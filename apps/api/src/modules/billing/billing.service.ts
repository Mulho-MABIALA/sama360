import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import { COUNTRIES, CountryCode, countryOf, MOBILE_MONEY, MobileMoney } from '../../shared/countries';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';
import {
  CYCLE_DAYS,
  Cycle,
  effectivePlan,
  extendFrom,
  PRO_FEATURE_LABELS,
  PRO_FEATURES,
  PRO_PRICES,
  REFERRAL_BONUS_DAYS,
  SubscriptionRow,
} from '../../shared/plans';
import { NotificationsService } from '../notifications/notifications.service';

type Row = Record<string, unknown>;

export interface PaymentRequestInput {
  cycle: Cycle;
  method: MobileMoney;
  reference: string;
  payerPhone?: string | null;
}

export const PAY_METHODS = MOBILE_MONEY;

/** Où envoyer l'argent de l'abonnement, par pays (variables PRO_PAY_TO_SN, _CI, _CG). */
export function payTo(country: CountryCode): string | null {
  const v = { SN: env().PRO_PAY_TO_SN, CI: env().PRO_PAY_TO_CI, CG: env().PRO_PAY_TO_CG }[country];
  return v?.trim() || null;
}

/** Numéros de l'équipe Sama360 qui valident les paiements (ADMIN_PHONES, séparés par des virgules). */
export function adminPhones(): string[] {
  return (env().ADMIN_PHONES ?? '')
    .split(',')
    .map((p) => normalizePhone(p.trim()))
    .filter((p): p is string => !!p);
}

const view = (r: Row) => ({
  id: r.id as string,
  cycle: r.cycle as Cycle,
  amount: Number(r.amount),
  currency: r.currency as string,
  method: r.method as string,
  reference: r.reference as string,
  payerPhone: (r.payer_phone as string) ?? null,
  status: r.status as string,
  note: (r.note as string) ?? null,
  createdAt: new Date(r.created_at as string).toISOString(),
  decidedAt: r.decided_at ? new Date(r.decided_at as string).toISOString() : null,
});

@Injectable()
export class BillingService {
  private readonly log = new Logger('Billing');

  constructor(
    private readonly dbs: DbService,
    private readonly notifications: NotificationsService,
  ) {}

  private async sub(tx: Tx, businessId: string): Promise<SubscriptionRow | undefined> {
    return (
      await tx.execute(sql`
        SELECT plan, status, current_period_end AS "currentPeriodEnd"
        FROM core.subscriptions WHERE business_id = ${businessId}`)
    ).rows[0] as unknown as SubscriptionRow | undefined;
  }

  /** État de l'abonnement, prix, comment payer, demande en attente, parrainage. */
  async overview(businessId: string) {
    return this.dbs.transaction(async (tx) => {
      const b = (
        await tx.execute(sql`SELECT country, currency, referral_code FROM core.businesses WHERE id = ${businessId}`)
      ).rows[0] as Row;
      const country = countryOf(b.country as string);
      const requests = (
        await tx.execute(sql`
          SELECT * FROM core.subscription_requests WHERE business_id = ${businessId}
          ORDER BY created_at DESC LIMIT 5`)
      ).rows as Row[];
      const sub = await this.sub(tx, businessId);
      return {
        ...effectivePlan(sub),
        currency: country.currency,
        prices: PRO_PRICES,
        features: PRO_FEATURES.map((key) => ({ key, label: PRO_FEATURE_LABELS[key] })),
        payTo: payTo(country.code),
        methods: country.mobileMoney,
        pending: requests.find((r) => r.status === 'pending') ? view(requests.find((r) => r.status === 'pending')!) : null,
        history: requests.map(view),
        referralCode: (b.referral_code as string) ?? null,
      };
    });
  }

  /** Le commerçant a payé (Wave, Orange Money, MoMo…) : demande à valider par l'équipe Sama360. */
  async requestPayment(businessId: string, userId: string, input: PaymentRequestInput) {
    return this.dbs.transaction(async (tx) => {
      const b = (await tx.execute(sql`SELECT country FROM core.businesses WHERE id = ${businessId}`)).rows[0] as Row;
      const country = countryOf(b.country as string);
      const pending = (
        await tx.execute(
          sql`SELECT 1 FROM core.subscription_requests WHERE business_id = ${businessId} AND status = 'pending'`,
        )
      ).rows[0];
      if (pending) throw AppError.conflict('Un paiement est déjà en cours de vérification');
      const phone = input.payerPhone ? normalizePhone(input.payerPhone, country.code) : null;
      if (input.payerPhone && !phone) throw new AppError('PHONE_INVALID', 'Numéro du payeur invalide', 422);
      const r = (
        await tx.execute(sql`
          INSERT INTO core.subscription_requests
            (id, business_id, cycle, amount, currency, method, reference, payer_phone, created_by)
          VALUES (${newId()}, ${businessId}, ${input.cycle}, ${PRO_PRICES[input.cycle]}, ${COUNTRIES[country.code].currency},
                  ${input.method}, ${input.reference.trim()}, ${phone}, ${userId})
          RETURNING *`)
      ).rows[0] as Row;
      this.log.log(`Paiement Pro à vérifier : ${businessId} ${input.method} ${input.reference}`);
      return view(r);
    });
  }

  /** Mes filleuls : inscrits avec mon code, et ceux qui ont déjà rapporté un mois offert. */
  async referrals(businessId: string) {
    return this.dbs.transaction(async (tx) => {
      const me = (await tx.execute(sql`SELECT referral_code FROM core.businesses WHERE id = ${businessId}`))
        .rows[0] as Row;
      const rows = (
        await tx.execute(sql`
          SELECT b.name, b.city, b.created_at, rr.days IS NOT NULL AS rewarded
          FROM core.businesses b
          LEFT JOIN core.referral_rewards rr ON rr.referee_id = b.id
          WHERE b.referred_by = ${businessId} AND b.deleted_at IS NULL
          ORDER BY b.created_at DESC LIMIT 200`)
      ).rows as Row[];
      const rewarded = rows.filter((r) => r.rewarded === true).length;
      return {
        code: me.referral_code as string,
        bonusDays: REFERRAL_BONUS_DAYS,
        daysEarned: rewarded * REFERRAL_BONUS_DAYS,
        referrals: rows.map((r) => ({
          name: r.name as string,
          city: (r.city as string) ?? null,
          joinedAt: new Date(r.created_at as string).toISOString(),
          rewarded: r.rewarded === true,
        })),
      };
    });
  }

  // ─────────────────────────────── équipe Sama360

  async isAdmin(userId: string): Promise<boolean> {
    const admins = adminPhones();
    if (!admins.length) return false;
    const u = (
      await this.dbs.transaction((tx) => tx.execute(sql`SELECT phone FROM core.users WHERE id = ${userId}`))
    ).rows[0] as Row | undefined;
    return !!u && admins.includes(u.phone as string);
  }

  async assertAdmin(userId: string) {
    if (!(await this.isAdmin(userId))) throw AppError.forbidden('Réservé à l’équipe Sama360');
  }

  async adminList(status: 'pending' | 'approved' | 'rejected' = 'pending') {
    return this.dbs.transaction(async (tx) => {
      const rows = (
        await tx.execute(sql`
          SELECT r.*, b.name AS business_name, b.country, b.city, b.phone AS business_phone
          FROM core.subscription_requests r JOIN core.businesses b ON b.id = r.business_id
          WHERE r.status = ${status}
          ORDER BY r.created_at ${status === 'pending' ? sql`ASC` : sql`DESC`} LIMIT 200`)
      ).rows as Row[];
      return rows.map((r) => ({
        ...view(r),
        business: {
          id: r.business_id as string,
          name: r.business_name as string,
          country: r.country as string,
          city: (r.city as string) ?? null,
          phone: (r.business_phone as string) ?? null,
        },
      }));
    });
  }

  /**
   * Paiement vérifié : Pro prolongé d'un mois ou d'un an. Premier paiement d'un filleul :
   * un mois offert au filleul et à son parrain (une seule fois).
   */
  async approve(id: string, adminId: string, now = new Date()) {
    const done = await this.dbs.transaction(async (tx) => {
      const r = (await tx.execute(sql`SELECT * FROM core.subscription_requests WHERE id = ${id} FOR UPDATE`))
        .rows[0] as Row | undefined;
      if (!r) throw AppError.notFound('Demande');
      if (r.status !== 'pending') throw AppError.conflict('Demande déjà traitée');
      const businessId = r.business_id as string;
      const cycle = r.cycle as Cycle;

      await tx.execute(sql`
        UPDATE core.subscription_requests SET status = 'approved', decided_by = ${adminId}, decided_at = ${now}
        WHERE id = ${id}`);
      const end = await this.extend(tx, businessId, CYCLE_DAYS[cycle], now);

      // Parrainage
      let sponsor: { id: string; end: Date } | null = null;
      let refereeEnd = end;
      const b = (
        await tx.execute(sql`
          SELECT referred_by FROM core.businesses WHERE id = ${businessId}
            AND NOT EXISTS (SELECT 1 FROM core.referral_rewards WHERE referee_id = ${businessId})`)
      ).rows[0] as Row | undefined;
      if (b?.referred_by) {
        const sponsorId = b.referred_by as string;
        await tx.execute(sql`
          INSERT INTO core.referral_rewards (referee_id, referrer_id, days)
          VALUES (${businessId}, ${sponsorId}, ${REFERRAL_BONUS_DAYS}) ON CONFLICT DO NOTHING`);
        refereeEnd = await this.extend(tx, businessId, REFERRAL_BONUS_DAYS, now);
        sponsor = { id: sponsorId, end: await this.extend(tx, sponsorId, REFERRAL_BONUS_DAYS, now) };
      }
      return { businessId, cycle, end: refereeEnd, sponsor };
    });

    // Notifications (au mieux, après validation)
    const day = (d: Date) => d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' });
    await this.notify(done.businessId, {
      kind: 'pro_active',
      title: 'Sama360 Pro est activé',
      body: `Merci ! Votre abonnement court jusqu’au ${day(done.end)}.`,
      link: '/pro',
      audience: 'business:update',
      dedupeKey: `pro_active:${id}`,
    });
    if (done.sponsor) {
      await this.notify(done.sponsor.id, {
        kind: 'referral_reward',
        title: 'Parrainage : un mois Pro offert',
        body: `Un commerçant que vous avez invité s’est abonné. Pro jusqu’au ${day(done.sponsor.end)}.`,
        link: '/referral',
        audience: 'business:update',
        dedupeKey: `referral_reward:${done.businessId}`,
      });
    }
    return { approved: true, endsAt: done.end.toISOString(), sponsorRewarded: !!done.sponsor };
  }

  async reject(id: string, adminId: string, note: string | null) {
    const r = await this.dbs.transaction(async (tx) => {
      const row = (
        await tx.execute(sql`
          UPDATE core.subscription_requests
             SET status = 'rejected', note = ${note}, decided_by = ${adminId}, decided_at = now()
           WHERE id = ${id} AND status = 'pending' RETURNING *`)
      ).rows[0] as Row | undefined;
      if (!row) throw new AppError('CONFLICT', 'Demande introuvable ou déjà traitée', HttpStatus.CONFLICT);
      return row;
    });
    await this.notify(r.business_id as string, {
      kind: 'pro_rejected',
      title: 'Paiement Pro non retrouvé',
      body: note ?? 'Vérifiez la référence de la transaction et renvoyez-la.',
      link: '/pro',
      audience: 'business:update',
      dedupeKey: `pro_rejected:${id}`,
    });
    return view(r);
  }

  /** Prolonge Pro de `days` jours (à partir de la fin en cours si elle est à venir). */
  private async extend(tx: Tx, businessId: string, days: number, now: Date): Promise<Date> {
    const cur = await this.sub(tx, businessId);
    const end = extendFrom(cur?.plan === 'pro' ? cur.currentPeriodEnd : null, days, now);
    await tx.execute(sql`
      INSERT INTO core.subscriptions (id, business_id, plan, status, current_period_end)
      VALUES (${newId()}, ${businessId}, 'pro', 'active', ${end})
      ON CONFLICT (business_id) DO UPDATE SET plan = 'pro', status = 'active', current_period_end = ${end}`);
    return end;
  }

  private async notify(businessId: string, n: Parameters<NotificationsService['push']>[2]) {
    try {
      await this.dbs.withTenant(businessId, (tx) => this.notifications.push(tx, businessId, n));
    } catch (e) {
      this.log.warn(`Notification non envoyée (${businessId}) : ${(e as Error).message}`);
    }
  }
}
