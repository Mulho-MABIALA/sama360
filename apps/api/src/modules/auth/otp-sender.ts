import { Injectable, Logger } from '@nestjs/common';
import { env } from '../../shared/config/env';

export const OTP_SENDER = Symbol('OTP_SENDER');

/** Canal d'envoi des codes (SMS, WhatsApp…). Une implémentation par fournisseur. */
export interface OtpSender {
  send(phone: string, code: string): Promise<void>;
}

/** Envoi impossible chez le fournisseur : l'utilisateur doit pouvoir réessayer tout de suite. */
export class SmsDeliveryError extends Error {
  constructor(
    readonly provider: string,
    readonly status: number,
    detail: string,
  ) {
    super(`${provider} : envoi du SMS refusé (${status}) ${detail}`.trim());
  }
}

/** Texte du SMS : court (un seul SMS de 160 caractères), sans accent qui doublerait le coût. */
export function otpMessage(code: string, ttlSeconds: number): string {
  const minutes = Math.max(1, Math.round(ttlSeconds / 60));
  return `Sama360 : votre code de connexion est ${code}. Il expire dans ${minutes} min. Ne le donnez a personne.`;
}

/** Numéro E.164 sans le « + » (Orange l'attend après « tel:+ »). */
const digits = (phone: string) => phone.replace(/\D/g, '');

/**
 * Développement et tests : le code est écrit dans les logs et gardé en mémoire.
 * Interdit en production, sauf dérogation explicite (OTP_CONSOLE_IN_PRODUCTION=true).
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

type Fetch = typeof fetch;

/**
 * Orange SMS API (Sénégal et autres pays Orange) : jeton OAuth 2.0 v3 puis
 * POST /smsmessaging/v1/outbound/tel:+<expéditeur>/requests.
 * Le jeton est gardé en mémoire jusqu'à peu avant son expiration.
 */
export class OrangeSmsSender implements OtpSender {
  private token: { value: string; until: number } | null = null;

  constructor(
    private readonly cfg: {
      clientId: string;
      clientSecret: string;
      sender: string;
      senderName?: string;
    },
    private readonly ttlSeconds: number,
    private readonly http: Fetch = fetch,
  ) {}

  private async accessToken(force = false): Promise<string> {
    if (!force && this.token && Date.now() < this.token.until) return this.token.value;
    const basic = Buffer.from(`${this.cfg.clientId}:${this.cfg.clientSecret}`).toString('base64');
    const res = await this.http('https://api.orange.com/oauth/v3/token', {
      method: 'POST',
      headers: {
        Authorization: `Basic ${basic}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: 'grant_type=client_credentials',
    });
    if (!res.ok) throw new SmsDeliveryError('Orange', res.status, 'jeton refusé');
    const body = (await res.json()) as {
      access_token: string;
      expires_in?: number;
    };
    this.token = {
      value: body.access_token,
      until: Date.now() + ((body.expires_in ?? 3600) - 60) * 1000,
    };
    return body.access_token;
  }

  async send(phone: string, code: string): Promise<void> {
    const sender = digits(this.cfg.sender);
    const url = `https://api.orange.com/smsmessaging/v1/outbound/${encodeURIComponent(`tel:+${sender}`)}/requests`;
    const payload = JSON.stringify({
      outboundSMSMessageRequest: {
        address: `tel:+${digits(phone)}`,
        senderAddress: `tel:+${sender}`,
        ...(this.cfg.senderName ? { senderName: this.cfg.senderName } : {}),
        outboundSMSTextMessage: { message: otpMessage(code, this.ttlSeconds) },
      },
    });
    const post = async (token: string) =>
      this.http(url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: payload,
      });
    let res = await post(await this.accessToken());
    if (res.status === 401) res = await post(await this.accessToken(true)); // jeton révoqué : un seul nouvel essai
    if (!res.ok) throw new SmsDeliveryError('Orange', res.status, (await res.text()).slice(0, 200));
  }
}

/** Twilio : POST /2010-04-01/Accounts/<sid>/Messages.json (expéditeur ou service de messagerie). */
export class TwilioSmsSender implements OtpSender {
  constructor(
    private readonly cfg: {
      accountSid: string;
      authToken: string;
      from?: string;
      messagingServiceSid?: string;
    },
    private readonly ttlSeconds: number,
    private readonly http: Fetch = fetch,
  ) {}

  async send(phone: string, code: string): Promise<void> {
    const form = new URLSearchParams({
      To: `+${digits(phone)}`,
      Body: otpMessage(code, this.ttlSeconds),
    });
    if (this.cfg.messagingServiceSid) form.set('MessagingServiceSid', this.cfg.messagingServiceSid);
    else form.set('From', this.cfg.from!);
    const basic = Buffer.from(`${this.cfg.accountSid}:${this.cfg.authToken}`).toString('base64');
    const res = await this.http(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.cfg.accountSid)}/Messages.json`,
      {
        method: 'POST',
        headers: {
          Authorization: `Basic ${basic}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.toString(),
      },
    );
    if (!res.ok) throw new SmsDeliveryError('Twilio', res.status, (await res.text()).slice(0, 200));
  }
}

/** Choisit le fournisseur selon OTP_PROVIDER (la configuration est validée au démarrage). */
export function createOtpSender(consoleSender: ConsoleOtpSender): OtpSender {
  const e = env();
  switch (e.OTP_PROVIDER) {
    case 'orange':
      return new OrangeSmsSender(
        {
          clientId: e.ORANGE_SMS_CLIENT_ID!,
          clientSecret: e.ORANGE_SMS_CLIENT_SECRET!,
          sender: e.ORANGE_SMS_SENDER!,
          senderName: e.ORANGE_SMS_SENDER_NAME,
        },
        e.OTP_TTL_SECONDS,
      );
    case 'twilio':
      return new TwilioSmsSender(
        {
          accountSid: e.TWILIO_ACCOUNT_SID!,
          authToken: e.TWILIO_AUTH_TOKEN!,
          from: e.TWILIO_FROM,
          messagingServiceSid: e.TWILIO_MESSAGING_SERVICE_SID,
        },
        e.OTP_TTL_SECONDS,
      );
    default:
      if (e.NODE_ENV === 'production') {
        new Logger('OTP').warn(
          'OTP_PROVIDER=console en production : les codes ne partent pas par SMS (logs seulement)',
        );
      }
      return consoleSender;
  }
}
