import { createParamDecorator, ExecutionContext, SetMetadata } from '@nestjs/common';
import type { ModuleKey, Permission } from '@sama360/contracts';
import { AppError } from '../http/app-error';
import type { AppRequest, AuthUser, TenantContext } from './auth.types';

export const IS_PUBLIC = 'sama:isPublic';
export const REQUIRED_PERMISSION = 'sama:permission';
export const REQUIRED_MODULE = 'sama:module';
export const TENANT_SCOPED = 'sama:tenant';

/** Route accessible sans jeton. */
export const Public = () => SetMetadata(IS_PUBLIC, true);

/** Route qui agit dans une entreprise (en-tête X-Business-Id), sans permission particulière. */
export const TenantScoped = () => SetMetadata(TENANT_SCOPED, true);

/** Exige une permission dans l'entreprise courante (implique TenantScoped). */
export const RequirePermission = (permission: Permission) => SetMetadata(REQUIRED_PERMISSION, permission);

/** Exige que le module soit activé pour l'entreprise courante. */
export const RequireModule = (module: ModuleKey) => SetMetadata(REQUIRED_MODULE, module);

export const CurrentUser = createParamDecorator((_: unknown, ctx: ExecutionContext): AuthUser => {
  const req = ctx.switchToHttp().getRequest<AppRequest>();
  if (!req.user) throw new AppError('UNAUTHENTICATED', 'Authentification requise', 401);
  return req.user;
});

export const CurrentTenant = createParamDecorator((_: unknown, ctx: ExecutionContext): TenantContext => {
  const req = ctx.switchToHttp().getRequest<AppRequest>();
  if (!req.tenant) throw new AppError('BUSINESS_REQUIRED', 'En-tête X-Business-Id requis', 400);
  return req.tenant;
});
