import { Injectable, Logger } from '@nestjs/common';
import type { BusinessCreated, MemberInvited } from '@sama360/contracts';
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
}
