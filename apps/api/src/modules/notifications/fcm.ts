import { createSign } from 'node:crypto';

/**
 * Firebase Cloud Messaging (API HTTP v1), sans SDK : jeton OAuth2 signé avec la clé
 * du compte de service, puis un envoi par appareil.
 */

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

/** Clé du compte de service : JSON brut ou en base64 (plus simple à coller dans Render). */
export function parseServiceAccount(raw: string): ServiceAccount {
  const text = raw.trim().startsWith('{') ? raw : Buffer.from(raw.trim(), 'base64').toString('utf8');
  const sa = JSON.parse(text) as Partial<ServiceAccount>;
  if (!sa.project_id || !sa.client_email || !sa.private_key) {
    throw new Error('Clé Firebase incomplète : project_id, client_email et private_key attendus');
  }
  // Collée dans un champ d'une seule ligne : les retours à la ligne deviennent « \n »
  return { ...sa, private_key: sa.private_key.replace(/\\n/g, '\n') } as ServiceAccount;
}

export interface PushMessage {
  title: string;
  body: string;
  /** Écran de l'app à ouvrir (/shop/orders/…) */
  link?: string | null;
  /** Adresse publique du site, pour ouvrir la version web au bon écran */
  webBase?: string | null;
}

export type SendResult = 'sent' | 'unregistered' | 'failed';

type Fetch = typeof fetch;
const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export class FcmClient {
  private token?: { value: string; expiresAt: number };

  constructor(
    private readonly sa: ServiceAccount,
    private readonly http: Fetch = fetch,
  ) {}

  get projectId() {
    return this.sa.project_id;
  }

  /** Jeton d'accès OAuth2 (1 h), gardé en mémoire jusqu'à 5 minutes de sa fin. */
  async accessToken(now = Date.now()): Promise<string> {
    if (this.token && this.token.expiresAt - 300_000 > now) return this.token.value;
    const iat = Math.floor(now / 1000);
    const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const claims = b64url(
      JSON.stringify({
        iss: this.sa.client_email,
        scope: 'https://www.googleapis.com/auth/firebase.messaging',
        aud: 'https://oauth2.googleapis.com/token',
        iat,
        exp: iat + 3600,
      }),
    );
    const signer = createSign('RSA-SHA256');
    signer.update(`${header}.${claims}`);
    const jwt = `${header}.${claims}.${b64url(signer.sign(this.sa.private_key))}`;
    const res = await this.http('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
      signal: AbortSignal.timeout(15_000),
    });
    const body = (await res.json().catch(() => ({}))) as { access_token?: string; expires_in?: number; error?: string };
    if (!res.ok || !body.access_token) throw new Error(`Jeton Firebase refusé : ${body.error ?? res.status}`);
    this.token = { value: body.access_token, expiresAt: now + (body.expires_in ?? 3600) * 1000 };
    return body.access_token;
  }

  /** Envoie à un appareil. « unregistered » : jeton périmé (app désinstallée…), à oublier. */
  async send(deviceToken: string, msg: PushMessage): Promise<SendResult> {
    const link = msg.link ?? '/notifications';
    const res = await this.http(`https://fcm.googleapis.com/v1/projects/${this.sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await this.accessToken()}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token: deviceToken,
          notification: { title: msg.title, body: msg.body },
          data: { link },
          android: { priority: 'high', notification: { sound: 'default' } },
          webpush: {
            notification: { icon: '/app/icons/Icon-192.png', badge: '/app/icons/Icon-192.png' },
            ...(msg.webBase ? { fcm_options: { link: `${msg.webBase.replace(/\/$/, '')}/app/#${link}` } } : {}),
          },
        },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    if (res.ok) return 'sent';
    const err = (await res.json().catch(() => ({}))) as {
      error?: { status?: string; details?: Array<{ errorCode?: string }> };
    };
    const code = err.error?.details?.find((d) => d.errorCode)?.errorCode ?? err.error?.status;
    if (res.status === 404 || code === 'UNREGISTERED') return 'unregistered';
    return 'failed';
  }
}
