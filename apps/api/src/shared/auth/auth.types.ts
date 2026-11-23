import { hasPermission } from '@sama360/contracts';
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
  /** Sama360 Pro actif (essai ou abonnement payé en cours). */
  pro: boolean;
  /**
   * Point de vente où s'écrivent ventes, caisse, réceptions et mouvements de stock :
   * celui du vendeur rattaché, sinon celui choisi (en-tête X-Location-Id), sinon le principal.
   */
  warehouseId: string;
  /** Filtre des lectures (ventes, rapports, stock) : un point de vente, ou null = tous. */
  locationFilter: string | null;
  /** Vendeur rattaché à un point de vente : il ne peut pas en changer. */
  locationLocked: boolean;
}

export interface AppRequest extends Request {
  user?: AuthUser;
  tenant?: TenantContext;
}

export interface AccessTokenPayload {
  sub: string;
  typ: 'access';
}

/**
 * Point de vente d'une écriture : celui du vendeur rattaché (imposé), sinon celui indiqué
 * dans la requête (vente hors ligne enregistrée plus tard), sinon le point de vente actif.
 */
export function locationFor(t: TenantContext, requested?: string | null): string {
  return t.locationLocked ? t.warehouseId : (requested ?? t.warehouseId);
}

/**
 * Prix d'achat, marges et valeur du stock : réservés à qui voit les rapports ou gère le catalogue
 * (propriétaire, gérant, comptable). Un vendeur ne les voit pas.
 */
export function seesCosts(t: Pick<TenantContext, 'permissions'>): boolean {
  return hasPermission(t.permissions, 'reports:read') || hasPermission(t.permissions, 'catalog:write');
}

/** Retire le prix d'achat d'un produit pour qui ne doit pas le voir. */
export function hideCost<T extends { cost?: unknown }>(t: Pick<TenantContext, 'permissions'>, p: T): T {
  return seesCosts(t) ? p : { ...p, cost: null };
}
