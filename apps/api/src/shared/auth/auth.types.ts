import { CountryCode } from '../countries';
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
  /** Pays de l'entreprise (indicatif par défaut des numéros, moyens de paiement). */
  country: CountryCode;
}

export interface AppRequest extends Request {
  user?: AuthUser;
  tenant?: TenantContext;
}

export interface AccessTokenPayload {
  sub: string;
  typ: 'access';
}
