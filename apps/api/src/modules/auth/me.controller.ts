import { Body, Controller, Get, Patch } from '@nestjs/common';
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser } from '../../shared/auth/auth.types';
import { CurrentUser } from '../../shared/auth/decorators';
import { DbService } from '../../shared/db/db.service';
import { businesses, memberships, roles, users } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';

const UpdateMe = z.object({
  fullName: z.string().trim().min(2).max(120).optional(),
  email: z.string().email().max(160).nullable().optional(),
  locale: z.enum(['fr', 'wo', 'en']).optional(),
});

@Controller('v1/me')
export class MeController {
  constructor(private readonly dbs: DbService) {}

  /** Profil + entreprises auxquelles l'utilisateur a accès (pour le sélecteur d'entreprise). */
  @Get()
  async me(@CurrentUser() current: AuthUser) {
    const db = this.dbs.db;
    const [user] = await db
      .select({ id: users.id, phone: users.phone, fullName: users.fullName, email: users.email, locale: users.locale })
      .from(users)
      .where(eq(users.id, current.id))
      .limit(1);
    if (!user) throw AppError.notFound('Utilisateur');

    const list = await db
      .select({
        id: businesses.id,
        name: businesses.name,
        slug: businesses.slug,
        category: businesses.category,
        role: roles.key,
        roleName: roles.name,
      })
      .from(memberships)
      .innerJoin(businesses, eq(businesses.id, memberships.businessId))
      .innerJoin(roles, eq(roles.id, memberships.roleId))
      .where(and(eq(memberships.userId, current.id), eq(memberships.status, 'active'), isNull(businesses.deletedAt)))
      .orderBy(businesses.name);

    return { user, businesses: list };
  }

  @Patch()
  async update(@CurrentUser() current: AuthUser, @Body() body: unknown) {
    const input = parse(UpdateMe, body);
    const [user] = await this.dbs.db
      .update(users)
      .set({ ...input, updatedAt: new Date() })
      .where(eq(users.id, current.id))
      .returning({ id: users.id, phone: users.phone, fullName: users.fullName, email: users.email, locale: users.locale });
    return { user };
  }
}
