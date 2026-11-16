import { Injectable } from '@nestjs/common';
import type { CustomerBalanceAdjusted, CustomerRepaymentRecorded, SaleCompleted, SaleVoided } from '@sama360/contracts';
import { sql } from 'drizzle-orm';
import type { Tx } from '../../shared/db/db.service';
import { OnDomainEvent } from '../../shared/events/on-domain-event.decorator';

/**
 * Tient à jour contacts.balance, le cache du solde dû affiché dans l'annuaire.
 * La source de vérité reste le carnet de crédit (sales.customer_ledger).
 */
@Injectable()
export class ContactBalanceHandlers {
  private async add(tx: Tx, customerId: string, delta: number) {
    if (delta === 0) return;
    await tx.execute(
      sql`UPDATE contacts.contacts SET balance = balance + ${delta}, updated_at = now() WHERE id = ${customerId}`,
    );
  }

  @OnDomainEvent('sale.completed')
  async onSale(event: SaleCompleted, tx: Tx) {
    if (event.payload.customerId && event.payload.due > 0) await this.add(tx, event.payload.customerId, event.payload.due);
  }

  @OnDomainEvent('sale.voided')
  async onVoid(event: SaleVoided, tx: Tx) {
    if (event.payload.customerId && event.payload.due > 0) await this.add(tx, event.payload.customerId, -event.payload.due);
  }

  @OnDomainEvent('customer.repayment_recorded')
  async onRepayment(event: CustomerRepaymentRecorded, tx: Tx) {
    await this.add(tx, event.payload.customerId, -event.payload.amount);
  }

  @OnDomainEvent('customer.balance_adjusted')
  async onAdjustment(event: CustomerBalanceAdjusted, tx: Tx) {
    await this.add(tx, event.payload.customerId, event.payload.amount);
  }
}
