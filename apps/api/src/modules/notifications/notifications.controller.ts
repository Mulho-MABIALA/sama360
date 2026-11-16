import { Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Query } from '@nestjs/common';
import { z } from 'zod';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, TenantScoped } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { NotificationsService } from './notifications.service';

const List = z.object({ limit: z.coerce.number().int().min(1).max(100).default(50) });

/** Cloche de l'accueil : chaque membre voit ce qui concerne son rôle. */
@Controller('v1/notifications')
@TenantScoped()
export class NotificationsController {
  constructor(private readonly notifications: NotificationsService) {}

  @Get()
  list(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Query() q: unknown) {
    return this.notifications.list(t.businessId, u.id, t.permissions, parse(List, q).limit);
  }

  @Get('unread-count')
  async unread(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser) {
    return { unread: await this.notifications.unreadCount(t.businessId, u.id, t.permissions) };
  }

  @Post('read-all')
  @HttpCode(200)
  readAll(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser) {
    return this.notifications.markAllRead(t.businessId, u.id, t.permissions);
  }

  @Post(':id/read')
  @HttpCode(200)
  read(@CurrentTenant() t: TenantContext, @CurrentUser() u: AuthUser, @Param('id', ParseUUIDPipe) id: string) {
    return this.notifications.markRead(t.businessId, u.id, t.permissions, id);
  }
}
