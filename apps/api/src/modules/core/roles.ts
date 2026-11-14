import type { RoleKey } from '@sama360/contracts';

/** Identifiants fixes des rôles système, insérés par la migration 0001. */
export const SYSTEM_ROLE_IDS: Record<RoleKey, string> = {
  owner: '01930000-0000-7000-8000-000000000001',
  manager: '01930000-0000-7000-8000-000000000002',
  cashier: '01930000-0000-7000-8000-000000000003',
  accountant: '01930000-0000-7000-8000-000000000004',
};
