import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import { COUNTRIES, CountryCode, countryOf, countryOfPhone, MOBILE_MONEY, MobileMoney } from '../../shared/countries';
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
import { createCheckout, splitName, verifyPulseSignature, readPulse } from './chariow';

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
        pending: requests.find((r) => r.status === 'pending')
          ? view(requests.find((r) => r.status === 'pending')!)
          : null,
        history: requests.map(view),
        referralCode: (b.referral_code as string) ?? null,
        online: this.onlineEnabled(),
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
    const u = (await this.dbs.transaction((tx) => tx.execute(sql`SELECT phone FROM core.users WHERE id = ${userId}`)))
      .rows[0] as Row | undefined;
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
      await tx.execute(sql`
        UPDATE core.subscription_requests SET status = 'approved', decided_by = ${adminId}, decided_at = ${now}
        WHERE id = ${id}`);
      return this.grant(tx, r.business_id as string, r.cycle as Cycle, now);
    });
    await this.announce(done, id);
    return { approved: true, endsAt: done.end.toISOString(), sponsorRewarded: !!done.sponsor };
  }

  // ─────────────────────────────── paiement en ligne (Chariow)

  /** Paiement en ligne possible ? (clé, secret et produits Chariow configurés) */
  onlineEnabled(): boolean {
    const e = env();
    return !!(e.CHARIOW_API_KEY && e.CHARIOW_PULSE_SECRET && e.CHARIOW_PRODUCT_MONTHLY && e.CHARIOW_PRODUCT_YEARLY);
  }

  private productFor(cycle: Cycle): string {
    const e = env();
    return (cycle === 'monthly' ? e.CHARIOW_PRODUCT_MONTHLY : e.CHARIOW_PRODUCT_YEARLY) as string;
  }

  /** Ouvre une page de paiement Chariow pour un mois ou un an de Pro. */
  async startCheckout(
    businessId: string,
    userId: string,
    input: { cycle: Cycle; email: string },
    ctx: { origin: string; ip?: string },
    fetchImpl?: typeof fetch,
  ) {
    if (!this.onlineEnabled()) {
      throw new AppError('PAYMENT_UNAVAILABLE', 'Paiement en ligne pas encore disponible', 503);
    }
    const e = env();
    const productId = this.productFor(input.cycle);
    const paymentId = newId();
    const info = await this.dbs.transaction(async (tx) => {
      const b = (await tx.execute(sql`SELECT name, country, phone FROM core.businesses WHERE id = ${businessId}`))
        .rows[0] as Row;
      const u = (await tx.execute(sql`SELECT full_name, phone, email FROM core.users WHERE id = ${userId}`))
        .rows[0] as Row;
      // L'adresse e-mail sert au reçu Chariow ; on la garde pour la prochaine fois
      if (!u.email) await tx.execute(sql`UPDATE core.users SET email = ${input.email} WHERE id = ${userId}`);
      await tx.execute(sql`
        INSERT INTO core.online_payments (id, business_id, provider, cycle, product_id, created_by)
        VALUES (${paymentId}, ${businessId}, 'chariow', ${input.cycle}, ${productId}, ${userId})`);
      return { business: b, user: u };
    });

    const phone = (info.user.phone as string) ?? (info.business.phone as string);
    // Le pays du numéro décide des moyens de paiement proposés par Chariow
    const country = countryOfPhone(phone) ?? countryOf(info.business.country as string);
    const name = splitName(info.user.full_name as string, info.business.name as string);
    const local = phone.replace(/\D/g, '').replace(new RegExp(`^${country.dial}`), '');
    const base = (e.PUBLIC_URL ?? ctx.origin).replace(/\/$/, '');
    let result;
    try {
      result = await createCheckout(
        e.CHARIOW_API_URL,
        e.CHARIOW_API_KEY as string,
        {
          productId,
          email: input.email,
          firstName: name.first,
          lastName: name.last,
          phone: { number: local, countryCode: country.code },
          redirectUrl: `${base}/app/#/pro?paid=${paymentId}`,
          customerIp: ctx.ip,
          metadata: { payment_id: paymentId, business_id: businessId, cycle: input.cycle },
        },
        fetchImpl,
      );
    } catch (err) {
      await this.dbs.transaction((tx) =>
        tx.execute(sql`UPDATE core.online_payments SET status = 'failed' WHERE id = ${paymentId}`),
      );
      this.log.warn(`Chariow : paiement non ouvert (${businessId}) : ${(err as Error).message}`);
      throw new AppError('PAYMENT_PROVIDER', 'La page de paiement n’a pas pu s’ouvrir. Réessayez.', 502);
    }
    await this.dbs.transaction((tx) =>
      tx.execute(sql`
        UPDATE core.online_payments SET sale_id = ${result.saleId}, checkout_url = ${result.checkoutUrl}
        WHERE id = ${paymentId}`),
    );
    if (result.step !== 'payment' || !result.checkoutUrl) {
      this.log.warn(`Chariow : étape inattendue « ${result.step} » (${businessId}) ${result.message ?? ''}`);
      throw new AppError('PAYMENT_PROVIDER', 'La page de paiement n’a pas pu s’ouvrir. Réessayez.', 502);
    }
    return { paymentId, checkoutUrl: result.checkoutUrl };
  }

  /** Où en est un paiement en ligne (retour de la page de paiement). */
  async onlinePayment(businessId: string, paymentId: string) {
    const r = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT id, cycle, status, paid_at FROM core.online_payments
          WHERE id = ${paymentId} AND business_id = ${businessId}`),
      )
    ).rows[0] as Row | undefined;
    if (!r) throw AppError.notFound('Paiement');
    return {
      id: r.id as string,
      cycle: r.cycle as Cycle,
      status: r.status as string,
      paidAt: r.paid_at ? new Date(r.paid_at as string).toISOString() : null,
    };
  }

  /**
   * Pulse Chariow (webhook signé). « successful.sale » d'un paiement Sama360 : Pro prolongé.
   * Rejoué sans risque : un paiement n'est crédité qu'une fois.
   */
  async handlePulse(
    raw: Buffer | undefined,
    signature: string | undefined,
    deliveryId: string | undefined,
    now = new Date(),
  ) {
    const secret = env().CHARIOW_PULSE_SECRET;
    if (!secret || !raw || !verifyPulseSignature(raw, signature, secret)) {
      throw new AppError('INVALID_SIGNATURE', 'Signature invalide', 401);
    }
    let payload: unknown;
    try {
      payload = JSON.parse(raw.toString('utf8'));
    } catch {
      throw new AppError('BAD_PAYLOAD', 'Contenu illisible', 400);
    }
    const p = readPulse(payload);
    if (deliveryId) {
      const fresh = (
        await this.dbs.transaction((tx) =>
          tx.execute(sql`
            INSERT INTO core.payment_events (provider, delivery_id, event) VALUES ('chariow', ${deliveryId}, ${p.event})
            ON CONFLICT DO NOTHING RETURNING delivery_id`),
        )
      ).rows[0];
      if (!fresh) return { ok: true, duplicate: true };
    }
    if (p.event !== 'successful.sale') return { ok: true, ignored: p.event };
    const paymentId = typeof p.metadata.payment_id === 'string' ? p.metadata.payment_id : null;
    if (!paymentId || !/^[0-9a-f-]{36}$/i.test(paymentId)) {
      // Vente Chariow qui ne vient pas de Sama360 (autre produit de la boutique)
      return { ok: true, ignored: 'not_sama360' };
    }

    const done = await this.dbs.transaction(async (tx) => {
      const r = (await tx.execute(sql`SELECT * FROM core.online_payments WHERE id = ${paymentId} FOR UPDATE`))
        .rows[0] as Row | undefined;
      if (!r) {
        this.log.warn(`Chariow : paiement inconnu ${paymentId} (vente ${p.saleId})`);
        return null;
      }
      if (r.status === 'paid') return null;
      if (p.productId && p.productId !== r.product_id) {
        this.log.warn(`Chariow : produit ${p.productId} au lieu de ${r.product_id as string} (paiement ${paymentId})`);
        return null;
      }
      await tx.execute(sql`
        UPDATE core.online_payments
           SET status = 'paid', paid_at = ${now}, sale_id = COALESCE(sale_id, ${p.saleId}),
               amount = ${p.amount}, currency = ${p.currency}
         WHERE id = ${paymentId}`);
      return this.grant(tx, r.business_id as string, r.cycle as Cycle, now);
    });
    if (!done) return { ok: true, credited: false };
    this.log.log(`Chariow : Pro ${done.cycle} payé en ligne (${done.businessId}, vente ${p.saleId})`);
    await this.announce(done, paymentId);
    return { ok: true, credited: true };
  }

  /**
   * Paiement reçu : Pro prolongé d'un mois ou d'un an. Premier paiement d'un filleul :
   * un mois offert au filleul et à son parrain (une seule fois).
   */
  private async grant(tx: Tx, businessId: string, cycle: Cycle, now: Date) {
    const end = await this.extend(tx, businessId, CYCLE_DAYS[cycle], now);
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
  }

  /** Notifications après paiement (au mieux). */
  private async announce(done: Awaited<ReturnType<BillingService['grant']>>, key: string) {
    const day = (d: Date) => d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' });
    await this.notify(done.businessId, {
      kind: 'pro_active',
      title: 'Sama360 Pro est activé',
      body: `Merci ! Votre abonnement court jusqu’au ${day(done.end)}.`,
      link: '/pro',
      audience: 'business:update',
      dedupeKey: `pro_active:${key}`,
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
  /** Équipe Sama360 : jours de Pro offerts (geste commercial, dédommagement). */
  async gift(businessId: string, days: number, reason: string | null, now = new Date()) {
    const end = await this.dbs.transaction((tx) => this.extend(tx, businessId, days, now));
    const day = end.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' });
    await this.notify(businessId, {
      kind: 'pro_active',
      title: `Cadeau : ${days} jour${days > 1 ? 's' : ''} de Pro offert${days > 1 ? 's' : ''}`,
      body: `${reason ? `${reason}. ` : ''}Sama360 Pro court jusqu’au ${day}.`,
      link: '/pro',
      audience: 'business:update',
      dedupeKey: `pro_gift:${businessId}:${now.getTime()}`,
    });
    return { endsAt: end.toISOString() };
  }

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
