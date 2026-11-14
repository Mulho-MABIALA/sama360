import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { env } from '../config/env';
import { AppError } from '../http/app-error';
import type { AccessTokenPayload, AppRequest } from './auth.types';
import { IS_PUBLIC } from './decorators';

/** Garde globale : toute route exige un jeton d'accès valide, sauf @Public(). */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, [ctx.getHandler(), ctx.getClass()]);
    if (isPublic) return true;

    const req = ctx.switchToHttp().getRequest<AppRequest>();
    const header = req.headers.authorization ?? '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new AppError('UNAUTHENTICATED', 'Authentification requise', 401);
    }
    try {
      const payload = await this.jwt.verifyAsync<AccessTokenPayload>(token, { secret: env().JWT_ACCESS_SECRET });
      if (payload.typ !== 'access') throw new Error('mauvais type de jeton');
      req.user = { id: payload.sub };
      return true;
    } catch {
      throw new AppError('TOKEN_INVALID', 'Jeton invalide ou expiré', 401);
    }
  }
}
