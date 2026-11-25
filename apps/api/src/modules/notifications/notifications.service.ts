import { Injectable } from '@nestjs/common';
import { hasPermission } from '@sama360/contracts';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { hourLabel } from '../booking/booking';
import { EXPIRY_WARNING_DAYS } from '../documents/documents';
import { effectivePlan, FREE_LIMITS, PRO_PRICES, SubscriptionRow } from '../../shared/plans';
import { fcfa, weekOf } from '../sales/insights';
import { enqueuePush } from './push-queue';

/** Permissions qui ouvrent l'accès à une notification (colonne `audience`). */
export const AUDIENCES = [
  'sales:read',
  'sales:create',
  'sales:void',
  'inventory:read',
  'invoicing:read',
  'reports:read',
  'contacts:read',
  'documents:read',
  'business:update',
] as const;
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
    const id = newId();
    const res = await tx.execute(sql`
      INSERT INTO core.notifications
        (id, business_id, kind, title, body, link, audience, user_id, actor_id, dedupe_key, created_at)
      VALUES (${id}, ${businessId}, ${n.kind}, ${n.title.slice(0, 160)}, ${(n.body ?? '').slice(0, 400)},
              ${n.link ?? null}, ${n.audience}, ${n.userId ?? null}, ${n.actorId ?? null}, ${n.dedupeKey ?? null},
              ${(n.createdAt ?? new Date()).toISOString()})
      ON CONFLICT (business_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING
      RETURNING id`);
    if (res.rows.length === 0) return false;
    // Aussi sur le téléphone (commande en ligne, stock bas, Pro…), après la validation de la transaction
    await enqueuePush(tx, businessId, id, n.kind);
    return true;
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

    // Documents dont l'échéance approche (bail, assurance…) : une alerte par document et par échéance
    if (can('documents:read')) {
      const due = (
        await tx.execute(sql`
          SELECT id, title, to_char(expires_on, 'YYYY-MM-DD') AS e, (expires_on - current_date) AS days
          FROM core.documents
          WHERE deleted_at IS NULL AND expires_on IS NOT NULL
            AND expires_on <= current_date + ${EXPIRY_WARNING_DAYS}::int
            AND expires_on >= current_date - 30
          ORDER BY expires_on LIMIT 20`)
      ).rows as { id: string; title: string; e: string; days: number }[];
      for (const d of due) {
        const days = Number(d.days);
        await this.push(tx, businessId, {
          kind: 'document_expiring',
          title: days < 0 ? `Échéance dépassée : ${d.title}` : `${d.title} : échéance bientôt`,
          body:
            days < 0
              ? `Expiré depuis ${-days} jour${-days > 1 ? 's' : ''}. Pensez à le renouveler.`
              : days === 0
                ? 'Expire aujourd’hui. Pensez à le renouveler.'
                : `Expire dans ${days} jour${days > 1 ? 's' : ''}. Pensez à le renouveler.`,
          link: `/documents/${d.id}`,
          audience: 'documents:read',
          dedupeKey: `document_expiring:${d.id}:${d.e}:${days < 0 ? 'late' : 'soon'}`,
        });
      }
    }

    // Rendez-vous du jour : une notification le matin, avec le premier client
    if (can('sales:read')) {
      const rdv = (
        await tx.execute(sql`
          SELECT customer_name, service_name, starts_at, count(*) OVER () AS total
          FROM sales.appointments
          WHERE status = 'booked' AND starts_at >= current_date AND starts_at < current_date + 1
          ORDER BY starts_at LIMIT 1`)
      ).rows[0] as { customer_name: string; service_name: string; starts_at: string; total: number } | undefined;
      if (rdv) {
        const total = Number(rdv.total);
        await this.push(tx, businessId, {
          kind: 'appointments_today',
          title: total === 1 ? '1 rendez-vous aujourd’hui' : `${total} rendez-vous aujourd’hui`,
          body: `Premier à ${hourLabel(new Date(rdv.starts_at))} : ${rdv.customer_name} (${rdv.service_name}).`,
          link: '/booking',
          audience: 'sales:read',
          dedupeKey: `appointments_today:${today}`,
        });
      }
    }

    // Rapport de la semaine : une fois par semaine, dès qu'il y a eu des ventes la semaine passée
    if (can('reports:read')) {
      const week = weekOf(undefined, now);
      const r = (
        await tx.execute(sql`
          SELECT count(*)::int AS n, coalesce(sum(total), 0)::bigint AS revenue FROM sales.sales
          WHERE status = 'completed' AND sold_at >= ${week.from}::date AND sold_at < ${week.to}::date + 1`)
      ).rows[0] as { n: number; revenue: string | number };
      if (Number(r.n) > 0) {
        await this.push(tx, businessId, {
          kind: 'weekly_report',
          title: 'Votre rapport de la semaine est prêt',
          body: `${fcfa(Number(r.revenue))} de ventes. Heures de pointe, produits qui dorment, marges : à envoyer sur WhatsApp.`,
          link: '/insights/week',
          audience: 'reports:read',
          dedupeKey: `weekly_report:${isoWeek(now)}`,
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
            names.length === 1
              ? `Anniversaire de ${names[0]} aujourd’hui`
              : `${names.length} anniversaires aujourd’hui`,
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
          title:
            n > 1 ? `${n} clients n’ont rien remboursé depuis 30 jours` : '1 client n’a rien remboursé depuis 30 jours',
          body: `${francs(Number(due))} de crédit en attente.`,
          link: '/reminders',
          audience: 'contacts:read',
          dedupeKey: `credit_stale:${isoWeek(now)}`,
        });
      }
    }

    // Sama360 Pro : fin d'essai ou d'abonnement (7 jours, 3 jours, la veille, puis terminé),
    // avec ce que ce commerçant-là va perdre : c'est le moment où il est le plus prêt à payer
    if (can('business:update')) {
      const sub = (
        await tx.execute(sql`
          SELECT plan, status, current_period_end AS "currentPeriodEnd"
          FROM core.subscriptions WHERE business_id = ${businessId}`)
      ).rows[0] as unknown as SubscriptionRow | undefined;
      const p = effectivePlan(sub, now);
      const what = sub?.status === 'trialing' ? 'Votre essai Sama360 Pro' : 'Votre abonnement Sama360 Pro';
      const end = p.endsAt?.slice(0, 10);
      if (p.pro && p.daysLeft <= 7) {
        const bucket = p.daysLeft <= 1 ? 1 : p.daysLeft <= 3 ? 3 : 7;
        const losses = await this.proLosses(tx, businessId, now);
        await this.push(tx, businessId, {
          kind: 'pro_ending',
          title: p.daysLeft <= 1 ? `${what} se termine demain` : `${what} se termine dans ${p.daysLeft} jours`,
          body: losses.length
            ? `Sans Pro, vous perdez : ${losses.join(', ')}. Dès ${fcfa(PRO_PRICES.weekly)} la semaine.`
            : `Gardez les produits illimités, tout l’historique et la boutique en ligne. Dès ${fcfa(PRO_PRICES.weekly)} la semaine.`,
          link: '/pro',
          audience: 'business:update',
          dedupeKey: `pro_ending:${end}:${bucket}`,
        });
      } else if (p.state === 'expired' && p.endsAt && now.getTime() - Date.parse(p.endsAt) < 30 * 86_400_000) {
        await this.push(tx, businessId, {
          kind: 'pro_ended',
          title: `${what} est terminé`,
          body: 'Vos ventes, votre stock et vos clients restent là. Passez à Pro pour retrouver le reste.',
          link: '/pro',
          audience: 'business:update',
          dedupeKey: `pro_ended:${end}`,
        });
      }
    }
  }

  /** Ce que la fin de Pro enlèverait à ce commerce, d'après ce qu'il utilise vraiment. */
  private async proLosses(tx: Tx, businessId: string, now: Date): Promise<string[]> {
    const since = new Date(now.getTime() - 30 * 86_400_000);
    const r = (
      await tx.execute(sql`
        SELECT
          (SELECT count(*)::int FROM catalog.products WHERE deleted_at IS NULL AND parent_id IS NULL) AS products,
          (SELECT count(*)::int FROM core.memberships m JOIN core.businesses b ON b.id = m.business_id
            WHERE m.business_id = ${businessId} AND m.status = 'active' AND m.user_id <> b.owner_id) AS staff,
          (SELECT count(*)::int FROM shop.orders WHERE created_at >= ${since}) AS orders,
          (SELECT count(*)::int FROM sales.deliveries WHERE created_at >= ${since}) AS deliveries`)
    ).rows[0] as { products: number; staff: number; orders: number; deliveries: number };
    const out: string[] = [];
    if (r.products > FREE_LIMITS.products)
      out.push(`l’ajout de produits (vous en avez ${r.products}, ${FREE_LIMITS.products} en gratuit)`);
    if (r.staff > 0) out.push(r.staff === 1 ? 'votre vendeur' : `vos ${r.staff} vendeurs`);
    if (r.orders > 0) out.push(`la boutique en ligne (${r.orders} commande${r.orders > 1 ? 's' : ''} ce mois)`);
    if (r.deliveries > 0) out.push('les livraisons');
    return out;
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
        items: (items.rows as Array<Record<string, unknown>>).map((r): NotificationView => ({
          id: r.id as string,
          kind: r.kind as string,
          title: r.title as string,
          body: r.body as string,
          link: (r.link as string | null) ?? null,
          createdAt: new Date(r.created_at as string).toISOString(),
          read: Boolean(r.read),
        })),
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
      ? sql`n.audience IN (${sql.join(
          audiences.map((a) => sql`${a}`),
          sql`, `,
        )})`
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
