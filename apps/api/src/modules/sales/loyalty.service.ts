import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';

export interface LoyaltySettings {
  enabled: boolean;
  /** F dépensés pour gagner 1 point. */
  earnPer: number;
  /** Points nécessaires pour une récompense. */
  rewardPoints: number;
  /** Remise accordée par récompense (F). */
  rewardValue: number;
}

/** Programme proposé par défaut : 1 point par 1 000 F, 100 points = 2 000 F de remise (2 %). */
export const DEFAULT_LOYALTY: LoyaltySettings = { enabled: false, earnPer: 1000, rewardPoints: 100, rewardValue: 2000 };

/** Points gagnés pour un achat (montant payé ou dû, après remises). */
export function pointsFor(total: number, s: LoyaltySettings): number {
  if (!s.enabled || total <= 0) return 0;
  return Math.floor(total / s.earnPer);
}

/** Nombre de récompenses que le client peut utiliser avec son solde. */
export function rewardsAvailable(balance: number, s: LoyaltySettings): number {
  if (!s.enabled || balance <= 0) return 0;
  return Math.floor(balance / s.rewardPoints);
}

/** Points manquants avant la prochaine récompense. */
export function pointsToNextReward(balance: number, s: LoyaltySettings): number {
  const rest = Math.max(0, balance) % s.rewardPoints;
  return s.rewardPoints - rest;
}

/** Ordre des anniversaires à venir : jours avant la prochaine date (0 = aujourd'hui). */
export function daysUntilBirthday(day: number, month: number, now: Date): number {
  const y = now.getUTCFullYear();
  const today = Date.UTC(y, now.getUTCMonth(), now.getUTCDate());
  // 29 février : fêté le 28 les années non bissextiles
  const safeDay = (yy: number) => (month === 2 && day === 29 && !isLeap(yy) ? 28 : day);
  let next = Date.UTC(y, month - 1, safeDay(y));
  if (next < today) next = Date.UTC(y + 1, month - 1, safeDay(y + 1));
  return Math.round((next - today) / 86_400_000);
}

const isLeap = (y: number) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

type Row = Record<string, unknown>;

@Injectable()
export class LoyaltyService {
  constructor(private readonly dbs: DbService) {}

  // ------------------------------------------------------------ réglages

  async settingsIn(tx: Tx): Promise<LoyaltySettings> {
    const [r] = (await tx.execute(sql`SELECT * FROM sales.loyalty_settings LIMIT 1`)).rows as Row[];
    if (!r) return DEFAULT_LOYALTY;
    return {
      enabled: Boolean(r.enabled),
      earnPer: Number(r.earn_per),
      rewardPoints: Number(r.reward_points),
      rewardValue: Number(r.reward_value),
    };
  }

  settings(businessId: string) {
    return this.dbs.withTenant(businessId, (tx) => this.settingsIn(tx));
  }

  saveSettings(businessId: string, s: LoyaltySettings) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await tx.execute(sql`
        INSERT INTO sales.loyalty_settings (business_id, enabled, earn_per, reward_points, reward_value, updated_at)
        VALUES (${businessId}, ${s.enabled}, ${s.earnPer}, ${s.rewardPoints}, ${s.rewardValue}, now())
        ON CONFLICT (business_id) DO UPDATE SET
          enabled = EXCLUDED.enabled, earn_per = EXCLUDED.earn_per,
          reward_points = EXCLUDED.reward_points, reward_value = EXCLUDED.reward_value, updated_at = now()`);
      return this.settingsIn(tx);
    });
  }

  // ------------------------------------------------------------ points

  async balanceIn(tx: Tx, customerId: string): Promise<number> {
    const [r] = (
      await tx.execute(
        sql`SELECT coalesce(sum(points), 0)::int AS b FROM sales.loyalty_ledger WHERE customer_id = ${customerId}`,
      )
    ).rows as { b: number }[];
    return Number(r.b);
  }

  /**
   * Utilisation de récompenses dans une vente : vérifie le programme et le solde (verrouillé),
   * renvoie la remise à appliquer. Appelé dans la transaction de la vente.
   */
  async redeemDiscount(tx: Tx, customerId: string | null | undefined, rewards: number) {
    if (!rewards) return { discount: 0, points: 0, settings: await this.settingsIn(tx) };
    if (!customerId) throw new AppError('VALIDATION_FAILED', 'Choisissez le client qui utilise ses points', 422);
    const settings = await this.settingsIn(tx);
    if (!settings.enabled) throw new AppError('CONFLICT', 'Le programme de fidélité est désactivé', 409);
    // Verrou sur le client : deux ventes simultanées ne dépensent pas les mêmes points.
    await tx.execute(sql`SELECT id FROM contacts.contacts WHERE id = ${customerId} FOR UPDATE`);
    const balance = await this.balanceIn(tx, customerId);
    const points = rewards * settings.rewardPoints;
    if (balance < points) {
      throw new AppError('CONFLICT', `Points insuffisants : ${balance} disponibles, ${points} demandés`, 409, {
        balance,
        points,
      });
    }
    return { discount: rewards * settings.rewardValue, points, settings };
  }

  /** Après l'enregistrement d'une vente : points utilisés puis points gagnés. */
  async recordSale(
    tx: Tx,
    p: {
      businessId: string;
      customerId: string;
      saleId: string;
      number: string;
      total: number;
      redeemedPoints: number;
      settings: LoyaltySettings;
      by: string;
    },
  ) {
    if (p.redeemedPoints > 0) {
      await this.entry(
        tx,
        p.businessId,
        p.customerId,
        'redeem',
        -p.redeemedPoints,
        p.saleId,
        `Remise ${p.number}`,
        p.by,
      );
    }
    const earned = pointsFor(p.total, p.settings);
    if (earned > 0) await this.entry(tx, p.businessId, p.customerId, 'earn', earned, p.saleId, p.number, p.by);
    return earned;
  }

  /** Vente annulée : on retire les points gagnés et on rend les points utilisés. */
  async reverseSale(tx: Tx, businessId: string, saleId: string, number: string, by: string) {
    const rows = (
      await tx.execute(sql`
        SELECT customer_id, sum(points)::int AS net FROM sales.loyalty_ledger
        WHERE sale_id = ${saleId} AND kind IN ('earn', 'redeem') GROUP BY customer_id`)
    ).rows as { customer_id: string; net: number }[];
    for (const r of rows) {
      if (Number(r.net) !== 0) {
        await this.entry(tx, businessId, r.customer_id, 'reverse', -Number(r.net), saleId, `Annulation ${number}`, by);
      }
    }
  }

  /** Points d'une vente (reçu) : gagnés, utilisés, solde du client. */
  async forSale(tx: Tx, saleId: string, customerId: string | null) {
    if (!customerId) return null;
    const rows = (await tx.execute(sql`SELECT kind, points FROM sales.loyalty_ledger WHERE sale_id = ${saleId}`))
      .rows as { kind: string; points: number }[];
    if (rows.length === 0) return null;
    return {
      earned: rows.filter((r) => r.kind === 'earn').reduce((s, r) => s + Number(r.points), 0),
      redeemed: -rows.filter((r) => r.kind === 'redeem').reduce((s, r) => s + Number(r.points), 0),
      balance: await this.balanceIn(tx, customerId),
    };
  }

  private async entry(
    tx: Tx,
    businessId: string,
    customerId: string,
    kind: 'earn' | 'redeem' | 'reverse' | 'adjust',
    points: number,
    saleId: string | null,
    note: string | null,
    by: string | null,
  ) {
    await tx.execute(sql`
      INSERT INTO sales.loyalty_ledger (id, business_id, customer_id, kind, points, sale_id, note, created_by)
      VALUES (${newId()}, ${businessId}, ${customerId}, ${kind}, ${points}, ${saleId}, ${note}, ${by})`);
  }

  // ------------------------------------------------------------ écrans

  /** Carte de fidélité d'un client : solde, récompenses, historique. */
  customer(businessId: string, customerId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [c] = (
        await tx.execute(sql`
          SELECT id, name, birth_day, birth_month FROM contacts.contacts
          WHERE id = ${customerId} AND deleted_at IS NULL AND type <> 'supplier'`)
      ).rows as Row[];
      if (!c) throw AppError.notFound('Client');
      const settings = await this.settingsIn(tx);
      const balance = await this.balanceIn(tx, customerId);
      const history = (
        await tx.execute(sql`
          SELECT id, kind, points, sale_id, note, created_at FROM sales.loyalty_ledger
          WHERE customer_id = ${customerId} ORDER BY created_at DESC, id DESC LIMIT 30`)
      ).rows as Row[];
      return {
        settings,
        balance,
        rewardsAvailable: rewardsAvailable(balance, settings),
        pointsToNextReward: pointsToNextReward(balance, settings),
        history: history.map((h) => ({
          id: h.id as string,
          kind: h.kind as string,
          points: Number(h.points),
          saleId: (h.sale_id as string) ?? null,
          note: (h.note as string) ?? null,
          at: new Date(h.created_at as string).toISOString(),
        })),
      };
    });
  }

  /** Ajustement manuel (cadeau, correction) par un gérant. */
  adjust(businessId: string, userId: string, customerId: string, points: number, reason: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [c] = (
        await tx.execute(
          sql`SELECT id FROM contacts.contacts WHERE id = ${customerId} AND deleted_at IS NULL FOR UPDATE`,
        )
      ).rows as Row[];
      if (!c) throw AppError.notFound('Client');
      const balance = await this.balanceIn(tx, customerId);
      if (balance + points < 0) {
        throw new AppError('CONFLICT', `Le client n’a que ${balance} points`, 409, { balance });
      }
      await this.entry(tx, businessId, customerId, 'adjust', points, null, reason, userId);
      return { balance: balance + points };
    });
  }

  /** Tableau de bord : programme, meilleurs clients (90 jours), anniversaires des 30 prochains jours. */
  dashboard(businessId: string, now = new Date()) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const settings = await this.settingsIn(tx);
      const top = (
        await tx.execute(sql`
          SELECT c.id, c.name, c.phone, count(s.id)::int AS visits, coalesce(sum(s.total), 0)::bigint AS spent,
                 max(s.sold_at) AS last_visit,
                 (SELECT coalesce(sum(points), 0)::int FROM sales.loyalty_ledger l WHERE l.customer_id = c.id) AS points
          FROM contacts.contacts c
          JOIN sales.sales s ON s.customer_id = c.id AND s.status = 'completed'
            AND s.sold_at >= ${now.toISOString()}::timestamptz - interval '90 days'
          WHERE c.deleted_at IS NULL AND c.type <> 'supplier'
          GROUP BY c.id ORDER BY spent DESC, visits DESC LIMIT 10`)
      ).rows as Row[];
      const withBirthday = (
        await tx.execute(sql`
          SELECT c.id, c.name, c.phone, c.birth_day, c.birth_month,
                 (SELECT coalesce(sum(points), 0)::int FROM sales.loyalty_ledger l WHERE l.customer_id = c.id) AS points
          FROM contacts.contacts c
          WHERE c.deleted_at IS NULL AND c.type <> 'supplier' AND c.birth_day IS NOT NULL AND c.birth_month IS NOT NULL`)
      ).rows as Row[];
      const birthdays = withBirthday
        .map((b) => ({
          customerId: b.id as string,
          name: b.name as string,
          phone: (b.phone as string) ?? null,
          day: Number(b.birth_day),
          month: Number(b.birth_month),
          points: Number(b.points),
          inDays: daysUntilBirthday(Number(b.birth_day), Number(b.birth_month), now),
        }))
        .filter((b) => b.inDays <= 30)
        .sort((a, b) => a.inDays - b.inDays || a.name.localeCompare(b.name));
      const [stats] = (
        await tx.execute(sql`
          SELECT coalesce(sum(points) FILTER (WHERE kind IN ('earn', 'adjust') AND points > 0), 0)::int AS issued,
                 coalesce(-sum(points) FILTER (WHERE kind = 'redeem'), 0)::int AS redeemed,
                 coalesce(sum(points), 0)::int AS outstanding,
                 count(DISTINCT customer_id)::int AS members
          FROM sales.loyalty_ledger`)
      ).rows as Row[];
      return {
        settings,
        stats: {
          members: Number(stats.members),
          pointsIssued: Number(stats.issued),
          pointsRedeemed: Number(stats.redeemed),
          pointsOutstanding: Number(stats.outstanding),
        },
        top: top.map((t) => ({
          customerId: t.id as string,
          name: t.name as string,
          phone: (t.phone as string) ?? null,
          visits: Number(t.visits),
          spent: Number(t.spent),
          lastVisit: new Date(t.last_visit as string).toISOString(),
          points: Number(t.points),
        })),
        birthdays,
      };
    });
  }
}
