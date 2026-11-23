import { z } from 'zod';

const secret = z.string().min(32, 'doit contenir au moins 32 caractères');

const BaseSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  DATABASE_URL: z.string().url(),
  DATABASE_URL_DIRECT: z.string().url().optional(),
  DATABASE_POOL_MAX: z.coerce.number().int().positive().default(10),
  REDIS_URL: z.string().default('redis://localhost:6379'),
  JWT_ACCESS_SECRET: secret,
  JWT_REFRESH_SECRET: secret,
  JWT_ACCESS_TTL: z
    .string()
    .regex(/^\d+[smhd]$/, 'format attendu : 15m, 1h, 30s…')
    .default('15m'),
  REFRESH_TTL_DAYS: z.coerce.number().int().positive().default(30),
  OTP_SECRET: secret,
  // Envoi des codes : console (logs, développement), orange (Orange SMS API) ou twilio
  OTP_PROVIDER: z.enum(['console', 'orange', 'twilio', 'twilio_verify']).default('console'),
  OTP_CONSOLE_IN_PRODUCTION: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
  ORANGE_SMS_CLIENT_ID: z.string().min(1).optional(),
  ORANGE_SMS_CLIENT_SECRET: z.string().min(1).optional(),
  ORANGE_SMS_SENDER: z
    .string()
    .regex(/^\+?\d{4,15}$/, 'numéro expéditeur, ex. +2210000')
    .optional(),
  ORANGE_SMS_SENDER_NAME: z.string().max(11).optional(),
  TWILIO_ACCOUNT_SID: z.string().min(1).optional(),
  TWILIO_AUTH_TOKEN: z.string().min(1).optional(),
  TWILIO_FROM: z.string().min(1).optional(),
  TWILIO_MESSAGING_SERVICE_SID: z.string().min(1).optional(),
  // Twilio Verify : Twilio crée, envoie et vérifie le code (numéros et conformité gérés par pays)
  TWILIO_VERIFY_SERVICE_SID: z.string().min(1).optional(),
  // Moyen proposé d'abord : whatsapp, sms ou call (appel vocal qui dicte le code)
  OTP_CHANNEL: z.enum(['sms', 'whatsapp', 'call']).default('sms'),
  // Moyens au choix du commerçant (Twilio Verify), séparés par des virgules.
  // WhatsApp seulement une fois un expéditeur WhatsApp Business relié au service Verify.
  OTP_CHANNELS: z
    .string()
    .default('sms,call')
    .transform((v) => v.split(',').map((c) => c.trim()))
    .pipe(z.array(z.enum(['sms', 'whatsapp', 'call'])).min(1)),
  OTP_TTL_SECONDS: z.coerce.number().int().positive().default(300),
  OTP_MAX_ATTEMPTS: z.coerce.number().int().positive().default(5),
  OUTBOX_POLL_MS: z.coerce.number().int().positive().default(1000),
  // Fichiers : disque local en développement / sur VPS (S3 ou R2 à brancher plus tard)
  // Fichiers : local (disque) ou s3 (Cloudflare R2, AWS S3, Backblaze… tout service compatible S3)
  STORAGE_DRIVER: z.enum(['local', 's3']).default('local'),
  STORAGE_DIR: z.string().optional(), // défaut : apps/api/storage
  S3_BUCKET: z.string().min(1).optional(),
  S3_REGION: z.string().default('auto'),
  S3_ENDPOINT: z.string().url().optional(), // R2 : https://<compte>.r2.cloudflarestorage.com
  S3_ACCESS_KEY_ID: z.string().min(1).optional(),
  S3_SECRET_ACCESS_KEY: z.string().min(1).optional(),
  // Derrière un hébergeur ou un proxy (Render, Caddy…) : nombre de proxys à croire pour l'IP du client
  TRUST_PROXY: z.coerce.number().int().min(0).max(5).default(0),
  // Version web de l'app (flutter build web --base-href /app/) servie sur /app ; par défaut ../../builds/web
  WEB_APP_DIR: z.string().optional(),
  // Faire tourner le worker (outbox + abonnés) dans le process de l'API : un seul service à héberger
  RUN_WORKER: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
  // Lancer les migrations SQL au démarrage de l'API (un seul service doit le faire)
  MIGRATE_ON_START: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
  MAX_UPLOAD_MB: z.coerce.number().positive().max(20).default(5),
  // Assistant IA : « anthropic » (clé requise), « fake » (tests, démonstration) ou « off »
  ASSISTANT_PROVIDER: z.enum(['off', 'anthropic', 'fake']).default('off'),
  ANTHROPIC_API_KEY: z.string().min(1).optional(),
  ASSISTANT_MODEL: z.string().default('claude-haiku-5-5'),
  // Questions par boutique et par jour (maîtrise du coût)
  ASSISTANT_DAILY_LIMIT: z.coerce.number().int().min(1).max(10000).default(60),
  // Lecture des factures fournisseurs en photo (même fournisseur d'IA que l'assistant)
  SCAN_MODEL: z.string().optional(),
  SCAN_DAILY_LIMIT: z.coerce.number().int().min(1).max(10000).default(20),
  // Sama360 Pro : numéros de l'équipe qui valident les paiements (ex. "+221771234567,+242061234567")
  ADMIN_PHONES: z.string().optional(),
  // Où payer l'abonnement, affiché aux commerçants (ex. "Wave ou Orange Money au 77 123 45 67 — Zolaa Tech")
  PRO_PAY_TO_SN: z.string().optional(),
  PRO_PAY_TO_CI: z.string().optional(),
  PRO_PAY_TO_CG: z.string().optional(),
  // Paiement en ligne de Pro par Chariow (Wave, Orange Money, MoMo, carte…). Sans clé : paiement manuel seulement.
  CHARIOW_API_KEY: z.string().min(1).optional(),
  CHARIOW_API_URL: z.string().url().default('https://api.chariow.com/v1'),
  // Secret de signature du Pulse (whsec_…), dans Chariow : Automatisations → Pulses → le Pulse → Overview
  CHARIOW_PULSE_SECRET: z.string().min(1).optional(),
  // Produits Chariow (type Licence, achetable plusieurs fois) : prix du mois et de l'année
  CHARIOW_PRODUCT_MONTHLY: z.string().min(1).optional(),
  CHARIOW_PRODUCT_YEARLY: z.string().min(1).optional(),
  // Adresse publique (retour après paiement) ; par défaut, celle de la requête
  PUBLIC_URL: z.string().url().optional(),
  // Notifications push (Firebase Cloud Messaging). Clé du compte de service : le JSON
  // téléchargé dans Firebase (Paramètres → Comptes de service), tel quel ou en base64.
  FCM_SERVICE_ACCOUNT: z.string().min(1).optional(),
  // Version web (navigateur, iPhone ajouté à l'écran d'accueil) : appli Web Firebase + clé VAPID
  FIREBASE_WEB_API_KEY: z.string().min(1).optional(),
  FIREBASE_WEB_APP_ID: z.string().min(1).optional(),
  FIREBASE_VAPID_KEY: z.string().min(1).optional(),
});

/** Règles entre variables : chaque fournisseur choisi doit avoir ses identifiants. */
const EnvSchema = BaseSchema.superRefine((e, ctx) => {
  const need = (keys: (keyof typeof e)[], why: string) => {
    for (const k of keys)
      if (!e[k])
        ctx.addIssue({
          code: 'custom',
          path: [k],
          message: `obligatoire avec ${why}`,
        });
  };
  if (e.OTP_PROVIDER === 'orange') {
    need(['ORANGE_SMS_CLIENT_ID', 'ORANGE_SMS_CLIENT_SECRET', 'ORANGE_SMS_SENDER'], 'OTP_PROVIDER=orange');
  }
  if (e.OTP_PROVIDER === 'twilio') {
    need(['TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN'], 'OTP_PROVIDER=twilio');
    if (!e.TWILIO_FROM && !e.TWILIO_MESSAGING_SERVICE_SID) {
      ctx.addIssue({
        code: 'custom',
        path: ['TWILIO_FROM'],
        message: 'TWILIO_FROM ou TWILIO_MESSAGING_SERVICE_SID requis',
      });
    }
  }
  if (e.OTP_PROVIDER === 'twilio_verify') {
    need(['TWILIO_ACCOUNT_SID', 'TWILIO_AUTH_TOKEN', 'TWILIO_VERIFY_SERVICE_SID'], 'OTP_PROVIDER=twilio_verify');
  }
  if (e.NODE_ENV === 'production' && e.OTP_PROVIDER === 'console' && !e.OTP_CONSOLE_IN_PRODUCTION) {
    ctx.addIssue({
      code: 'custom',
      path: ['OTP_PROVIDER'],
      message:
        'console interdit en production (choisir twilio_verify, twilio ou orange, ou OTP_CONSOLE_IN_PRODUCTION=true pour un test)',
    });
  }
  if (e.ASSISTANT_PROVIDER === 'anthropic') need(['ANTHROPIC_API_KEY'], 'ASSISTANT_PROVIDER=anthropic');
  if (e.CHARIOW_API_KEY) {
    need(['CHARIOW_PULSE_SECRET', 'CHARIOW_PRODUCT_MONTHLY', 'CHARIOW_PRODUCT_YEARLY'], 'CHARIOW_API_KEY');
  }
  if (e.STORAGE_DRIVER === 's3') {
    need(['S3_BUCKET', 'S3_ACCESS_KEY_ID', 'S3_SECRET_ACCESS_KEY'], 'STORAGE_DRIVER=s3');
  }
});

export type Env = z.infer<typeof EnvSchema>;

let cached: Env | undefined;

/** Lit et valide les variables d'environnement une seule fois ; échoue au démarrage si invalide. */
export function env(): Env {
  if (cached) return cached;
  // Une variable laissée vide (champ non rempli sur l'hébergeur) compte comme absente
  const raw = Object.fromEntries(Object.entries(process.env).filter(([, v]) => v !== undefined && v.trim() !== ''));
  const parsed = EnvSchema.safeParse(raw);
  if (!parsed.success) {
    const details = parsed.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Configuration invalide :\n${details}`);
  }
  cached = parsed.data;
  return cached;
}

/** Réservé aux tests. */
export function resetEnvCache(): void {
  cached = undefined;
}
