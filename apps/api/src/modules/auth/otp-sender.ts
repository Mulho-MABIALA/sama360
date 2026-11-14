import { Injectable, Logger } from '@nestjs/common';

export const OTP_SENDER = Symbol('OTP_SENDER');

/** Canal d'envoi des codes (SMS, WhatsApp…). Une implémentation par fournisseur. */
export interface OtpSender {
  send(phone: string, code: string): Promise<void>;
}

/**
 * Développement et tests : le code est écrit dans les logs et gardé en mémoire.
 * Ne JAMAIS utiliser en production.
 */
@Injectable()
export class ConsoleOtpSender implements OtpSender {
  private readonly logger = new Logger('OTP');
  readonly sent = new Map<string, string>();

  async send(phone: string, code: string): Promise<void> {
    this.sent.set(phone, code);
    this.logger.log(`Code de connexion pour ${phone} : ${code}`);
  }
}
