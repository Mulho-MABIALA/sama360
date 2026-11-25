import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Query } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import type { AuthUser } from '../../shared/auth/auth.types';
import { CurrentUser } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { AdminService } from './admin.service';
import { FeedbackService } from './feedback.service';

const Send = z.object({
  kind: z.enum(['idea', 'problem', 'other']),
  message: z.string().trim().min(3, 'Écrivez quelques mots').max(2000),
  businessId: z.string().uuid().nullish(),
  appVersion: z.string().trim().max(30).nullish(),
});
const ListQuery = z.object({
  status: z.enum(['new', 'read', 'done']).optional(),
  page: z.coerce.number().int().min(1).max(10_000).optional(),
  pageSize: z.coerce.number().int().min(1).max(100).optional(),
});
const SetStatus = z.object({ status: z.enum(['new', 'read', 'done']) });

/** Suggestions : envoyées par tout utilisateur connecté, lues par l'équipe Sama360. */
@Controller('v1')
export class FeedbackController {
  constructor(
    private readonly feedback: FeedbackService,
    private readonly admin: AdminService,
  ) {}

  @Post('feedback')
  @Throttle({ default: { limit: 10, ttl: 3_600_000 } })
  send(@CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.feedback.send(user.id, parse(Send, body));
  }

  @Get('admin/feedback')
  async list(@CurrentUser() user: AuthUser, @Query() query: unknown) {
    await this.admin.assertAdmin(user.id);
    return this.feedback.list(parse(ListQuery, query));
  }

  @Patch('admin/feedback/:id')
  async setStatus(@CurrentUser() user: AuthUser, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    await this.admin.assertAdmin(user.id);
    return this.feedback.setStatus(id, parse(SetStatus, body).status);
  }
}
