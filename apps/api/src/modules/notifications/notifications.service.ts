import { Injectable } from '@nestjs/common';
import { hasPermission } from '@sama360/contracts';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';

/** Permissions qui ouvrent l'accès à une notification (colonne `audience`). */
export const AUDIENCES = ['sales:read', 'sales:create', 'sales:void', 'inventory:read', 'invoicing:read', 'contacts:read'] as const;
export type Audience = (typeof AUDIENCES)[number];

export interface NewNotification {
  kind: string;
  title: string;
  body?: string;
  link?: string | null;
  audience: Audience;
  userId?: string | null;
  actorId?: string | null;
  /** Une seule notification par clé et par entreprise (les doublons sont ignorés). */
  dedupeKey?: string | null;
  createdAt?: Date;
}

export interface NotificationView {
  id: string;
  kind: string;
  title: string;
  body: string;
  link: string | null;
  createdAt: string;
  read: boolean;
}

/** Notifications des 30 derniers jours seulement. */
const WINDOW_DAYS = 30;

/** « 125 000 F » (espace fine insécable, comme sur les reçus). */
export const francs = (n: number) => `${Math.round(n).toLocaleString('fr-FR').replace(/\s/g, ' ')} F`;

export const plural = (n: number, one: string, many: string) => `${n} ${n > 1 ? many : one}`;

/** Jour civil (Dakar = UTC) : sert de clé pour les rappels quotidiens. */
export const dayKey = (d: Date) => d.toISOString().slice(0, 10);

/** Audiences visibles pour un rôle. */
export const visibleAudiences = (permissions: readonly string[]) =>
  AUDIENCES.filter((a) => hasPermission(permissions, a));

@Injectable()
export class NotificationsService {
  constructor(private readonly dbs: DbService) {}

  /** Ajoute une notification (dans la transaction de l'appelant). Renvoie false si la clé existait déjà. */
  async push(tx: Tx, businessId: string, n: NewNotification): Promise<boolean> {
    const res = await tx.execute(sql`
      INSERT INTO core.notifications
        (id, business_id, kind, title, body, link, audience, user_id, actor_id, dedupe_key, created_at)
      VALUES (${newId()}, ${businessId}, ${n.kind}, ${n.title.slice(0, 160)}, ${(n.body ?? '').slice(0, 400)},
              ${n.link ?? null}, ${n.audience}, ${n.userId ?? null}, ${n.actorId ?? null}, ${n.dedupeKey ?? null},
              ${(n.createdAt ?? new Date()).toISOString()})
      ON CONFLICT (business_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
      RETURNING id`);
    return res.rows.length > 0;
  }

  /**
   * Rappels calculés à partir de l'état des données, créés au plus une fois par jour
   * (ou par semaine) au moment où un membre ouvre ses notifications.
   */
  async refreshReminders(tx: Tx, businessId: string, userId: string, permissions: readonly string[], now = new Date()) {
    const can = (p: string) => hasPermission(permissions, p);
    const today = dayKey(now);

    // Ma caisse ouverte depuis un jour précédent
    if (can('sales:create')) {
      const mine = await tx.execute(sql`
        SELECT id, number, opened_at FROM sales.cash_sessions
        WHERE user_id = ${userId} AND status = 'open' AND opened_at < ${today}::date
        LIMIT 1`);
      const s = mine.rows[0] as { id: string; number: string } | undefined;
      if (s) {
        await this.push(tx, businessId, {
          kind: 'cash_open',
          title: 'Votre caisse est toujours ouverte',
          body: `${s.number} a été ouverte avant aujourd’hui. Clôturez-la pour garder des comptes justes.`,
          link: '/cash',
          audience: 'sales:create',
          userId,
          dedupeKey: `cash_open:${s.id}:${today}`,
        });
      }
    }

    // Caisses des vendeurs restées ouvertes (gérant)
    if (can('sales:void')) {
      const others = await tx.execute(sql`
        SELECT count(*)::int AS n FROM sales.cash_sessions
        WHERE status = 'open' AND opened_at < ${today}::date`);
      const n = (others.rows[0] as { n: number }).n;
      if (n > 0) {
        await this.push(tx, businessId, {
          kind: 'cash_open_team',
          title: n > 1 ? `${n} caisses sont restées ouvertes` : 'Une caisse est restée ouverte',
          body: 'Ouverte(s) avant aujourd’hui : vérifiez le comptage avant de clôturer.',
          link: '/cash/history',
          audience: 'sales:void',
          dedupeKey: `cash_open_team:${today}`,
        });
      }
    }

    // Factures en retard
    if (can('invoicing:read')) {
      const r = await tx.execute(sql`
        SELECT count(*)::int AS n, COALESCE(sum(total - paid), 0)::bigint AS due
        FROM invoicing.documents
        WHERE kind = 'invoice' AND status IN ('unpaid', 'partial') AND due_date < ${today}::date`);
      const { n, due } = r.rows[0] as { n: number; due: string };
      if (n > 0) {
        await this.push(tx, businessId, {
          kind: 'invoices_overdue',
          title: n > 1 ? `${n} factures en retard` : '1 facture en retard',
          body: `${francs(Number(due))} à encaisser. Relancez vos clients.`,
          link: '/reminders',
          audience: 'invoicing:read',
          dedupeKey: `invoices_overdue:${today}`,
        });
      }
    }

    // Anniversaires du jour (fidélité)
    if (can('contacts:read')) {
      const r = await tx.execute(sql`
        SELECT id, name FROM contacts.contacts
        WHERE deleted_at IS NULL AND type <> 'supplier'
          AND birth_day = ${now.getUTCDate()} AND birth_month = ${now.getUTCMonth() + 1}
        ORDER BY name LIMIT 20`);
      const names = (r.rows as { id: string; name: string }[]).map((x) => x.name);
      if (names.length > 0) {
        await this.push(tx, businessId, {
          kind: 'birthday',
          title:
            names.length === 1 ? `Anniversaire de ${names[0]} aujourd’hui` : `${names.length} anniversaires aujourd’hui`,
          body:
            names.length === 1
              ? 'Envoyez-lui un petit message : un client fêté revient.'
              : `${names.slice(0, 3).join(', ')}${names.length > 3 ? '…' : ''} : envoyez un petit message.`,
          link: '/loyalty',
          audience: 'contacts:read',
          dedupeKey: `birthday:${today}`,
        });
      }
    }

    // Clients qui doivent de l'argent sans avoir rien remboursé depuis 30 jours (une fois par semaine)
    if (can('contacts:read')) {
      const r = await tx.execute(sql`
        SELECT count(*)::int AS n, COALESCE(sum(c.balance), 0)::bigint AS due
        FROM contacts.contacts c
        WHERE c.balance > 0 AND c.type IN ('customer', 'both')
          AND NOT EXISTS (
            SELECT 1 FROM sales.customer_ledger l
            WHERE l.customer_id = c.id AND l.entry_type = 'repayment'
              AND l.occurred_at > ${now.toISOString()}::timestamptz - interval '30 days')
          AND EXISTS (
            SELECT 1 FROM sales.customer_ledger l
            WHERE l.customer_id = c.id AND l.entry_type = 'debt'
              AND l.occurred_at <= ${now.toISOString()}::timestamptz - interval '30 days')`);
      const { n, due } = r.rows[0] as { n: number; due: string };
      if (n > 0) {
        await this.push(tx, businessId, {
          kind: 'credit_stale',
          title: n > 1 ? `${n} clients n’ont rien remboursé depuis 30 jours` : '1 client n’a rien remboursé depuis 30 jours',
          body: `${francs(Number(due))} de crédit en attente.`,
          link: '/reminders',
          audience: 'contacts:read',
          dedupeKey: `credit_stale:${isoWeek(now)}`,
        });
      }
    }
  }

  /** Notifications visibles par ce membre, les plus récentes d'abord. */
  async list(businessId: string, userId: string, permissions: readonly string[], limit = 50) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.refreshReminders(tx, businessId, userId, permissions);
      const items = await tx.execute(sql`
        SELECT n.id, n.kind, n.title, n.body, n.link, n.created_at, (r.user_id IS NOT NULL) AS read
        FROM core.notifications n
        LEFT JOIN core.notification_reads r ON r.notification_id = n.id AND r.user_id = ${userId}
        WHERE ${this.visible(userId, permissions)}
        ORDER BY n.created_at DESC
        LIMIT ${limit}`);
      const unread = await this.unreadIn(tx, userId, permissions);
      return {
        items: (items.rows as Array<Record<string, unknown>>).map(
          (r): NotificationView => ({
            id: r.id as string,
            kind: r.kind as string,
            title: r.title as string,
            body: r.body as string,
            link: (r.link as string | null) ?? null,
            createdAt: new Date(r.created_at as string).toISOString(),
            read: Boolean(r.read),
          }),
        ),
        unread,
      };
    });
  }

  /** Nombre de non lues (pastille de la cloche). */
  async unreadCount(businessId: string, userId: string, permissions: readonly string[]) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.refreshReminders(tx, businessId, userId, permissions);
      return this.unreadIn(tx, userId, permissions);
    });
  }

  async markRead(businessId: string, userId: string, permissions: readonly string[], id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const found = await tx.execute(sql`
        SELECT n.id FROM core.notifications n WHERE n.id = ${id} AND ${this.visible(userId, permissions)}`);
      if (found.rows.length === 0) throw new AppError('NOT_FOUND', 'Notification introuvable', 404);
      await tx.execute(sql`
        INSERT INTO core.notification_reads (notification_id, user_id, business_id)
        VALUES (${id}, ${userId}, ${businessId}) ON CONFLICT DO NOTHING`);
      return { unread: await this.unreadIn(tx, userId, permissions) };
    });
  }

  async markAllRead(businessId: string, userId: string, permissions: readonly string[]) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await tx.execute(sql`
        INSERT INTO core.notification_reads (notification_id, user_id, business_id)
        SELECT n.id, ${userId}, ${businessId} FROM core.notifications n
        WHERE ${this.visible(userId, permissions)}
        ON CONFLICT DO NOTHING`);
      return { unread: 0 };
    });
  }

  private async unreadIn(tx: Tx, userId: string, permissions: readonly string[]) {
    const r = await tx.execute(sql`
      SELECT count(*)::int AS n FROM core.notifications n
      WHERE ${this.visible(userId, permissions)}
        AND NOT EXISTS (SELECT 1 FROM core.notification_reads r WHERE r.notification_id = n.id AND r.user_id = ${userId})`);
    return (r.rows[0] as { n: number }).n;
  }

  /** Condition SQL : audience autorisée, destinataire, hors propres actions, fenêtre de 30 jours. */
  private visible(userId: string, permissions: readonly string[]) {
    const audiences = visibleAudiences(permissions);
    const inList = audiences.length
      ? sql`n.audience IN (${sql.join(audiences.map((a) => sql`${a}`), sql`, `)})`
      : sql`false`;
    return sql`${inList}
      AND (n.user_id IS NULL OR n.user_id = ${userId})
      AND (n.actor_id IS NULL OR n.actor_id <> ${userId})
      AND n.created_at > now() - make_interval(days => ${WINDOW_DAYS})`;
  }
}

/** Semaine ISO « 2026-W47 ». */
export function isoWeek(d: Date): string {
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const year = t.getUTCFullYear();
  const week = Math.ceil(((t.getTime() - Date.UTC(year, 0, 1)) / 86_400_000 + 1) / 7);
  return `${year}-W${String(week).padStart(2, '0')}`;
}
