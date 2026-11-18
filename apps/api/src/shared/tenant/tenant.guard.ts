import { countryOf } from '../countries';
import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { hasPermission } from '@sama360/contracts';
import { and, eq, isNull } from 'drizzle-orm';
import { sql } from 'drizzle-orm';
import type { AppRequest } from '../auth/auth.types';
import { IS_PUBLIC, REQUIRED_MODULE, REQUIRED_PERMISSION, REQUIRED_PRO, TENANT_SCOPED } from '../auth/decorators';
import { effectivePlan, PRO_FEATURE_LABELS, ProFeature } from '../plans';
import { DbService } from '../db/db.service';
import { businesses, memberships, moduleActivations, roles, subscriptions } from '../db/schema';
import { AppError } from '../http/app-error';
import { newId } from '../ids';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Garde globale (après JwtAuthGuard) : pour les routes liées à une entreprise,
 * vérifie l'adhésion active de l'utilisateur, charge rôle, permissions et modules,
 * puis contrôle la permission et le module exigés.
 */
@Injectable()
export class TenantGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly dbs: DbService,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const targets = [ctx.getHandler(), ctx.getClass()];
    if (this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, targets)) return true;

    const permission = this.reflector.getAllAndOverride<string>(REQUIRED_PERMISSION, targets);
    const module = this.reflector.getAllAndOverride<string>(REQUIRED_MODULE, targets);
    const scoped = this.reflector.getAllAndOverride<boolean>(TENANT_SCOPED, targets);
    const proFeature = this.reflector.getAllAndOverride<ProFeature>(REQUIRED_PRO, targets);
    if (!permission && !module && !scoped && !proFeature) return true;

    const req = ctx.switchToHttp().getRequest<AppRequest>();
    const businessId = req.header('x-business-id');
    if (!businessId || !UUID_RE.test(businessId)) {
      throw new AppError('BUSINESS_REQUIRED', 'En-tête X-Business-Id requis', 400);
    }
    if (!req.user) throw new AppError('UNAUTHENTICATED', 'Authentification requise', 401);

    const db = this.dbs.db;
    const [m] = await db
      .select({
        membershipId: memberships.id,
        roleKey: roles.key,
        permissions: roles.permissions,
        country: businesses.country,
        plan: subscriptions.plan,
        planStatus: subscriptions.status,
        periodEnd: subscriptions.currentPeriodEnd,
        memberWarehouse: memberships.warehouseId,
      })
      .from(memberships)
      .innerJoin(roles, eq(roles.id, memberships.roleId))
      .innerJoin(businesses, eq(businesses.id, memberships.businessId))
      .leftJoin(subscriptions, eq(subscriptions.businessId, memberships.businessId))
      .where(
        and(
          eq(memberships.businessId, businessId),
          eq(memberships.userId, req.user.id),
          eq(memberships.status, 'active'),
          isNull(businesses.deletedAt),
        ),
      )
      .limit(1);
    if (!m) throw new AppError('NOT_A_MEMBER', "Vous n'avez pas accès à cette entreprise", 403);

    const requested = req.header('x-location-id');
    const { modules, locations } = await this.dbs.withTenant(businessId, async (tx) => {
      const rows = await tx
        .select({ module: moduleActivations.module })
        .from(moduleActivations)
        .where(sql`${moduleActivations.enabled} = true`);
      let locs = (await tx.execute(sql`SELECT id, is_default FROM inventory.warehouses WHERE archived_at IS NULL`))
        .rows as { id: string; is_default: boolean }[];
      if (!locs.some((l) => l.is_default)) {
        // Commerce créé avant les points de vente : on crée le principal
        await tx.execute(sql`
          INSERT INTO inventory.warehouses (id, business_id, name, is_default)
          VALUES (${newId()}, ${businessId}, 'Boutique principale', true) ON CONFLICT DO NOTHING`);
        locs = (await tx.execute(sql`SELECT id, is_default FROM inventory.warehouses WHERE archived_at IS NULL`))
          .rows as { id: string; is_default: boolean }[];
      }
      return { modules: rows.map((r) => r.module), locations: locs };
    });
    const main = locations.find((l) => l.is_default)!.id;
    const active = (id?: string | null) => (id && locations.some((l) => l.id === id) ? id : null);
    const pinned = active(m.memberWarehouse);
    // Point de vente demandé inconnu ou archivé (sélection ancienne sur le téléphone) : on retombe sur « tous »
    const chosen = pinned ?? active(requested && UUID_RE.test(requested) ? requested : null);

    if (permission && !hasPermission(m.permissions, permission)) {
      throw new AppError('INSUFFICIENT_PERMISSION', `Permission requise : ${permission}`, 403, { permission });
    }
    if (module && !modules.includes(module)) {
      throw new AppError('MODULE_NOT_ENABLED', `Le module ${module} n'est pas activé`, 403, { module });
    }

    const pro = effectivePlan(
      m.plan ? { plan: m.plan, status: m.planStatus ?? 'active', currentPeriodEnd: m.periodEnd } : null,
    ).pro;
    if (proFeature && !pro) {
      throw new AppError(
        'PRO_REQUIRED',
        `${PRO_FEATURE_LABELS[proFeature]} : fonction Sama360 Pro`,
        HttpStatus.PAYMENT_REQUIRED,
        { feature: proFeature },
      );
    }

    req.tenant = {
      businessId,
      membershipId: m.membershipId,
      roleKey: m.roleKey,
      permissions: m.permissions,
      modules,
      country: countryOf(m.country).code,
      pro,
      warehouseId: chosen ?? main,
      locationFilter: chosen,
      locationLocked: pinned !== null,
    };
    return true;
  }
}
