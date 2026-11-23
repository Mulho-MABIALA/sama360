import { sql } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import type { Tx } from '../../shared/db/db.service';

/**
 * Notifications envoyées aussi sur le téléphone (ou le navigateur). Les autres (astuces,
 * premiers pas) restent dans la cloche de l'app.
 */
export const PUSH_KINDS = new Set([
  'shop_order',
  'appointment_online',
  'stock_low',
  'credit_stale',
  'invoices_overdue',
  'sale_voided',
  'cash_open',
  'cash_open_team',
  'appointments_today',
  'document_expiring',
  'weekly_report',
  'pro_active',
  'pro_rejected',
  'pro_ending',
  'pro_ended',
  'referral_reward',
]);

/** Met une notification dans la file d'envoi push (même transaction que sa création). */
export async function enqueuePush(tx: Tx, businessId: string, notificationId: string, kind: string) {
  if (!PUSH_KINDS.has(kind) || !env().FCM_SERVICE_ACCOUNT) return;
  await tx.execute(sql`
    INSERT INTO core.push_queue (notification_id, business_id) VALUES (${notificationId}, ${businessId})
    ON CONFLICT DO NOTHING`);
}
