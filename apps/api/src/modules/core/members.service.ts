import { Injectable } from '@nestjs/common';
import type { RoleKey } from '@sama360/contracts';
import { and, eq } from 'drizzle-orm';
import { DbService } from '../../shared/db/db.service';
import { auditLogs, memberships, roles, users } from '../../shared/db/schema';
import { OutboxService } from '../../shared/events/outbox.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { SYSTEM_ROLE_IDS } from './roles';

@Injectable()
export class MembersService {
  constructor(
    private readonly dbs: DbService,
    private readonly outbox: OutboxService,
  ) {}

  list(businessId: string) {
    return this.dbs.db
      .select({
        id: memberships.id,
        status: memberships.status,
        role: roles.key,
        roleName: roles.name,
        userId: users.id,
        phone: users.phone,
        fullName: users.fullName,
        createdAt: memberships.createdAt,
      })
      .from(memberships)
      .innerJoin(users, eq(users.id, memberships.userId))
      .innerJoin(roles, eq(roles.id, memberships.roleId))
      .where(eq(memberships.businessId, businessId))
      .orderBy(memberships.createdAt);
  }

  /**
   * Invite une personne par son numéro. Si elle n'a pas encore de compte, un compte « invited »
   * est créé ; l'adhésion devient active à sa première connexion par OTP.
   */
  async invite(businessId: string, actorId: string, input: { phone: string; fullName?: string; roleKey: Exclude<RoleKey, 'owner'> }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      let [user] = await tx.select().from(users).where(eq(users.phone, input.phone)).limit(1);
      if (!user) {
        [user] = await tx
          .insert(users)
          .values({ id: newId(), phone: input.phone, fullName: input.fullName ?? null, status: 'invited' })
          .returning();
      }

      const [existing] = await tx
        .select({ id: memberships.id })
        .from(memberships)
        .where(and(eq(memberships.businessId, businessId), eq(memberships.userId, user.id)))
        .limit(1);
      if (existing) throw AppError.conflict('Cette personne est déjà membre de l’entreprise');

      const membershipId = newId();
      const status = user.status === 'active' ? 'active' : 'invited';
      await tx.insert(memberships).values({
        id: membershipId,
        businessId,
        userId: user.id,
        roleId: SYSTEM_ROLE_IDS[input.roleKey],
        status,
        invitedBy: actorId,
      });

      await this.outbox.record(tx, {
        type: 'member.invited',
        businessId,
        aggregateId: membershipId,
        actorId,
        payload: { membershipId, userId: user.id, phone: user.phone, roleKey: input.roleKey, invitedBy: actorId },
      });

      return { id: membershipId, userId: user.id, phone: user.phone, role: input.roleKey, status };
    });
  }

  /** Change le rôle ou suspend un membre. L'adhésion du propriétaire n'est pas modifiable ici. */
  async update(
    businessId: string,
    actorId: string,
    membershipId: string,
    input: { roleKey?: Exclude<RoleKey, 'owner'>; status?: 'active' | 'suspended' },
  ) {
    return this.dbs.transaction(async (tx) => {
      const [m] = await tx
        .select({ id: memberships.id, roleId: memberships.roleId, userId: memberships.userId })
        .from(memberships)
        .where(and(eq(memberships.id, membershipId), eq(memberships.businessId, businessId)))
        .limit(1);
      if (!m) throw AppError.notFound('Membre');
      if (m.roleId === SYSTEM_ROLE_IDS.owner) throw AppError.forbidden('Le propriétaire ne peut pas être modifié');
      if (m.userId === actorId) throw AppError.forbidden('Vous ne pouvez pas modifier votre propre accès');

      const [updated] = await tx
        .update(memberships)
        .set({
          ...(input.roleKey ? { roleId: SYSTEM_ROLE_IDS[input.roleKey] } : {}),
          ...(input.status ? { status: input.status } : {}),
        })
        .where(eq(memberships.id, membershipId))
        .returning();

      await tx.insert(auditLogs).values({
        id: newId(),
        businessId,
        actorId,
        action: 'member.updated',
        entityType: 'membership',
        entityId: membershipId,
        data: input,
      });
      return updated;
    });
  }
}
