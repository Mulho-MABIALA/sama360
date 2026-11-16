import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Patch,
  Post,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { and, eq, isNull } from 'drizzle-orm';
import { z } from 'zod';
import { AuthUser } from '../../shared/auth/auth.types';
import { CurrentUser } from '../../shared/auth/decorators';
import { env } from '../../shared/config/env';
import { DbService } from '../../shared/db/db.service';
import { businesses, memberships, roles, users } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { FilesService } from '../files/files.service';
import { AuthService } from './auth.service';

const UpdateMe = z.object({
  fullName: z.string().trim().min(2).max(120).optional(),
  email: z.string().email().max(160).nullable().optional(),
  locale: z.enum(['fr', 'wo', 'en']).optional(),
});

const profile = {
  id: users.id,
  phone: users.phone,
  fullName: users.fullName,
  email: users.email,
  locale: users.locale,
  avatarFileId: users.avatarFileId,
  createdAt: users.createdAt,
};

@Controller('v1/me')
export class MeController {
  constructor(
    private readonly dbs: DbService,
    private readonly files: FilesService,
    private readonly auth: AuthService,
  ) {}

  /** Profil + entreprises auxquelles l'utilisateur a accès (pour le sélecteur d'entreprise). */
  @Get()
  async me(@CurrentUser() current: AuthUser) {
    const db = this.dbs.db;
    const [user] = await db
      .select(profile)
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
      .returning(profile);
    return { user };
  }

  /** Photo de profil (JPEG, PNG ou WebP) : remplace l'ancienne. */
  @Post('avatar')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 20 * 1024 * 1024, files: 1 } }))
  setAvatar(@CurrentUser() current: AuthUser, @UploadedFile() file?: { buffer: Buffer; size: number }) {
    if (!file?.buffer?.length) throw new AppError('VALIDATION_FAILED', 'Ajoutez une photo (champ « file »)', 422);
    const maxMb = env().MAX_UPLOAD_MB;
    if (file.size > maxMb * 1024 * 1024) {
      throw new AppError('PAYLOAD_TOO_LARGE', `Photo trop lourde (maximum ${maxMb} Mo)`, 413);
    }
    return this.dbs.transaction(async (tx) => {
      const [before] = await tx
        .select({ avatarFileId: users.avatarFileId })
        .from(users)
        .where(eq(users.id, current.id))
        .for('update')
        .limit(1);
      if (!before) throw AppError.notFound('Utilisateur');
      const saved = await this.files.saveImage(tx, {
        businessId: null,
        kind: 'avatar',
        data: file.buffer,
        createdBy: current.id,
      });
      const [user] = await tx
        .update(users)
        .set({ avatarFileId: saved.id, updatedAt: new Date() })
        .where(eq(users.id, current.id))
        .returning(profile);
      if (before.avatarFileId) await this.files.remove(tx, before.avatarFileId);
      return { user };
    });
  }

  @Delete('avatar')
  removeAvatar(@CurrentUser() current: AuthUser) {
    return this.dbs.transaction(async (tx) => {
      const [before] = await tx
        .select({ avatarFileId: users.avatarFileId })
        .from(users)
        .where(eq(users.id, current.id))
        .for('update')
        .limit(1);
      if (!before) throw AppError.notFound('Utilisateur');
      const [user] = await tx
        .update(users)
        .set({ avatarFileId: null, updatedAt: new Date() })
        .where(eq(users.id, current.id))
        .returning(profile);
      if (before.avatarFileId) await this.files.remove(tx, before.avatarFileId);
      return { user };
    });
  }

  /** Ferme toutes les sessions (tous les appareils, y compris celui-ci). */
  @Post('logout-all')
  @HttpCode(200)
  async logoutAll(@CurrentUser() current: AuthUser) {
    return { revoked: await this.auth.logoutAll(current.id) };
  }
}
