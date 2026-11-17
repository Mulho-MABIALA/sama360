import { Injectable } from '@nestjs/common';
import { DEFAULT_MODULES } from '@sama360/contracts';
import { eq, like, or } from 'drizzle-orm';
import { DbService } from '../../shared/db/db.service';
import { businesses, memberships, moduleActivations, roles, subscriptions } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { FilesService } from '../files/files.service';
import { SYSTEM_ROLE_IDS } from './roles';
import { slugify } from './slug';

export interface CreateBusinessInput {
  name: string;
  category?: string | null;
  phone?: string | null;
  city?: string | null;
  address?: string | null;
  ninea?: string | null;
}

export interface UpdateBusinessInput extends Partial<CreateBusinessInput> {
  brandColor?: string | null;
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

    return this.dbs.withTenant(id, async (tx) => {
      const [business] = await tx
        .insert(businesses)
        .values({
          id,
          ownerId,
          name: input.name,
          slug,
          category: input.category ?? null,
          phone: input.phone ?? null,
          city: input.city ?? null,
          address: input.address ?? null,
          ninea: input.ninea ?? null,
        })
        .returning();

      await tx.insert(memberships).values({
        id: newId(),
        businessId: id,
        userId: ownerId,
        roleId: SYSTEM_ROLE_IDS.owner,
        status: 'active',
      });
      await tx.insert(subscriptions).values({ id: newId(), businessId: id, plan: 'free' });
      await tx.insert(moduleActivations).values(DEFAULT_MODULES.map((module) => ({ businessId: id, module })));

      await this.outbox.record(tx, {
        type: 'business.created',
        businessId: id,
        aggregateId: id,
        actorId: ownerId,
        payload: { businessId: id, ownerId, name: business.name, category: business.category },
      });

      return { business, modules: DEFAULT_MODULES, subscription: { plan: 'free' } };
    });
  }

  async getCurrent(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const [business] = await tx.select().from(businesses).where(eq(businesses.id, businessId)).limit(1);
      if (!business) throw AppError.notFound('Entreprise');
      const mods = await tx.select().from(moduleActivations);
      const [subscription] = await tx
        .select({ plan: subscriptions.plan, status: subscriptions.status, currentPeriodEnd: subscriptions.currentPeriodEnd })
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
    const [business] = await this.dbs.db
      .update(businesses)
      .set({ ...input, updatedAt: new Date() })
      .where(eq(businesses.id, businessId))
      .returning();
    return { business };
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
      await tx.update(businesses).set({ logoFileId: saved.id, updatedAt: new Date() }).where(eq(businesses.id, businessId));
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
