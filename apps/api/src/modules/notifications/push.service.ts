import { Injectable, Logger, OnApplicationShutdown } from '@nestjs/common';
import { hasPermission, PERMISSIONS } from '@sama360/contracts';
import { sql } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import { DbService } from '../../shared/db/db.service';
import { FcmClient, parseServiceAccount, PushMessage, SendResult } from './fcm';
import { NotificationsService } from './notifications.service';
export { PUSH_KINDS } from './push-queue';

type Row = Record<string, unknown>;

/** Envoi vers un appareil (remplaçable dans les tests). */
export interface PushSender {
  send(token: string, msg: PushMessage): Promise<SendResult>;
}

export const PLATFORMS = ['android', 'ios', 'web'] as const;
export type Platform = (typeof PLATFORMS)[number];

@Injectable()
export class PushService implements OnApplicationShutdown {
  private readonly log = new Logger('Push');
  private sender?: PushSender | null;
  private timers: NodeJS.Timeout[] = [];
  private running = false;

  constructor(
    private readonly dbs: DbService,
    private readonly notifications: NotificationsService,
  ) {}

  /** Firebase configuré ? (clé du compte de service) */
  get enabled(): boolean {
    return this.getSender() !== null;
  }

  /** Remplace l'envoi (tests). */
  useSender(sender: PushSender | null) {
    this.sender = sender;
  }

  private getSender(): PushSender | null {
    if (this.sender !== undefined) return this.sender;
    const raw = env().FCM_SERVICE_ACCOUNT;
    try {
      this.sender = raw ? new FcmClient(parseServiceAccount(raw)) : null;
    } catch (e) {
      this.log.error(`FCM_SERVICE_ACCOUNT illisible : ${(e as Error).message}`);
      this.sender = null;
    }
    return this.sender;
  }

  /** Ce dont la version web a besoin pour s'abonner (rien de secret). */
  webConfig() {
    const e = env();
    const raw = e.FCM_SERVICE_ACCOUNT;
    let projectId: string | null = null;
    try {
      projectId = raw ? parseServiceAccount(raw).project_id : null;
    } catch {
      projectId = null;
    }
    const web =
      projectId && e.FIREBASE_WEB_API_KEY && e.FIREBASE_WEB_APP_ID && e.FIREBASE_VAPID_KEY
        ? {
            apiKey: e.FIREBASE_WEB_API_KEY,
            appId: e.FIREBASE_WEB_APP_ID,
            projectId,
            messagingSenderId: e.FIREBASE_WEB_APP_ID.split(':')[1] ?? '',
            vapidKey: e.FIREBASE_VAPID_KEY,
          }
        : null;
    return { enabled: this.enabled, web };
  }

  // ─────────────────────────────── appareils

  async register(userId: string, token: string, platform: Platform, now = new Date()) {
    await this.dbs.transaction((tx) =>
      tx.execute(sql`
        INSERT INTO core.push_tokens (token, user_id, platform, created_at, last_seen_at)
        VALUES (${token}, ${userId}, ${platform}, ${now}, ${now})
        ON CONFLICT (token) DO UPDATE SET user_id = ${userId}, platform = ${platform}, last_seen_at = ${now}`),
    );
    return { registered: true };
  }

  async unregister(userId: string, token: string) {
    await this.dbs.transaction((tx) =>
      tx.execute(sql`DELETE FROM core.push_tokens WHERE token = ${token} AND user_id = ${userId}`),
    );
    return { registered: false };
  }

  // ─────────────────────────────── file d'envoi

  /** Envoie ce qui attend dans la file. Renvoie le nombre d'appareils atteints. */
  async dispatch(limit = 100): Promise<number> {
    const sender = this.getSender();
    if (!sender) return 0;
    // Trop vieux (serveur endormi longtemps) : plus utile sur le téléphone, reste dans la cloche
    await this.dbs.transaction((tx) =>
      tx.execute(sql`DELETE FROM core.push_queue WHERE created_at < now() - interval '6 hours' OR attempts >= 3`),
    );
    const due = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT notification_id, business_id FROM core.push_queue ORDER BY created_at LIMIT ${limit}`),
      )
    ).rows as Row[];
    let sent = 0;
    for (const q of due) {
      const id = q.notification_id as string;
      const businessId = q.business_id as string;
      try {
        sent += await this.deliver(sender, businessId, id);
        await this.dbs.transaction((tx) => tx.execute(sql`DELETE FROM core.push_queue WHERE notification_id = ${id}`));
      } catch (e) {
        this.log.warn(`Notification ${id} : ${(e as Error).message}`);
        await this.dbs.transaction((tx) =>
          tx.execute(sql`UPDATE core.push_queue SET attempts = attempts + 1 WHERE notification_id = ${id}`),
        );
      }
    }
    return sent;
  }

  /** Destinataires : membres actifs qui ont la permission, sauf l'auteur ; puis leurs appareils. */
  private async deliver(sender: PushSender, businessId: string, notificationId: string): Promise<number> {
    const n = (
      await this.dbs.withTenant(businessId, (tx) =>
        tx.execute(sql`
          SELECT kind, title, body, link, audience, user_id, actor_id FROM core.notifications
          WHERE id = ${notificationId}`),
      )
    ).rows[0] as Row | undefined;
    if (!n) return 0;
    const members = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT m.user_id, r.permissions FROM core.memberships m
          JOIN core.roles r ON r.id = m.role_id
          JOIN core.users u ON u.id = m.user_id
          WHERE m.business_id = ${businessId} AND m.status = 'active' AND u.deleted_at IS NULL`),
      )
    ).rows as Row[];
    const users = members
      .filter((m) => hasPermission(m.permissions as string[], n.audience as string))
      .map((m) => m.user_id as string)
      .filter((u) => (!n.user_id || u === n.user_id) && u !== n.actor_id);
    if (!users.length) return 0;
    const tokens = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT token FROM core.push_tokens
          WHERE user_id IN (${sql.join(
            users.map((u) => sql`${u}`),
            sql`, `,
          )})`),
      )
    ).rows.map((r) => (r as Row).token as string);
    const msg: PushMessage = {
      title: n.title as string,
      body: n.body as string,
      link: (n.link as string | null) ?? null,
      webBase: env().PUBLIC_URL ?? null,
    };
    let sent = 0;
    for (const token of tokens) {
      const r = await sender.send(token, msg);
      if (r === 'sent') sent++;
      if (r === 'unregistered') {
        await this.dbs.transaction((tx) => tx.execute(sql`DELETE FROM core.push_tokens WHERE token = ${token}`));
      }
    }
    return sent;
  }

  // ─────────────────────────────── rappels du jour

  /**
   * Rappels calculés (stock, crédits en retard, factures, rendez-vous, fin de Pro…) pour chaque
   * boutique, sans attendre que quelqu'un ouvre l'app. Une fois par jour grâce aux clés de doublon.
   */
  async dailyReminders(now = new Date()) {
    const all = [...PERMISSIONS];
    const shops = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT id, owner_id FROM core.businesses WHERE deleted_at IS NULL`),
      )
    ).rows as Row[];
    for (const b of shops) {
      try {
        await this.dbs.withTenant(b.id as string, (tx) =>
          this.notifications.refreshReminders(tx, b.id as string, b.owner_id as string, all, now),
        );
      } catch (e) {
        this.log.warn(`Rappels de ${b.id as string} : ${(e as Error).message}`);
      }
    }
    return shops.length;
  }

  /** Worker : file toutes les 10 s ; rappels à chaque heure entre 8 h et 20 h (heure de Dakar). */
  start() {
    if (!this.enabled) {
      this.log.log('Notifications push désactivées (FCM_SERVICE_ACCOUNT absent)');
      return;
    }
    const tick = async () => {
      if (this.running) return;
      this.running = true;
      try {
        await this.dispatch();
      } catch (e) {
        this.log.warn(`Envoi : ${(e as Error).message}`);
      } finally {
        this.running = false;
      }
    };
    const hourly = async () => {
      const h = new Date().getUTCHours();
      if (h < 8 || h > 20) return;
      await this.dailyReminders().catch((e) => this.log.warn(`Rappels : ${(e as Error).message}`));
      await tick();
    };
    this.timers.push(
      setInterval(() => void tick(), 10_000),
      setInterval(() => void hourly(), 3_600_000),
    );
    setTimeout(() => void hourly(), 60_000).unref();
    for (const t of this.timers) t.unref();
    this.log.log('Notifications push actives');
  }

  onApplicationShutdown() {
    for (const t of this.timers) clearInterval(t);
  }
}
