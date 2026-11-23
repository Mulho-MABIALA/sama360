/** Modules de la plateforme. Les modules de vague 2 et 3 sont listés pour l'accueil (« Bientôt »). */
export const MODULES = [
  'sales',
  'inventory',
  'invoicing',
  'shop',
  'payments',
  'documents',
  'delivery',
  'booking',
  'assistant',
  'projects',
] as const;
export type ModuleKey = (typeof MODULES)[number];

/** Modules activés par défaut à la création d'une entreprise (vague 1). */
export const DEFAULT_MODULES: ModuleKey[] = ['sales', 'inventory', 'invoicing', 'shop', 'payments', 'documents'];

/** Permissions au format `domaine:action`. `domaine:*` donne toutes les actions, `*` donne tout. */
export const PERMISSIONS = [
  'business:read',
  'business:update',
  'members:read',
  'members:invite',
  'members:manage',
  'contacts:read',
  'contacts:write',
  'catalog:read',
  'catalog:write',
  'sales:read',
  'sales:create',
  'sales:void',
  'inventory:read',
  'inventory:write',
  'purchasing:read',
  'purchasing:write',
  'invoicing:read',
  'invoicing:write',
  'payments:read',
  'payments:collect',
  'reports:read',
  'documents:read',
  'documents:write',
  'subscription:manage',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const ROLE_KEYS = ['owner', 'manager', 'cashier', 'accountant'] as const;
export type RoleKey = (typeof ROLE_KEYS)[number];

/** Vrai si l'ensemble `granted` couvre la permission demandée (gère `*` et `domaine:*`). */
export function hasPermission(granted: readonly string[], required: string): boolean {
  if (granted.includes('*') || granted.includes(required)) return true;
  const [domain] = required.split(':');
  return granted.includes(`${domain}:*`);
}
