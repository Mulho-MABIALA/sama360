import { Focus, onboardingSteps } from './onboarding';
import { Injectable } from '@nestjs/common';
import { DEFAULT_MODULES } from '@sama360/contracts';
import { eq, like, or, sql } from 'drizzle-orm';
import { DbService } from '../../shared/db/db.service';
import { businesses, memberships, moduleActivations, roles, subscriptions, users } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { FilesService } from '../files/files.service';
import { SYSTEM_ROLE_IDS } from './roles';
import { slugify } from './slug';
import { extendFrom, referralCode, TRIAL_DAYS } from '../../shared/plans';
import { COUNTRIES, CountryCode } from '../../shared/countries';

export interface CreateBusinessInput {
  name: string;
  category?: string | null;
  phone?: string | null;
  city?: string | null;
  address?: string | null;
  ninea?: string | null;
  focus?: Focus | null;
  country?: CountryCode;
  referralCode?: string;
}

export interface UpdateBusinessInput extends Partial<Omit<CreateBusinessInput, 'focus'>> {
  focus?: Focus;
  onboardingDismissed?: boolean;
  brandColor?: string | null;
  requireOpenCash?: boolean;
  payAccounts?: Partial<Record<string, { number?: string | null; link?: string | null }>>;
}

@Injectable()
export class BusinessesService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
    private readonly files: FilesService,
  ) {}

  /**
   * Crée l'entreprise, l'adhésion « propriétaire », l'abonnement gratuit et les modules
   * de la vague 1, puis émet business.created — le tout dans une seule transaction.
   */
  async create(ownerId: string, input: CreateBusinessInput) {
    const id = newId();
    const slug = await this.uniqueSlug(slugify(input.name));
    const code = await this.uniqueReferralCode(input.name);
    // Parrain : code saisi à l'inscription (insensible à la casse) ; un code inconnu est ignoré
    const sponsor = input.referralCode
      ? (
          await this.dbs.db
            .select({ id: businesses.id })
            .from(businesses)
            .where(sql`upper(${businesses.referralCode}) = ${input.referralCode.trim().toUpperCase()}`)
            .limit(1)
        )[0]
      : undefined;

    // Numéro de la boutique (reçus, factures) : par défaut, celui du compte qui la crée
    const phone =
      input.phone ??
      (await this.dbs.db.select({ phone: users.phone }).from(users).where(eq(users.id, ownerId)).limit(1))[0]?.phone ??
      null;

    return this.dbs.withTenant(id, async (tx) => {
      const [business] = await tx
        .insert(businesses)
        .values({
          id,
          ownerId,
          name: input.name,
          slug,
          category: input.category ?? null,
          phone,
          city: input.city ?? null,
          address: input.address ?? null,
          ninea: input.ninea ?? null,
          country: input.country ?? 'SN',
          currency: COUNTRIES[input.country ?? 'SN'].currency,
          settings: input.focus ? { focus: input.focus } : {},
          referralCode: code,
          referredBy: sponsor?.id ?? null,
        })
        .returning();

      await tx.insert(memberships).values({
        id: newId(),
        businessId: id,
        userId: ownerId,
        roleId: SYSTEM_ROLE_IDS.owner,
        status: 'active',
      });
      // 30 jours de Pro offerts pour découvrir tout Sama360
      const trialEnd = extendFrom(null, TRIAL_DAYS);
      await tx.insert(subscriptions).values({
        id: newId(),
        businessId: id,
        plan: 'pro',
        status: 'trialing',
        currentPeriodEnd: trialEnd,
      });
      await tx.insert(moduleActivations).values(DEFAULT_MODULES.map((module) => ({ businessId: id, module })));

      await this.outbox.record(tx, {
        type: 'business.created',
        businessId: id,
        aggregateId: id,
        actorId: ownerId,
        payload: { businessId: id, ownerId, name: business.name, category: business.category },
      });

      return {
        business,
        modules: DEFAULT_MODULES,
        subscription: { plan: 'pro', status: 'trialing', currentPeriodEnd: trialEnd },
      };
    });
  }

  private async uniqueReferralCode(name: string): Promise<string> {
    for (let i = 0; i < 10; i++) {
      const code = referralCode(name);
      const [taken] = await this.dbs.db
        .select({ id: businesses.id })
        .from(businesses)
        .where(eq(businesses.referralCode, code))
        .limit(1);
      if (!taken) return code;
    }
    return referralCode(name) + referralCode('', Math.random).slice(3, 5);
  }

  async getCurrent(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [business] = await tx.select().from(businesses).where(eq(businesses.id, businessId)).limit(1);
      if (!business) throw AppError.notFound('Entreprise');
      const mods = await tx.select().from(moduleActivations);
      const [subscription] = await tx
        .select({
          plan: subscriptions.plan,
          status: subscriptions.status,
          currentPeriodEnd: subscriptions.currentPeriodEnd,
        })
        .from(subscriptions)
        .where(eq(subscriptions.businessId, businessId))
        .limit(1);
      return {
        business,
        modules: mods.map((m) => ({ module: m.module, enabled: m.enabled })),
        subscription,
      };
    });
  }

  async update(businessId: string, input: UpdateBusinessInput) {
    const { focus, onboardingDismissed, payAccounts, ...columns } = input;
    // Réglages libres (activité, guide masqué) : fusionnés dans le JSON, sans écraser le reste
    const patch: Record<string, unknown> = {};
    if (focus !== undefined) patch.focus = focus;
    if (onboardingDismissed !== undefined) patch.onboardingDismissed = onboardingDismissed;
    if (payAccounts !== undefined) {
      // Remplace tous les comptes ; ceux laissés vides sont retirés
      const clean: Record<string, { number?: string; link?: string }> = {};
      for (const [k, v] of Object.entries(payAccounts)) {
        const number = v?.number?.replace(/\s+/g, '') || undefined;
        const link = v?.link || undefined;
        if (number || link) clean[k] = { ...(number ? { number } : {}), ...(link ? { link } : {}) };
      }
      patch.payAccounts = clean;
    }
    const [business] = await this.dbs.db
      .update(businesses)
      .set({
        ...columns,
        ...(columns.country ? { currency: COUNTRIES[columns.country].currency } : {}),
        ...(Object.keys(patch).length
          ? { settings: sql`${businesses.settings} || ${JSON.stringify(patch)}::jsonb` }
          : {}),
        updatedAt: new Date(),
      })
      .where(eq(businesses.id, businessId))
      .returning();
    return { business };
  }

  /** Premiers pas : activité choisie, guide masqué ou non, étapes faites d'après les données. */
  onboarding(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const r = (
        await tx.execute(sql`
          SELECT b.settings, b.logo_file_id IS NOT NULL AS has_logo, coalesce(b.phone, '') <> '' AS has_phone,
            (SELECT count(*) FROM catalog.products WHERE deleted_at IS NULL AND parent_id IS NULL AND type = 'product')::int AS products,
            (SELECT count(*) FROM catalog.products WHERE deleted_at IS NULL AND parent_id IS NULL AND type = 'service')::int AS services,
            (SELECT count(*) FROM sales.sales)::int AS sales,
            (SELECT count(*) FROM sales.appointments)::int AS appointments,
            coalesce((SELECT enabled FROM shop.settings LIMIT 1), false) AS shop_online,
            coalesce((SELECT online_enabled FROM sales.booking_settings LIMIT 1), false) AS booking_online,
            (SELECT count(*) FROM core.memberships m WHERE m.business_id = b.id AND m.status <> 'removed')::int AS members
          FROM core.businesses b WHERE b.id = ${businessId}`)
      ).rows[0] as Record<string, unknown>;
      const settings = (r.settings ?? {}) as { focus?: Focus; onboardingDismissed?: boolean };
      const focus = settings.focus ?? null;
      return {
        focus,
        dismissed: settings.onboardingDismissed === true,
        steps: onboardingSteps(focus, {
          products: Number(r.products),
          services: Number(r.services),
          sales: Number(r.sales),
          appointments: Number(r.appointments),
          hasLogo: r.has_logo === true,
          hasPhone: r.has_phone === true,
          shopOnline: r.shop_online === true,
          bookingOnline: r.booking_online === true,
          members: Number(r.members),
        }),
      };
    });
  }

  /** Logo de l'entreprise (en-tête des factures, devis et reçus) : remplace l'ancien. */
  async setLogo(businessId: string, userId: string, data: Buffer) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [before] = await tx
        .select({ logoFileId: businesses.logoFileId })
        .from(businesses)
        .where(eq(businesses.id, businessId))
        .for('update')
        .limit(1);
      if (!before) throw AppError.notFound('Entreprise');
      const saved = await this.files.saveImage(tx, { businessId, kind: 'logo', data, createdBy: userId });
      await tx
        .update(businesses)
        .set({ logoFileId: saved.id, updatedAt: new Date() })
        .where(eq(businesses.id, businessId));
      if (before.logoFileId) await this.files.remove(tx, before.logoFileId);
      return { logoFileId: saved.id };
    });
  }

  async removeLogo(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [before] = await tx
        .select({ logoFileId: businesses.logoFileId })
        .from(businesses)
        .where(eq(businesses.id, businessId))
        .for('update')
        .limit(1);
      if (!before) throw AppError.notFound('Entreprise');
      await tx.update(businesses).set({ logoFileId: null, updatedAt: new Date() }).where(eq(businesses.id, businessId));
      if (before.logoFileId) await this.files.remove(tx, before.logoFileId);
      return { logoFileId: null };
    });
  }

  async systemRoles() {
    return this.dbs.db.select({ key: roles.key, name: roles.name, permissions: roles.permissions }).from(roles);
  }

  private async uniqueSlug(base: string): Promise<string> {
    const rows = await this.dbs.db
      .select({ slug: businesses.slug })
      .from(businesses)
      .where(or(eq(businesses.slug, base), like(businesses.slug, `${base}-%`)));
    const taken = new Set(rows.map((r) => r.slug));
    if (!taken.has(base)) return base;
    for (let i = 2; i < 1000; i++) {
      const candidate = `${base}-${i}`;
      if (!taken.has(candidate)) return candidate;
    }
    return `${base}-${newId().slice(-6)}`;
  }
}
