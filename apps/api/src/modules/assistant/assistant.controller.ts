import { Body, Controller, Get, HttpCode, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission } from '../../shared/auth/decorators';
import { parse } from '../../shared/http/zod';
import { AssistantService } from './assistant.service';

const Chat = z.object({
  messages: z
    .array(z.object({ role: z.enum(['user', 'assistant']), content: z.string().trim().min(1).max(2000) }))
    .min(1)
    .max(20)
    .refine((m) => m.length > 0 && m[m.length - 1].role === 'user', 'le dernier message doit venir de l’utilisateur'),
});

/** Assistant IA : questions sur la boutique, réponses à partir des vraies données (lecture seule). */
@Controller('v1/assistant')
export class AssistantController {
  constructor(private readonly assistant: AssistantService) {}

  @Get()
  @RequirePermission('business:read')
  status(@CurrentTenant() t: TenantContext) {
    return this.assistant.status(t);
  }

  @Post('chat')
  @HttpCode(200)
  @RequirePermission('business:read')
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  chat(@CurrentTenant() t: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    return this.assistant.chat(t, user.id, parse(Chat, body).messages);
  }
}
