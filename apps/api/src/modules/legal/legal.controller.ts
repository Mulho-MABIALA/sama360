import { Body, Controller, Get, Header, HttpCode, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { Public } from '../../shared/auth/decorators';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { AuthService } from '../auth/auth.service';
import { ClosureService } from '../core/closure.service';
import { deletionPage, privacyPage, termsPage } from './legal.pages';

const DeletionRequest = z.object({
  phone: z.string().trim().min(6).max(20),
  code: z
    .string()
    .trim()
    .regex(/^\d{4,8}$/, 'Code invalide'),
  confirm: z.string().trim(),
});

/** Pages légales publiques et suppression du compte depuis le web (exigée par Google Play). */
@Controller()
export class LegalController {
  constructor(
    private readonly auth: AuthService,
    private readonly closure: ClosureService,
  ) {}

  @Public()
  @Get(['cgu', 'conditions'])
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header('Cache-Control', 'public, max-age=3600')
  terms() {
    return termsPage();
  }

  @Public()
  @Get(['confidentialite', 'privacy'])
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header('Cache-Control', 'public, max-age=3600')
  privacy() {
    return privacyPage();
  }

  @Public()
  @Get(['suppression-compte', 'delete-account'])
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header('Cache-Control', 'public, max-age=3600')
  deletion() {
    return deletionPage();
  }

  /** Le code reçu prouve la possession du numéro ; même suppression que dans l'application. */
  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('v1/public/account-deletion')
  @HttpCode(200)
  async deleteAccount(@Body() body: unknown) {
    const b = parse(DeletionRequest, body);
    if (b.confirm.toUpperCase() !== 'SUPPRIMER') {
      throw new AppError('VALIDATION_FAILED', 'Tapez SUPPRIMER pour confirmer', 422);
    }
    const userId = await this.auth.verifyForDeletion(b.phone, b.code);
    return this.closure.deleteAccount(userId, b.confirm);
  }
}
