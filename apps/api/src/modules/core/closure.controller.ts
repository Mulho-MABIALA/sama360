import { Body, Controller, Delete, Get, HttpCode, Param, ParseUUIDPipe, Post } from '@nestjs/common';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, TenantScoped } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { ClosureService } from './closure.service';

const DeleteBusiness = z.object({ confirmName: z.string().trim().min(1).max(160) });
const DeleteAccount = z.object({ confirm: z.string().trim().min(1).max(20) });

/** Supprimer sa boutique ou son compte (30 jours pour changer d'avis), et restaurer. */
@Controller('v1')
export class ClosureController {
  constructor(private readonly closure: ClosureService) {}

  /** Propriétaire seulement ; le nom de la boutique est retapé pour confirmer. */
  @Delete('business')
  @TenantScoped()
  @HttpCode(200)
  deleteBusiness(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.closure.deleteBusiness(t, user.id, parse(DeleteBusiness, body).confirmName);
  }

  /** Mes boutiques supprimées, restaurables pendant 30 jours. */
  @Get('businesses/deleted')
  deleted(@CurrentUser() user: AuthUser) {
    return this.closure.deletedBusinesses(user.id);
  }

  @Post('businesses/:id/restore')
  @HttpCode(200)
  restore(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.closure.restoreBusiness(user.id, id);
  }

  /** Supprimer mon compte (exigé par l'App Store et Google Play) : taper SUPPRIMER pour confirmer. */
  @Delete('me')
  @HttpCode(200)
  deleteAccount(@CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.closure.deleteAccount(user.id, parse(DeleteAccount, body).confirm);
  }
}
