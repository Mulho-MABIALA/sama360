/**
 * Services que le commerçant peut afficher ou masquer selon son métier (l'app décide des valeurs
 * par défaut : apps/mobile/lib/core/trades.dart). Ventes, caisse, stock, clients, dépenses
 * et rapports sont toujours là.
 */
export const BIZ_SERVICES = [
  'invoices',
  'purchases',
  'delivery',
  'shop',
  'booking',
  'loyalty',
  'reminders',
  'documents',
  'team',
  'assistant',
] as const;
export type BizService = (typeof BIZ_SERVICES)[number];
