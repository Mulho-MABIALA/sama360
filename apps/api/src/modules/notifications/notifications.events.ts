import { Injectable, Logger } from '@nestjs/common';
import type { BusinessCreated, MemberInvited, StockLow } from '@sama360/contracts';
import { OnDomainEvent } from '../../shared/events/on-domain-event.decorator';

/**
 * Premiers abonnés du module notifications. Pour l'instant ils journalisent ;
 * les envois réels (WhatsApp Business, SMS, push FCM) arriveront avec les fournisseurs.
 */
@Injectable()
export class NotificationEventHandlers {
  private readonly logger = new Logger('Notifications');

  @OnDomainEvent('business.created')
  async welcome(event: BusinessCreated): Promise<void> {
    this.logger.log(`[bienvenue] ${event.payload.name} (${event.businessId})`);
  }

  @OnDomainEvent('member.invited')
  async inviteMember(event: MemberInvited): Promise<void> {
    this.logger.log(`[invitation] ${event.payload.phone} → rôle ${event.payload.roleKey}`);
  }

  @OnDomainEvent('stock.low')
  async stockLow(event: StockLow): Promise<void> {
    this.logger.log(`[stock bas] ${event.payload.name} : ${event.payload.onHand} restant(s) (seuil ${event.payload.threshold})`);
  }
}
