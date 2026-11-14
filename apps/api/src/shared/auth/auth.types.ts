import type { Request } from 'express';

export interface AuthUser {
  id: string;
}

export interface TenantContext {
  businessId: string;
  membershipId: string;
  roleKey: string;
  permissions: string[];
  modules: string[];
}

export interface AppRequest extends Request {
  user?: AuthUser;
  tenant?: TenantContext;
}

export interface AccessTokenPayload {
  sub: string;
  typ: 'access';
}
