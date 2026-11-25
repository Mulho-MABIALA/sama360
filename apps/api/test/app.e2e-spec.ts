/**
 * Parcours de bout en bout du socle Sama360 :
 * OTP → profil → entreprise → événements (outbox → BullMQ → abonnés) → catalogue,
 * contacts, isolation entre entreprises (RLS), invitations et rôles, rotation des sessions.
 *
 * Prérequis : une base de test vide accessible par un rôle NON superutilisateur
 * (TEST_DATABASE_URL) et Redis (REDIS_URL). La base est réinitialisée au début.
 */
const TEST_DB = process.env.TEST_DATABASE_URL ?? 'postgresql://sama_app:sama@localhost:5433/sama360_test';
process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = TEST_DB;
process.env.REDIS_URL = process.env.REDIS_URL ?? 'redis://localhost:6379';
process.env.JWT_ACCESS_SECRET = 'test-access-secret-0123456789-abcdefghij';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret-0123456789-abcdefghij';
process.env.OTP_SECRET = 'test-otp-secret-0123456789-abcdefghijklmn';
process.env.MAX_UPLOAD_MB = '1';
process.env.ASSISTANT_PROVIDER = 'fake'; // faux modèle : toute la chaîne testée sans API payante
process.env.ASSISTANT_DAILY_LIMIT = '6';
process.env.ADMIN_PHONES = '+221700000099'; // équipe Sama360 (validation des paiements Pro)
process.env.REVIEW_PHONE = '+221700000777'; // compte de démonstration pour la validation Play Store
process.env.REVIEW_CODE = '246810';
process.env.PRO_PAY_TO_SN = 'Wave au 77 000 00 00 (Zolaa Tech)';
// Paiement en ligne Chariow : l'API est simulée (fetch), les Pulses sont signés avec ce secret
process.env.CHARIOW_API_KEY = 'sk_test_sama';
process.env.CHARIOW_API_URL = 'https://chariow.test/v1';
process.env.CHARIOW_PULSE_SECRET = 'whsec_test_sama';
process.env.CHARIOW_PRODUCT_MONTHLY = 'prd_mois';
process.env.CHARIOW_PRODUCT_YEARLY = 'prd_annee';
// Notifications push : clé factice (l'envoi est remplacé dans le test), appli Web Firebase
process.env.FCM_SERVICE_ACCOUNT = Buffer.from(
  JSON.stringify({ project_id: 'sama-test', client_email: 'push@sama-test.iam', private_key: 'x' }),
).toString('base64');
process.env.FIREBASE_WEB_API_KEY = 'AIzaTest';
process.env.FIREBASE_WEB_APP_ID = '1:4242:web:abc';
process.env.FIREBASE_VAPID_KEY = 'BTestVapid';
process.env.PUBLIC_URL = 'https://sama.test';
process.env.STORAGE_DIR = require('node:path').join(require('node:os').tmpdir(), `sama-e2e-${process.pid}`);

import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { ThrottlerStorage } from '@nestjs/throttler';
import { sql } from 'drizzle-orm';
import { Client } from 'pg';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { ConsoleOtpSender } from '../src/modules/auth/otp-sender';
import { DbService } from '../src/shared/db/db.service';
import { ClosureService } from '../src/modules/core/closure.service';
import { NotificationsService } from '../src/modules/notifications/notifications.service';
import { PushService } from '../src/modules/notifications/push.service';
import { contacts } from '../src/shared/db/schema';
import { migrate } from '../src/shared/db/migrate';
import { EventWorkerService } from '../src/shared/events/event-worker.service';
import { OutboxRelayService } from '../src/shared/events/outbox-relay.service';

async function resetDatabase(url: string) {
  const c = new Client({ connectionString: url });
  await c.connect();
  await c.query(`
    DROP SCHEMA IF EXISTS shop CASCADE;
    DROP SCHEMA IF EXISTS purchasing CASCADE;
    DROP SCHEMA IF EXISTS invoicing CASCADE;
    DROP SCHEMA IF EXISTS sales CASCADE;
    DROP SCHEMA IF EXISTS inventory CASCADE;
    DROP SCHEMA IF EXISTS catalog CASCADE;
    DROP SCHEMA IF EXISTS contacts CASCADE;
    DROP SCHEMA IF EXISTS core CASCADE;
    DROP TABLE IF EXISTS public.schema_migrations;`);
  const { rows } = await c.query<{ rolsuper: boolean; rolbypassrls: boolean }>(
    'SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user',
  );
  await c.end();
  if (rows[0]?.rolsuper || rows[0]?.rolbypassrls) {
    throw new Error('Le rôle de test ignore la RLS (SUPERUSER/BYPASSRLS) : utilisez un rôle applicatif.');
  }
  await migrate(url, () => undefined);
}

async function waitFor<T>(fn: () => Promise<T>, ok: (v: T) => boolean, timeoutMs = 10_000): Promise<T> {
  const start = Date.now();
  for (;;) {
    const v = await fn();
    if (ok(v)) return v;
    if (Date.now() - start > timeoutMs) throw new Error('Délai dépassé en attendant la condition');
    await new Promise((r) => setTimeout(r, 150));
  }
}

describe('Socle Sama360 (e2e)', () => {
  let app: INestApplication;
  let http: ReturnType<typeof request>;
  let otp: ConsoleOtpSender;
  let relay: OutboxRelayService;
  let worker: EventWorkerService;
  let dbs: DbService;

  const AWA = '+221771234567';
  const MOUSSA = '+221781112233';
  const FATOU = '+221765554433';

  let awa: { accessToken: string; refreshToken: string };
  let modouToken = ''; // vendeur créé dans « Clôture de caisse », réutilisé (codes OTP limités par numéro)
  let moussa: { accessToken: string; refreshToken: string };
  let awaBiz: string;
  let cashierToken: string;
  let cashierRefresh: string;
  let moussaBiz: string;
  let adminToken: string | undefined; // équipe Sama360, connectée une fois (codes limités par numéro)

  const auth = (token: string, businessId?: string) => {
    const h: Record<string, string> = { Authorization: `Bearer ${token}` };
    if (businessId) h['X-Business-Id'] = businessId;
    return h;
  };

  async function login(phone: string) {
    await http.post('/v1/auth/otp/request').send({ phone }).expect(200);
    const code = otp.sent.get(phone)!;
    const res = await http.post('/v1/auth/otp/verify').send({ phone, code }).expect(200);
    return res.body as { accessToken: string; refreshToken: string; isNewUser: boolean; user: { id: string } };
  }

  beforeAll(async () => {
    await resetDatabase(TEST_DB);
    // Le limiteur par adresse IP (10 codes/min) n'est pas testé ici : la suite se connecte des
    // dizaines de fois en quelques secondes depuis la même adresse.
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ThrottlerStorage)
      .useValue({ increment: async () => ({ totalHits: 1, timeToExpire: 60, isBlocked: false, timeToBlockExpire: 0 }) })
      .compile();
    app = moduleRef.createNestApplication({ rawBody: true });
    await app.init();
    http = request(app.getHttpServer());
    otp = app.get(ConsoleOtpSender);
    relay = app.get(OutboxRelayService);
    worker = app.get(EventWorkerService);
    dbs = app.get(DbService);
    worker.start(2);
  });

  afterAll(async () => {
    await app?.close();
  });

  it('GET /health', async () => {
    const res = await http.get('/health').expect(200);
    expect(res.body).toEqual({ status: 'ok', db: 'ok' });
  });

  describe('Authentification OTP', () => {
    it('SMS non parti : erreur claire et nouvel essai possible tout de suite', async () => {
      const spy = jest.spyOn(otp, 'send').mockRejectedValueOnce(new Error('Orange : crédit épuisé'));
      const r = await http.post('/v1/auth/otp/request').send({ phone: '78 000 11 22' }).expect(503);
      expect(r.body.error).toMatchObject({ code: 'SMS_FAILED', message: expect.stringContaining('autre moyen') });
      spy.mockRestore();
      // Pas de « patientez une minute » : le code non envoyé a été effacé
      await http.post('/v1/auth/otp/request').send({ phone: '78 000 11 22' }).expect(200);
      expect(otp.sent.get('+221780001122')).toMatch(/^\d{6}$/);
    });

    it('code par WhatsApp, SMS ou appel au choix ; changer de moyen plus vite qu’un renvoi', async () => {
      const { sql } = await import('drizzle-orm');
      expect((await http.get('/v1/auth/otp/channels').expect(200)).body).toEqual({
        channels: ['whatsapp', 'sms', 'call'],
        default: 'whatsapp',
      });
      const phone = '+221760001234';
      expect((await http.post('/v1/auth/otp/request').send({ phone }).expect(200)).body.channel).toBe('whatsapp');
      await http.post('/v1/auth/otp/request').send({ phone, channel: 'fax' }).expect(422);
      // Pas reçu sur WhatsApp : SMS après 15 s (pas une minute)
      const tooSoon = await http.post('/v1/auth/otp/request').send({ phone, channel: 'sms' }).expect(429);
      expect(tooSoon.body.error.message).toContain('changer de moyen');
      await dbs.db.execute(
        sql`UPDATE core.otp_codes SET created_at = now() - interval '16 seconds' WHERE phone = ${phone}`,
      );
      expect((await http.post('/v1/auth/otp/request').send({ phone, channel: 'sms' }).expect(200)).body.channel).toBe(
        'sms',
      );
      expect(otp.channelOf.get(phone)).toBe('sms');
      // Même moyen : toujours une minute
      await dbs.db.execute(
        sql`UPDATE core.otp_codes SET created_at = now() - interval '16 seconds' WHERE phone = ${phone}`,
      );
      await http.post('/v1/auth/otp/request').send({ phone, channel: 'sms' }).expect(429);
      await http.post('/v1/auth/otp/request').send({ phone, channel: 'call' }).expect(200);
      expect(otp.channelOf.get(phone)).toBe('call');
      // Le dernier code reçu connecte
      await http
        .post('/v1/auth/otp/verify')
        .send({ phone, code: otp.sent.get(phone) })
        .expect(200);
    });

    it('refuse un numéro invalide', async () => {
      const res = await http.post('/v1/auth/otp/request').send({ phone: '12345678' }).expect(422);
      expect(res.body.error.code).toBe('PHONE_INVALID');
    });

    it('envoie un code, refuse un mauvais code puis connecte avec le bon', async () => {
      const r1 = await http.post('/v1/auth/otp/request').send({ phone: '77 123 45 67' }).expect(200);
      expect(r1.body).toEqual({ phone: AWA, expiresIn: 300, channel: 'whatsapp' });

      const again = await http.post('/v1/auth/otp/request').send({ phone: AWA }).expect(429);
      expect(again.body.error.code).toBe('OTP_TOO_SOON');

      const code = otp.sent.get(AWA)!;
      const wrong = code === '000000' ? '111111' : '000000';
      const bad = await http.post('/v1/auth/otp/verify').send({ phone: AWA, code: wrong }).expect(400);
      expect(bad.body.error).toMatchObject({ code: 'OTP_INVALID', details: { remainingAttempts: 4 } });

      const ok = await http.post('/v1/auth/otp/verify').send({ phone: AWA, code, deviceId: 'pixel-7' }).expect(200);
      expect(ok.body.isNewUser).toBe(true);
      expect(ok.body.user.phone).toBe(AWA);
      awa = ok.body;

      // un code ne sert qu'une fois
      const reuse = await http.post('/v1/auth/otp/verify').send({ phone: AWA, code }).expect(400);
      expect(reuse.body.error.code).toBe('OTP_EXPIRED');
    });

    it('protège les routes et renvoie le profil', async () => {
      const anon = await http.get('/v1/me').expect(401);
      expect(anon.body.error.code).toBe('UNAUTHENTICATED');

      await http.patch('/v1/me').set(auth(awa.accessToken)).send({ fullName: 'Awa Diallo' }).expect(200);
      const me = await http.get('/v1/me').set(auth(awa.accessToken)).expect(200);
      expect(me.body.user).toMatchObject({ phone: AWA, fullName: 'Awa Diallo' });
      expect(me.body.businesses).toEqual([]);
    });
  });

  describe('Entreprise et événements', () => {
    it('crée une entreprise avec ses modules et son abonnement', async () => {
      const res = await http
        .post('/v1/businesses')
        .set(auth(awa.accessToken))
        .send({ name: 'Awa Beauté', category: 'boutique', city: 'Dakar' })
        .expect(201);
      awaBiz = res.body.business.id;
      expect(res.body.business.slug).toBe('awa-beaute');
      // Numéro de la boutique (reçus) : celui du compte, sans le ressaisir
      expect(res.body.business.phone).toBe(AWA);
      expect(res.body.modules).toEqual(expect.arrayContaining(['sales', 'inventory', 'invoicing', 'shop']));
      expect(res.body.subscription).toMatchObject({ plan: 'pro', status: 'trialing' }); // 30 jours d'essai Pro
    });

    it('exige X-Business-Id et renvoie mes droits', async () => {
      const no = await http.get('/v1/business').set(auth(awa.accessToken)).expect(400);
      expect(no.body.error.code).toBe('BUSINESS_REQUIRED');

      const res = await http.get('/v1/business').set(auth(awa.accessToken, awaBiz)).expect(200);
      expect(res.body.business.name).toBe('Awa Beauté');
      expect(res.body.me).toMatchObject({ role: 'owner', permissions: ['*'], location: { id: null, locked: false } });
      expect(res.body.modules).toHaveLength(6);
    });

    it('business.created passe par l’outbox et crée les catégories par défaut (une seule fois)', async () => {
      const published = await relay.relayOnce();
      expect(published).toBeGreaterThanOrEqual(1);

      const cats = await waitFor(
        async () =>
          (await http.get('/v1/catalog/categories').set(auth(awa.accessToken, awaBiz))).body as { name: string }[],
        (list) => list.length >= 2,
      );
      expect(cats.map((c) => c.name)).toEqual(['Général', 'Nouveautés']);

      // Re-livraison du même job : l'abonné ne s'exécute pas deux fois
      const [evt] = (
        await dbs.db.execute(
          sql`SELECT id FROM core.outbox_events WHERE type = 'business.created' AND business_id = ${awaBiz}`,
        )
      ).rows as { id: string }[];
      const replay = await worker.process({
        data: { eventId: evt.id, handler: 'CatalogEventHandlers.createDefaultCategories' },
      });
      expect(replay).toBe(false);
      const after = await http.get('/v1/catalog/categories').set(auth(awa.accessToken, awaBiz)).expect(200);
      expect(after.body).toHaveLength(2);
    });
  });

  describe('Catalogue et contacts', () => {
    let productId: string;

    it('crée, liste et modifie un produit', async () => {
      const created = await http
        .post('/v1/catalog/products')
        .set(auth(awa.accessToken, awaBiz))
        .send({ name: 'Beurre de karité 250 g', price: 3500, cost: 2000, sku: 'KAR-250' })
        .expect(201);
      productId = created.body.id;
      expect(created.body).toMatchObject({ price: 3500, cost: 2000, unit: 'pièce', version: 1 });

      const dup = await http
        .post('/v1/catalog/products')
        .set(auth(awa.accessToken, awaBiz))
        .send({ name: 'Doublon', price: 100, sku: 'KAR-250' })
        .expect(409);
      expect(dup.body.error.code).toBe('CONFLICT');

      const patched = await http
        .patch(`/v1/catalog/products/${productId}`)
        .set(auth(awa.accessToken, awaBiz))
        .send({ price: 3800 })
        .expect(200);
      expect(patched.body).toMatchObject({ price: 3800, cost: 2000, version: 2 });

      const list = await http.get('/v1/catalog/products?search=karité').set(auth(awa.accessToken, awaBiz)).expect(200);
      expect(list.body.data).toHaveLength(1);
      expect(list.body.nextCursor).toBeNull();
    });

    it('valide les entrées', async () => {
      const res = await http
        .post('/v1/catalog/products')
        .set(auth(awa.accessToken, awaBiz))
        .send({ name: '', price: -5 })
        .expect(422);
      expect(res.body.error.code).toBe('VALIDATION_FAILED');
      expect(res.body.error.details.map((d: { field: string }) => d.field)).toEqual(
        expect.arrayContaining(['name', 'price']),
      );
    });

    it('crée un contact avec numéro normalisé', async () => {
      const res = await http
        .post('/v1/contacts')
        .set(auth(awa.accessToken, awaBiz))
        .send({ name: 'Fatou Ndiaye', phone: '77 412 08 55' })
        .expect(201);
      expect(res.body).toMatchObject({ name: 'Fatou Ndiaye', phone: '+221774120855', type: 'customer', balance: 0 });
    });
  });

  describe('Isolation entre entreprises', () => {
    it('un autre commerçant ne voit rien de l’entreprise d’Awa', async () => {
      moussa = await login(MOUSSA);
      const biz = await http
        .post('/v1/businesses')
        .set(auth(moussa.accessToken))
        .send({ name: 'Moussa Électricité', category: 'prestataire' })
        .expect(201);
      moussaBiz = biz.body.business.id;

      const denied = await http.get('/v1/contacts').set(auth(moussa.accessToken, awaBiz)).expect(403);
      expect(denied.body.error.code).toBe('NOT_A_MEMBER');

      const own = await http.get('/v1/contacts').set(auth(moussa.accessToken, moussaBiz)).expect(200);
      expect(own.body.data).toEqual([]);
    });

    it('la RLS filtre au niveau de la base, même sans filtre applicatif', async () => {
      const inMoussa = await dbs.withTenant(moussaBiz, (tx) => tx.select().from(contacts));
      expect(inMoussa).toHaveLength(0);
      const inAwa = await dbs.withTenant(awaBiz, (tx) => tx.select().from(contacts));
      expect(inAwa).toHaveLength(1);
      // Sans entreprise positionnée : aucune ligne métier visible
      const none = await dbs.db.select().from(contacts);
      expect(none).toHaveLength(0);
      // Écrire pour une autre entreprise est refusé par la politique
      await expect(
        dbs.withTenant(moussaBiz, (tx) =>
          tx
            .insert(contacts)
            .values({ id: '01930000-0000-7000-8000-0000000000aa', businessId: awaBiz, name: 'Intrus' }),
        ),
      ).rejects.toThrow(/row-level security/);
    });
  });

  describe('Membres et rôles', () => {
    it('invite un utilisateur existant comme caissier, avec des droits limités', async () => {
      const inv = await http
        .post('/v1/members')
        .set(auth(awa.accessToken, awaBiz))
        .send({ phone: '78 111 22 33', roleKey: 'cashier' })
        .expect(201);
      expect(inv.body).toMatchObject({ phone: MOUSSA, role: 'cashier', status: 'active' });

      const dup = await http
        .post('/v1/members')
        .set(auth(awa.accessToken, awaBiz))
        .send({ phone: MOUSSA, roleKey: 'manager' })
        .expect(409);
      expect(dup.body.error.code).toBe('CONFLICT');

      await http.get('/v1/catalog/products').set(auth(moussa.accessToken, awaBiz)).expect(200);
      const forbidden = await http
        .post('/v1/catalog/products')
        .set(auth(moussa.accessToken, awaBiz))
        .send({ name: 'Test', price: 100 })
        .expect(403);
      expect(forbidden.body.error).toMatchObject({
        code: 'INSUFFICIENT_PERMISSION',
        details: { permission: 'catalog:write' },
      });
      await http
        .post('/v1/contacts')
        .set(auth(moussa.accessToken, awaBiz))
        .send({ name: 'Client comptoir' })
        .expect(201);

      const me = await http.get('/v1/me').set(auth(moussa.accessToken)).expect(200);
      expect(me.body.businesses.map((b: { role: string }) => b.role).sort()).toEqual(['cashier', 'owner']);
    });

    it('invite un nouveau numéro : l’adhésion s’active à la première connexion', async () => {
      const inv = await http
        .post('/v1/members')
        .set(auth(awa.accessToken, awaBiz))
        .send({ phone: FATOU, fullName: 'Fatou Sarr', roleKey: 'manager' })
        .expect(201);
      expect(inv.body.status).toBe('invited');

      const fatou = await login(FATOU);
      expect(fatou.isNewUser).toBe(false); // nom déjà renseigné par l'invitation
      const me = await http.get('/v1/me').set(auth(fatou.accessToken)).expect(200);
      expect(me.body.businesses).toEqual([expect.objectContaining({ id: awaBiz, role: 'manager' })]);

      const members = await http.get('/v1/members').set(auth(awa.accessToken, awaBiz)).expect(200);
      expect(members.body).toHaveLength(3);
      expect(members.body.every((m: { status: string }) => m.status === 'active')).toBe(true);
    });

    it('un caissier ne peut pas gérer les membres et le propriétaire est protégé', async () => {
      const members = (await http.get('/v1/members').set(auth(awa.accessToken, awaBiz))).body as {
        id: string;
        role: string;
      }[];
      const owner = members.find((m) => m.role === 'owner')!;
      const cashier = members.find((m) => m.role === 'cashier')!;

      await http
        .patch(`/v1/members/${cashier.id}`)
        .set(auth(moussa.accessToken, awaBiz))
        .send({ status: 'suspended' })
        .expect(403);
      await http
        .patch(`/v1/members/${owner.id}`)
        .set(auth(awa.accessToken, awaBiz))
        .send({ roleKey: 'manager' })
        .expect(403);

      await http
        .patch(`/v1/members/${cashier.id}`)
        .set(auth(awa.accessToken, awaBiz))
        .send({ status: 'suspended' })
        .expect(200);
      const blocked = await http.get('/v1/catalog/products').set(auth(moussa.accessToken, awaBiz)).expect(403);
      expect(blocked.body.error.code).toBe('NOT_A_MEMBER');
    });

    it('retire un membre (pas le propriétaire) et liste l’équipe avec les photos', async () => {
      const A = auth(awa.accessToken, awaBiz);
      const inv = await http
        .post('/v1/members')
        .set(A)
        .send({ phone: '77 000 00 77', roleKey: 'accountant' })
        .expect(201);
      const list = (await http.get('/v1/members').set(A).expect(200)).body as { id: string; role: string }[];
      expect(list.find((m) => m.id === inv.body.id)).toMatchObject({ role: 'accountant', avatarFileId: null });

      await http.delete(`/v1/members/${inv.body.id}`).set(A).expect(200);
      const after = (await http.get('/v1/members').set(A)).body as { id: string; role: string }[];
      expect(after.some((m) => m.id === inv.body.id)).toBe(false);
      await http.delete(`/v1/members/${inv.body.id}`).set(A).expect(404);

      const owner = after.find((m) => m.role === 'owner')!;
      const res = await http.delete(`/v1/members/${owner.id}`).set(A).expect(403);
      expect(res.body.error.message).toContain('propriétaire');
    });
  });

  describe('Ventes et stock', () => {
    const CAISSIER = '+221770000099';
    let cashier: { accessToken: string; refreshToken: string };
    let karite: string;
    let huile: string;
    let aminata: string;
    let cashSaleId: string;
    let creditSaleId: string;
    const year = new Date().getUTCFullYear();
    const A = () => auth(awa.accessToken, awaBiz);

    /** Relaie l'outbox puis attend que la condition soit vraie (les abonnés tournent dans le worker). */
    async function settle<T>(read: () => Promise<T>, ok: (v: T) => boolean) {
      await relay.relayOnce();
      return waitFor(read, ok);
    }
    const stockOf = async (productId: string) => {
      const res = await http.get('/v1/inventory/stock').set(A()).expect(200);
      return (res.body.items as { productId: string; onHand: number }[]).find((i) => i.productId === productId)!.onHand;
    };
    const balanceOf = async (customerId: string) =>
      (await http.get(`/v1/sales/customers/${customerId}/ledger`).set(A()).expect(200)).body.balance as number;

    it('prépare produits, stock initial, client et caissier', async () => {
      const products = (await http.get('/v1/catalog/products?search=karité').set(A()).expect(200)).body.data;
      karite = products[0].id; // prix 3 800, coût 2 000
      huile = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Huile de coco 500 ml', price: 4000, cost: 2600, lowStockThreshold: 5 })
          .expect(201)
      ).body.id;

      const entry = await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: huile, type: 'purchase', quantity: 10 })
        .expect(201);
      expect(entry.body).toMatchObject({ before: 0, onHand: 10 });
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: karite, type: 'purchase', quantity: 20 })
        .expect(201);
      const bad = await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: huile, type: 'purchase', quantity: -3 })
        .expect(422);
      expect(bad.body.error.code).toBe('VALIDATION_FAILED');

      aminata = (
        await http.post('/v1/contacts').set(A()).send({ name: 'Aminata Ba', phone: '76 555 12 34' }).expect(201)
      ).body.id;

      await http.post('/v1/members').set(A()).send({ phone: CAISSIER, roleKey: 'cashier' }).expect(201);
      cashier = await login(CAISSIER);
      cashierToken = cashier.accessToken;
      cashierRefresh = cashier.refreshToken;
    });

    it('encaisse une vente au comptant, de façon idempotente', async () => {
      const id = '01930000-0000-7000-8000-00000000c001';
      const body = {
        id,
        customerId: aminata,
        items: [
          { productId: karite, quantity: 2 },
          { productId: huile, quantity: 1 },
        ],
        payments: [{ method: 'cash', amount: 11600 }],
      };
      const res = await http.post('/v1/sales').set(A()).send(body).expect(201);
      cashSaleId = res.body.id;
      expect(res.body).toMatchObject({
        number: `VEN-${year}-0001`,
        status: 'completed',
        subtotal: 11600,
        total: 11600,
        paid: 11600,
        due: 0,
        costTotal: 6600,
      });
      expect(res.body.items.map((i: { name: string; total: number }) => [i.name, i.total])).toEqual([
        ['Beurre de karité 250 g', 7600],
        ['Huile de coco 500 ml', 4000],
      ]);

      // Détail complet pour le reçu : client, vendeur, lignes dans l'ordre du ticket
      const detail = await http.get(`/v1/sales/${cashSaleId}`).set(A()).expect(200);
      expect(detail.body.customer).toEqual({ id: aminata, name: 'Aminata Ba', phone: '+221765551234' });
      expect(detail.body.cashierName).toBe('Awa Diallo');
      expect(detail.body.payments).toEqual([expect.objectContaining({ method: 'cash', amount: 11600 })]);

      // Renvoi du même id (mobile hors ligne qui resynchronise) : pas de doublon
      const again = await http.post('/v1/sales').set(A()).send(body).expect(200);
      expect(again.body.number).toBe(`VEN-${year}-0001`);
    });

    it('refuse le crédit sans client et le trop-payé', async () => {
      const noCustomer = await http
        .post('/v1/sales')
        .set(A())
        .send({ items: [{ productId: huile, quantity: 1 }], payments: [{ method: 'wave', amount: 1000 }] })
        .expect(422);
      expect(noCustomer.body.error).toMatchObject({ code: 'CREDIT_REQUIRES_CUSTOMER', details: { due: 3000 } });

      const over = await http
        .post('/v1/sales')
        .set(A())
        .send({ items: [{ productId: huile, quantity: 1 }], payments: [{ method: 'cash', amount: 5000 }] })
        .expect(422);
      expect(over.body.error.code).toBe('OVERPAYMENT');
    });

    it('vend à crédit : dette au carnet, stock décrémenté, alerte de stock bas', async () => {
      const res = await http
        .post('/v1/sales')
        .set(A())
        .send({
          customerId: aminata,
          items: [{ productId: huile, quantity: 5 }],
          payments: [{ method: 'wave', amount: 5000 }],
        })
        .expect(201);
      creditSaleId = res.body.id;
      expect(res.body).toMatchObject({ number: `VEN-${year}-0002`, total: 20000, paid: 5000, due: 15000 });
      expect(await balanceOf(aminata)).toBe(15000); // carnet écrit dans la même transaction

      // Le stock est mis à jour par l'abonné inventory (10 − 1 − 5 = 4 ; 20 − 2 = 18)
      await settle(
        () => stockOf(huile),
        (q) => q === 4,
      );
      expect(await stockOf(karite)).toBe(18);

      const low = await http.get('/v1/inventory/stock?lowOnly=true').set(A()).expect(200);
      expect(low.body.items.map((i: { name: string }) => i.name)).toEqual(['Huile de coco 500 ml']);
      const alerts = (
        await dbs.db.execute(
          sql`SELECT payload FROM core.outbox_events WHERE type = 'stock.low' AND aggregate_id = ${huile}`,
        )
      ).rows as { payload: { onHand: number; threshold: number } }[];
      expect(alerts).toHaveLength(1);
      // Le worker traite les deux ventes en parallèle : le seuil est franchi à 5 ou à 4 selon l'ordre
      expect(alerts[0].payload.threshold).toBe(5);
      expect([4, 5]).toContain(alerts[0].payload.onHand);

      // Le cache de solde de l'annuaire suit, via contacts
      const contact = await waitFor(
        async () => (await http.get(`/v1/contacts/${aminata}`).set(A())).body,
        (c) => c.balance === 15000,
      );
      expect(contact.balance).toBe(15000);
    });

    it('un abonné ne décrémente jamais deux fois la même vente', async () => {
      const [evt] = (
        await dbs.db.execute(
          sql`SELECT id FROM core.outbox_events WHERE type = 'sale.completed' AND aggregate_id = ${creditSaleId}`,
        )
      ).rows as { id: string }[];
      expect(
        await worker.process({ data: { eventId: evt.id, handler: 'InventoryEventHandlers.decrementOnSale' } }),
      ).toBe(false);
      expect(await stockOf(huile)).toBe(4);
    });

    it('enregistre un remboursement sans dépasser la dette', async () => {
      const tooMuch = await http
        .post(`/v1/sales/customers/${aminata}/repayments`)
        .set(A())
        .send({ amount: 20000, method: 'cash' })
        .expect(422);
      expect(tooMuch.body.error).toMatchObject({ code: 'REPAYMENT_EXCEEDS_BALANCE', details: { balance: 15000 } });

      const ok = await http
        .post(`/v1/sales/customers/${aminata}/repayments`)
        .set(A())
        .send({ amount: 5000, method: 'orange_money' })
        .expect(201);
      expect(ok.body.balance).toBe(10000);

      const debtors = await http.get('/v1/sales/debtors').set(A()).expect(200);
      expect(debtors.body).toEqual([
        expect.objectContaining({ customerId: aminata, name: 'Aminata Ba', balance: 10000 }),
      ]);
      await settle(
        async () => (await http.get(`/v1/contacts/${aminata}`).set(A())).body.balance,
        (b) => b === 10000,
      );
    });

    it('calcule le résumé du jour : CA, bénéfice, encaissements, crédit', async () => {
      await http
        .post('/v1/sales/expenses')
        .set(A())
        .send({ category: 'transport', amount: 2000, method: 'cash' })
        .expect(201);
      const s = (await http.get('/v1/sales/summary').set(A()).expect(200)).body;
      expect(s).toMatchObject({
        salesCount: 2,
        revenue: 31600,
        cost: 19600,
        grossProfit: 12000,
        expenses: 2000,
        netProfit: 10000,
        collected: 16600,
        onCredit: 15000,
        receivables: 10000,
      });
      // Courbe des 7 derniers jours : aujourd'hui en dernier, avec le CA du jour
      expect(s.last7Days).toHaveLength(7);
      expect(s.last7Days[6]).toEqual({ date: new Date().toISOString().slice(0, 10), revenue: 31600 });
      expect(s.last7Days.slice(0, 6).every((d: { revenue: number }) => d.revenue === 0)).toBe(true);
      expect(s.previous7DaysRevenue).toBe(0);
      expect(s.byMethod).toEqual([
        { method: 'cash', amount: 11600 },
        { method: 'wave', amount: 5000 },
      ]);
      expect(s.topProducts[0]).toMatchObject({ name: 'Huile de coco 500 ml', quantity: 6, revenue: 24000 });
    });

    it('le caissier vend mais ne voit pas les bénéfices et ne peut pas annuler', async () => {
      const C = auth(cashier.accessToken, awaBiz);
      const sale = await http
        .post('/v1/sales')
        .set(C)
        .send({ items: [{ name: 'Sachet', quantity: 1, unitPrice: 100 }], payments: [{ method: 'cash', amount: 100 }] })
        .expect(201);
      expect(sale.body).toMatchObject({ number: `VEN-${year}-0003`, total: 100, costTotal: 0 });
      expect((await http.get('/v1/sales/summary').set(C).expect(403)).body.error.code).toBe('INSUFFICIENT_PERMISSION');
      await http.post(`/v1/sales/${cashSaleId}/void`).set(C).send({ reason: 'erreur de saisie' }).expect(403);
    });

    it('le caissier ne voit que ses ventes, sans prix d’achat ni achats fournisseurs', async () => {
      const C = auth(cashier.accessToken, awaBiz);
      const list = (await http.get('/v1/sales').set(C).expect(200)).body.data as { id: string; cashierId: string }[];
      expect(list.length).toBeGreaterThan(0);
      expect(new Set(list.map((s) => s.cashierId)).size).toBe(1);
      expect(list.map((s) => s.id)).not.toContain(cashSaleId);
      await http.get(`/v1/sales/${cashSaleId}`).set(C).expect(404);

      const stock = (await http.get('/v1/inventory/stock').set(C).expect(200)).body;
      expect(stock.totals.stockValue).toBeNull();
      expect(stock.items.every((i: { cost: unknown; value: unknown }) => i.cost === null && i.value === null)).toBe(
        true,
      );
      const products = (await http.get('/v1/catalog/products').set(C).expect(200)).body.data;
      expect(products.every((p: { cost: unknown }) => p.cost === null)).toBe(true);

      await http.get('/v1/purchases').set(C).expect(403);
      await http.get('/v1/suppliers').set(C).expect(403);

      // Le propriétaire, lui, voit tout
      expect((await http.get('/v1/inventory/stock').set(A()).expect(200)).body.totals.stockValue).not.toBeNull();
      expect((await http.get('/v1/sales').set(A()).expect(200)).body.data.map((s: { id: string }) => s.id)).toContain(
        cashSaleId,
      );
    });

    it('annule une vente : stock remis et dette annulée', async () => {
      const res = await http
        .post(`/v1/sales/${creditSaleId}/void`)
        .set(A())
        .send({ reason: 'Client a rendu la marchandise' })
        .expect(200);
      expect(res.body).toMatchObject({ status: 'voided', voidReason: 'Client a rendu la marchandise' });

      await settle(
        () => stockOf(huile),
        (q) => q === 9,
      );
      // 10 000 dus − 15 000 annulés : la boutique doit 5 000 à la cliente (déjà payés)
      expect(await balanceOf(aminata)).toBe(-5000);

      const twice = await http.post(`/v1/sales/${creditSaleId}/void`).set(A()).send({ reason: 'encore' }).expect(409);
      expect(twice.body.error.code).toBe('SALE_ALREADY_VOIDED');

      const summary = (await http.get('/v1/sales/summary').set(A()).expect(200)).body;
      expect(summary).toMatchObject({ salesCount: 2, revenue: 11700 }); // 11 600 + 100 (vente annulée exclue)
    });

    it('enregistre une vente faite hors ligne à sa vraie date, une seule fois', async () => {
      const id = '01937a00-0000-7000-8000-00000000a001';
      const soldAt = new Date(Date.now() - 2 * 24 * 3600 * 1000).toISOString();
      const body = {
        id,
        soldAt,
        items: [{ name: 'Retouche', quantity: 1, unitPrice: 500 }],
        payments: [{ method: 'cash', amount: 500 }],
      };
      const first = await http.post('/v1/sales').set(A()).send(body).expect(201);
      expect(first.body.soldAt).toBe(soldAt);
      // Le téléphone renvoie la vente (réseau coupé pendant la réponse) : même vente
      const again = await http.post('/v1/sales').set(A()).send(body).expect(200);
      expect(again.body.number).toBe(first.body.number);
      // Elle ne compte pas dans le résumé d'aujourd'hui
      const today = (await http.get('/v1/sales/summary').set(A()).expect(200)).body;
      expect(today).toMatchObject({ salesCount: 2, revenue: 11700 });

      const tooOld = await http
        .post('/v1/sales')
        .set(A())
        .send({ ...body, id: undefined, soldAt: new Date(Date.now() - 100 * 24 * 3600 * 1000).toISOString() })
        .expect(422);
      expect(tooOld.body.error.message).toContain('trop ancienne');
    });

    it('ventes par vendeur : classement du gérant, « ma journée » du vendeur', async () => {
      const s = (await http.get('/v1/sales/summary').set(A()).expect(200)).body;
      expect(s.bySeller).toEqual([
        expect.objectContaining({ name: 'Awa Diallo', salesCount: 1, revenue: 11600 }),
        expect.objectContaining({ name: CAISSIER, salesCount: 1, revenue: 100 }),
      ]);

      const C = auth(cashier.accessToken, awaBiz);
      const mine = await http.get('/v1/sales/my-day').set(C).expect(200);
      expect(mine.body).toMatchObject({ salesCount: 1, revenue: 100, collected: 100 });

      const list = (await http.get('/v1/sales?mine=true').set(C).expect(200)).body.data;
      expect(list).toHaveLength(1);
      expect(list[0]).toMatchObject({ total: 100, cashierName: CAISSIER, firstItem: expect.any(String), itemCount: 1 });
      const all = (await http.get('/v1/sales').set(A()).expect(200)).body.data as { cashierName: string }[];
      expect(new Set(all.map((x) => x.cashierName))).toEqual(new Set(['Awa Diallo', CAISSIER]));
    });

    it('rapport sur 7 jours : totaux, série jour par jour, comparaison, droits', async () => {
      const d = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
      const r = (
        await http
          .get(`/v1/reports/overview?from=${d(-6)}&to=${d(0)}`)
          .set(A())
          .expect(200)
      ).body;
      // Aujourd'hui : 11 600 + 100 ; il y a 2 jours : 500 (vente hors ligne) ; la vente annulée ne compte pas
      expect(r).toMatchObject({
        period: { from: d(-6), to: d(0), days: 7, granularity: 'day' },
        salesCount: 3,
        voidedCount: 1,
        revenue: 12200,
        expenses: 2000,
        averageBasket: Math.round(12200 / 3),
        change: { revenue: null },
      });
      expect(r.grossProfit).toBe(r.revenue - r.cost);
      expect(r.netProfit).toBe(r.grossProfit - 2000);
      expect(r.series).toHaveLength(7);
      expect(r.series.map((p: { revenue: number }) => p.revenue)).toEqual([0, 0, 0, 0, 500, 0, 11700]);
      expect(r.byMethod).toEqual([{ method: 'cash', amount: 12200, salesCount: 3 }]);
      expect(r.topProducts[0]).toMatchObject({ name: 'Beurre de karité 250 g', quantity: 2 });
      expect(r.bySeller.map((v: { salesCount: number }) => v.salesCount)).toEqual([2, 1]);
      expect(r.expensesByCategory).toEqual([{ category: 'transport', amount: 2000, count: 1 }]);

      // Hier seul : la vente hors ligne n'y est pas, et aujourd'hui est comparé à hier
      const today = (
        await http
          .get(`/v1/reports/overview?from=${d(0)}&to=${d(0)}`)
          .set(A())
          .expect(200)
      ).body;
      expect(today.previous).toMatchObject({ from: d(-1), to: d(-1), revenue: 0 });

      await http
        .get(`/v1/reports/overview?from=${d(0)}&to=${d(-3)}`)
        .set(A())
        .expect(422);
      await http
        .get(`/v1/reports/overview?from=2020-01-01&to=${d(0)}`)
        .set(A())
        .expect(422);
      await http
        .get(`/v1/reports/overview?from=${d(-6)}&to=${d(0)}`)
        .set(auth(cashier.accessToken, awaBiz))
        .expect(403);
    });

    it('ajuste le stock par inventaire physique', async () => {
      const res = await http
        .post('/v1/inventory/counts')
        .set(A())
        .send({ items: [{ productId: karite, counted: 17 }] })
        .expect(201);
      expect(res.body).toMatchObject({ adjusted: 1, items: [{ before: 18, counted: 17, delta: -1 }] });
      const moves = await http.get(`/v1/inventory/products/${karite}/movements`).set(A()).expect(200);
      expect(moves.body.data.map((m: { type: string; quantity: number }) => [m.type, m.quantity])).toEqual([
        ['count', -1],
        ['sale', -2],
        ['purchase', 20],
      ]);
    });
  });

  describe('Logo de l’entreprise', () => {
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      'base64',
    );
    it('ajoute, remplace et retire le logo ; réservé au propriétaire ou gérant', async () => {
      const A = auth(awa.accessToken, awaBiz);
      const first = await http
        .post('/v1/business/logo')
        .set(A)
        .attach('file', png, { filename: 'logo.png' })
        .expect(201);
      expect((await http.get('/v1/business').set(A).expect(200)).body.business.logoFileId).toBe(first.body.logoFileId);
      await http.get(`/v1/files/${first.body.logoFileId}`).expect(200);

      const second = await http
        .post('/v1/business/logo')
        .set(A)
        .attach('file', png, { filename: 'logo.png' })
        .expect(201);
      expect(second.body.logoFileId).not.toBe(first.body.logoFileId);
      await http.get(`/v1/files/${first.body.logoFileId}`).expect(404);

      await http
        .post('/v1/business/logo')
        .set(auth(cashierToken, awaBiz))
        .attach('file', png, { filename: 'logo.png' })
        .expect(403);
      await http
        .post('/v1/business/logo')
        .set(A)
        .attach('file', Buffer.from('<svg/>'), { filename: 'x.png' })
        .expect(422);

      await http.delete('/v1/business/logo').set(A).expect(200);
      expect((await http.get('/v1/business').set(A).expect(200)).body.business.logoFileId).toBeNull();
      await http.get(`/v1/files/${second.body.logoFileId}`).expect(404);
    });
  });

  describe('Factures et devis', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const year = new Date().getUTCFullYear();
    const daysFromNow = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
    let client: string;
    let tissu: string;
    let quoteId: string;
    let invoiceId: string;
    const stockOf = async (productId: string) =>
      (
        (await http.get('/v1/inventory/stock').set(A()).expect(200)).body.items as {
          productId: string;
          onHand: number;
        }[]
      ).find((i) => i.productId === productId)!.onHand;

    it('crée un devis : numéro, lignes du catalogue et libres, remise, validité 30 jours', async () => {
      client = (
        await http.post('/v1/contacts').set(A()).send({ name: 'Hôtel Teranga', phone: '33 820 00 00' }).expect(201)
      ).body.id;
      tissu = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Nappe brodée', price: 15000, cost: 9000 })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: tissu, type: 'purchase', quantity: 20 })
        .expect(201);

      const res = await http
        .post('/v1/invoicing/documents')
        .set(A())
        .send({
          kind: 'quote',
          customerId: client,
          lines: [
            { productId: tissu, quantity: 4 },
            { name: 'Livraison et pose', description: 'Plateau, Dakar', quantity: 1, unitPrice: 10000 },
          ],
          discount: 5000,
          note: 'Livraison sous 72 h',
        })
        .expect(201);
      quoteId = res.body.id;
      expect(res.body).toMatchObject({
        kind: 'quote',
        number: `DEV-${year}-0001`,
        status: 'pending',
        subtotal: 70000,
        discount: 5000,
        total: 65000,
        dueDate: daysFromNow(30),
        customer: { name: 'Hôtel Teranga', phone: '+221338200000' },
      });
      expect(res.body.lines.map((l: { name: string; total: number }) => [l.name, l.total])).toEqual([
        ['Nappe brodée', 60000],
        ['Livraison et pose', 10000],
      ]);
      expect(res.body.lines[0].unitCost).toBeUndefined(); // le coût ne sort pas sur un document client
    });

    it('modifie le devis, l’accepte puis le transforme en facture (une seule fois)', async () => {
      const upd = await http
        .patch(`/v1/invoicing/documents/${quoteId}`)
        .set(A())
        .send({ customerId: client, lines: [{ productId: tissu, quantity: 5 }], discount: 0 })
        .expect(200);
      expect(upd.body).toMatchObject({ total: 75000, status: 'pending', number: `DEV-${year}-0001` });

      await http.post(`/v1/invoicing/documents/${quoteId}/accept`).set(A()).expect(200);
      const inv = await http
        .post(`/v1/invoicing/documents/${quoteId}/convert`)
        .set(A())
        .send({ dueDate: daysFromNow(15) })
        .expect(201);
      invoiceId = inv.body.id;
      expect(inv.body).toMatchObject({
        kind: 'invoice',
        number: `FAC-${year}-0001`,
        status: 'unpaid',
        total: 75000,
        due: 75000,
        quote: { id: quoteId, number: `DEV-${year}-0001` },
      });
      const again = await http.post(`/v1/invoicing/documents/${quoteId}/convert`).set(A()).send({}).expect(200);
      expect(again.body.id).toBe(invoiceId);

      const quote = (await http.get(`/v1/invoicing/documents/${quoteId}`).set(A()).expect(200)).body;
      expect(quote).toMatchObject({ status: 'invoiced', invoice: { id: invoiceId } });
      const locked = await http
        .patch(`/v1/invoicing/documents/${quoteId}`)
        .set(A())
        .send({ customerId: client, lines: [{ productId: tissu, quantity: 1 }] })
        .expect(409);
      expect(locked.body.error.code).toBe('DOCUMENT_LOCKED');
      await http
        .patch(`/v1/invoicing/documents/${invoiceId}`)
        .set(A())
        .send({ customerId: client, lines: [{ productId: tissu, quantity: 1 }] })
        .expect(409);

      // La facture fait sortir la marchandise : 20 − 5
      await relay.relayOnce();
      await waitFor(
        () => stockOf(tissu),
        (q) => q === 15,
      );
    });

    it('encaisse la facture en plusieurs fois, sans dépasser ni doubler', async () => {
      const payId = '01937a00-0000-7000-8000-00000000f001';
      const p1 = await http
        .post(`/v1/invoicing/documents/${invoiceId}/payments`)
        .set(A())
        .send({ id: payId, amount: 30000, method: 'wave', reference: 'WV-123' })
        .expect(201);
      expect(p1.body).toMatchObject({ status: 'partial', paid: 30000, due: 45000 });
      const dup = await http
        .post(`/v1/invoicing/documents/${invoiceId}/payments`)
        .set(A())
        .send({ id: payId, amount: 30000, method: 'wave' })
        .expect(200);
      expect(dup.body.paid).toBe(30000);

      const over = await http
        .post(`/v1/invoicing/documents/${invoiceId}/payments`)
        .set(A())
        .send({ amount: 50000, method: 'cash' })
        .expect(422);
      expect(over.body.error).toMatchObject({ code: 'PAYMENT_EXCEEDS_DUE', details: { due: 45000 } });

      const full = await http
        .post(`/v1/invoicing/documents/${invoiceId}/payments`)
        .set(A())
        .send({ amount: 45000, method: 'transfer' })
        .expect(201);
      expect(full.body).toMatchObject({ status: 'paid', due: 0 });
      expect(full.body.payments).toHaveLength(2);

      const cancel = await http
        .post(`/v1/invoicing/documents/${invoiceId}/cancel`)
        .set(A())
        .send({ reason: 'erreur' })
        .expect(409);
      expect(cancel.body.error.code).toBe('INVOICE_HAS_PAYMENTS');
    });

    it('facture directe en retard, résumé, recherche, puis annulation avec retour en stock', async () => {
      const late = await http
        .post('/v1/invoicing/documents')
        .set(A())
        .send({
          kind: 'invoice',
          customerId: client,
          issueDate: daysFromNow(-20),
          dueDate: daysFromNow(-5),
          lines: [{ productId: tissu, quantity: 2 }],
        })
        .expect(201);
      expect(late.body).toMatchObject({ number: `FAC-${year}-0002`, status: 'unpaid', overdue: true, total: 30000 });

      const summary = (await http.get('/v1/invoicing/summary').set(A()).expect(200)).body;
      expect(summary).toMatchObject({
        receivable: 30000,
        openInvoices: 1,
        overdue: 30000,
        overdueInvoices: 1,
        openQuotes: 0,
      });

      const overdue = (await http.get('/v1/invoicing/documents?overdue=true').set(A()).expect(200)).body.data;
      expect(overdue.map((d: { id: string }) => d.id)).toEqual([late.body.id]);
      const found = (await http.get('/v1/invoicing/documents?kind=quote&search=teranga').set(A()).expect(200)).body
        .data;
      expect(found.map((d: { number: string }) => d.number)).toEqual([`DEV-${year}-0001`]);

      await relay.relayOnce();
      await waitFor(
        () => stockOf(tissu),
        (q) => q === 13,
      );
      const cancelled = await http
        .post(`/v1/invoicing/documents/${late.body.id}/cancel`)
        .set(A())
        .send({ reason: 'Commande annulée par le client' })
        .expect(200);
      expect(cancelled.body).toMatchObject({ status: 'cancelled', cancelReason: 'Commande annulée par le client' });
      await relay.relayOnce();
      await waitFor(
        () => stockOf(tissu),
        (q) => q === 15,
      );
      await http
        .post(`/v1/invoicing/documents/${late.body.id}/payments`)
        .set(A())
        .send({ amount: 100, method: 'cash' })
        .expect(409);
    });

    it('droits et isolation : le caissier consulte sans facturer, un autre commerçant ne voit rien', async () => {
      await http.get('/v1/invoicing/documents').set(auth(cashierToken, awaBiz)).expect(200);
      const denied = await http
        .post('/v1/invoicing/documents')
        .set(auth(cashierToken, awaBiz))
        .send({ kind: 'quote', customerId: client, lines: [{ name: 'x', quantity: 1, unitPrice: 1 }] })
        .expect(403);
      expect(denied.body.error.code).toBe('INSUFFICIENT_PERMISSION');
      await http.get(`/v1/invoicing/documents/${invoiceId}`).set(auth(moussa.accessToken, moussaBiz)).expect(404);
      const other = (await http.get('/v1/invoicing/documents').set(auth(moussa.accessToken, moussaBiz)).expect(200))
        .body.data;
      expect(other).toEqual([]);
    });
  });

  describe('Fiche produit et catégories', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let riz: string;
    let cat: string;

    it('catégories : création, doublon refusé, renommage, nombre de produits, suppression', async () => {
      cat = (await http.post('/v1/catalog/categories').set(A()).send({ name: 'Épicerie' }).expect(201)).body.id;
      const dup = await http.post('/v1/catalog/categories').set(A()).send({ name: 'épicerie' }).expect(409);
      expect(dup.body.error.message).toBe('Cette catégorie existe déjà');

      riz = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({
            name: 'Riz parfumé 5 kg',
            price: 5000,
            cost: 4000,
            unit: 'sac',
            categoryId: cat,
            barcode: '6111234567890',
            sku: 'RIZ-5',
            lowStockThreshold: 3,
            wholesalePrice: 4600,
            wholesaleMinQty: 10,
          })
          .expect(201)
      ).body.id;

      const renamed = await http
        .patch(`/v1/catalog/categories/${cat}`)
        .set(A())
        .send({ name: 'Alimentation' })
        .expect(200);
      expect(renamed.body.name).toBe('Alimentation');
      const list = (await http.get('/v1/catalog/categories').set(A()).expect(200)).body as {
        id: string;
        productCount: number;
      }[];
      expect(list.find((c) => c.id === cat)?.productCount).toBe(1);

      const tmp = (await http.post('/v1/catalog/categories').set(A()).send({ name: 'Temporaire' }).expect(201)).body.id;
      await http.delete(`/v1/catalog/categories/${tmp}`).set(A()).expect(204);
      await http.delete(`/v1/catalog/categories/${tmp}`).set(A()).expect(404);
    });

    it('codes : recherche par code-barres ou référence, doublon refusé avec le nom du produit', async () => {
      expect((await http.get('/v1/catalog/products/by-code/6111234567890').set(A()).expect(200)).body.id).toBe(riz);
      expect((await http.get('/v1/catalog/products/by-code/RIZ-5').set(A()).expect(200)).body.id).toBe(riz);
      const missing = await http.get('/v1/catalog/products/by-code/000').set(A()).expect(404);
      expect(missing.body.error.message).toBe('Aucun produit avec le code 000');

      const dup = await http
        .post('/v1/catalog/products')
        .set(A())
        .send({ name: 'Autre riz', price: 4500, barcode: '6111234567890' })
        .expect(409);
      expect(dup.body.error.message).toBe('Ce code-barres est déjà utilisé par « Riz parfumé 5 kg »');
      // Le produit garde son propre code en modification
      await http
        .patch(`/v1/catalog/products/${riz}`)
        .set(A())
        .send({ barcode: '6111234567890', price: 5200 })
        .expect(200);
    });

    it('prix de gros : appliqué en caisse dès la quantité minimale', async () => {
      const small = await http
        .post('/v1/sales')
        .set(A())
        .send({ items: [{ productId: riz, quantity: 2 }], payments: [{ method: 'cash', amount: 10400 }] })
        .expect(201);
      expect(small.body.total).toBe(10400);
      const bulk = await http
        .post('/v1/sales')
        .set(A())
        .send({ items: [{ productId: riz, quantity: 10 }], payments: [{ method: 'cash', amount: 46000 }] })
        .expect(201);
      expect(bulk.body.total).toBe(46000);

      const bad = await http.patch(`/v1/catalog/products/${riz}`).set(A()).send({ wholesalePrice: 6000 }).expect(422);
      expect(bad.body.error.message).toBe('Le prix de gros doit être inférieur au prix normal');
      await http.patch(`/v1/catalog/products/${riz}`).set(A()).send({ wholesaleMinQty: null }).expect(422);
      const cleared = await http
        .patch(`/v1/catalog/products/${riz}`)
        .set(A())
        .send({ wholesalePrice: null, wholesaleMinQty: null })
        .expect(200);
      expect(cleared.body).toMatchObject({ wholesalePrice: null, wholesaleMinQty: null });
    });

    it('un produit supprimé libère son code-barres', async () => {
      await http.delete(`/v1/catalog/products/${riz}`).set(A()).expect(204);
      await http.get('/v1/catalog/products/by-code/6111234567890').set(A()).expect(404);
      await http
        .post('/v1/catalog/products')
        .set(A())
        .send({ name: 'Riz parfumé 5 kg (nouveau)', price: 5000, barcode: '6111234567890' })
        .expect(201);
    });
  });

  describe('Clients et crédit', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let cashier: string;
    let binta: string;
    let product: string;
    const sell = (
      customerId: string,
      total: number,
      paid: number,
      extra: Record<string, unknown> = {},
      token?: string,
    ) =>
      http
        .post('/v1/sales')
        .set(token ? auth(token, awaBiz) : A())
        .send({
          customerId,
          items: [{ productId: product, quantity: 1, unitPrice: total }],
          payments: paid ? [{ method: 'cash', amount: paid }] : [],
          ...extra,
        });

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770009988', fullName: 'Ibou Ndiaye', roleKey: 'cashier' })
        .expect(201);
      cashier = (await login('+221770009988')).accessToken;
      product = (await http.post('/v1/catalog/products').set(A()).send({ name: 'Pagne wax', price: 10000 }).expect(201))
        .body.id;
    });

    it('plafond de crédit : fixé par le gérant, refusé au caissier, appliqué en caisse sauf hors ligne', async () => {
      const denied = await http
        .post('/v1/contacts')
        .set(auth(cashier, awaBiz))
        .send({ name: 'Binta Sow', creditLimit: 50000 })
        .expect(403);
      expect(denied.body.error.message).toContain('crédit maximum');

      binta = (
        await http
          .post('/v1/contacts')
          .set(A())
          .send({ name: 'Binta Sow', phone: '77 222 33 44', creditLimit: 25000 })
          .expect(201)
      ).body.id;

      await sell(binta, 20000, 0, {}, cashier).expect(201);
      const over = await sell(binta, 10000, 0).expect(422);
      expect(over.body.error).toMatchObject({
        code: 'CREDIT_LIMIT_EXCEEDED',
        details: { limit: 25000, balance: 20000, available: 5000, requested: 10000 },
      });
      expect(over.body.error.message).toBe(
        'Crédit possible pour Binta Sow : 5 000 F au plus (crédit maximum 25 000 F)',
      );
      // Payer une partie ramène la dette sous le plafond
      await sell(binta, 10000, 5000).expect(201);
      // Vente faite hors ligne : déjà conclue en boutique, enregistrée même au-delà du plafond
      await sell(binta, 8000, 0, { soldAt: new Date(Date.now() - 3600_000).toISOString() }).expect(201);
      const full = await sell(binta, 1000, 0).expect(422);
      expect(full.body.error.message).toBe('Binta Sow a atteint son crédit maximum (25 000 F)');

      // Le caissier peut modifier le client mais pas son plafond
      await http
        .patch(`/v1/contacts/${binta}`)
        .set(auth(cashier, awaBiz))
        .send({ address: 'Marché Sandaga' })
        .expect(200);
      await http.patch(`/v1/contacts/${binta}`).set(auth(cashier, awaBiz)).send({ creditLimit: null }).expect(403);
    });

    it('fiche client : solde, plafond disponible, statistiques, achats et relevé avec solde courant', async () => {
      const o = (await http.get(`/v1/customers/${binta}`).set(A()).expect(200)).body;
      expect(o.customer).toMatchObject({ name: 'Binta Sow', creditLimit: 25000, address: 'Marché Sandaga' });
      expect(o.balance).toBe(33000);
      expect(o.availableCredit).toBe(0);
      expect(o.stats).toMatchObject({ salesCount: 3, totalSpent: 38000, totalPaid: 5000, averageBasket: 12667 });
      expect(o.recentSales).toHaveLength(3);
      expect(o.topProducts[0]).toMatchObject({ name: 'Pagne wax', quantity: 3, total: 38000 });
      // Relevé du plus récent au plus ancien ; la vente hors ligne (il y a une heure) est la plus ancienne
      expect(o.entries.map((e: { balanceAfter: number }) => e.balanceAfter)).toEqual([33000, 28000, 8000]);
      expect(new Date(o.oldestUnpaidAt).getTime()).toBeLessThan(Date.now());

      // Remboursement de 22 000 F : la dette la plus ancienne (8 000) est soldée, la suivante devient la plus ancienne
      await http
        .post(`/v1/sales/customers/${binta}/repayments`)
        .set(A())
        .send({ amount: 22000, method: 'wave' })
        .expect(201);
      const after = (await http.get(`/v1/customers/${binta}`).set(A()).expect(200)).body;
      expect(after.balance).toBe(11000);
      expect(after.availableCredit).toBe(14000);
      expect(new Date(after.oldestUnpaidAt).getTime()).toBeGreaterThan(new Date(o.oldestUnpaidAt).getTime());
    });

    it('ajustements : reprise d’ancienne dette et remise, réservés au gérant', async () => {
      await http
        .post(`/v1/customers/${binta}/adjustments`)
        .set(auth(cashier, awaBiz))
        .send({ amount: 5000, reason: 'Ancien cahier' })
        .expect(403);
      await http.post(`/v1/customers/${binta}/adjustments`).set(A()).send({ amount: 0, reason: 'Rien' }).expect(422);
      const up = await http
        .post(`/v1/customers/${binta}/adjustments`)
        .set(A())
        .send({ amount: 4000, reason: 'Reprise du cahier papier' })
        .expect(201);
      expect(up.body.balance).toBe(15000);
      const tooMuch = await http
        .post(`/v1/customers/${binta}/adjustments`)
        .set(A())
        .send({ amount: -20000, reason: 'Geste commercial' })
        .expect(422);
      expect(tooMuch.body.error.message).toBe('Vous effacez plus que la dette du client (15 000 F)');
      await http
        .post(`/v1/customers/${binta}/adjustments`)
        .set(A())
        .send({ amount: -1000, reason: 'Geste commercial' })
        .expect(201);
      const o = (await http.get(`/v1/customers/${binta}`).set(A()).expect(200)).body;
      expect(o.balance).toBe(14000);
      expect(o.entries[0]).toMatchObject({
        entryType: 'adjustment',
        amount: -1000,
        refType: 'write_off',
        balanceAfter: 14000,
      });
      // Le solde en cache de l'annuaire suit (via l'événement)
      await relay.relayOnce();
      const contact = await waitFor(
        async () => (await http.get(`/v1/contacts/${binta}`).set(A())).body as { balance: number },
        (c) => c.balance === 14000,
      );
      expect(contact.balance).toBe(14000);
    });

    it('annuaire : filtres, tri, totaux, rappel, et suppression bloquée tant qu’il reste une dette', async () => {
      const kader = (await http.post('/v1/contacts').set(A()).send({ name: 'Abdou Kader' }).expect(201)).body.id;
      const all = (await http.get('/v1/customers').set(A()).expect(200)).body;
      const names = all.data.map((c: { name: string }) => c.name);
      expect(names.indexOf('Abdou Kader')).toBeLessThan(names.indexOf('Binta Sow'));
      expect(all.totals.debtors).toBeGreaterThanOrEqual(1);

      const debt = (await http.get('/v1/customers?filter=debt&sort=balance').set(A()).expect(200)).body;
      expect(debt.data.some((c: { id: string }) => c.id === kader)).toBe(false);
      expect(debt.data.find((c: { id: string }) => c.id === binta)).toMatchObject({
        balance: 14000,
        creditLimit: 25000,
        salesCount: 3,
        totalSpent: 38000,
      });
      expect(debt.data.map((c: { balance: number }) => c.balance)).toEqual(
        [...debt.data.map((c: { balance: number }) => c.balance)].sort((a, b) => b - a),
      );
      const found = (await http.get('/v1/customers?search=binta').set(A()).expect(200)).body;
      expect(found.data).toHaveLength(1);

      const r = await http
        .post(`/v1/customers/${binta}/reminders`)
        .set(auth(cashier, awaBiz))
        .send({ channel: 'whatsapp' })
        .expect(201);
      expect(r.body.lastRemindedAt).toBeTruthy();
      expect((await http.get(`/v1/customers/${binta}`).set(A())).body.customer.lastRemindedAt).toBeTruthy();

      const blocked = await http.delete(`/v1/contacts/${binta}`).set(A()).expect(409);
      expect(blocked.body.error).toMatchObject({ code: 'CUSTOMER_HAS_BALANCE', details: { balance: 14000 } });
      expect(blocked.body.error.message).toBe('Ce client doit encore 14 000 F : soldez sa dette avant de le supprimer');
      await http.delete(`/v1/contacts/${kader}`).set(A()).expect(204);
      await http.get(`/v1/customers/${kader}`).set(A()).expect(404);
    });
  });

  describe('Fournisseurs et achats', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let cashier: string;
    let supplier: string;
    let huile: string;
    let sachet: string;
    let order: string;
    const year = new Date().getUTCFullYear();
    const stockOf = async (productId: string) =>
      Number(
        (
          (await http.get('/v1/inventory/stock').set(A()).expect(200)).body.items as {
            productId: string;
            onHand: number;
          }[]
        ).find((i) => i.productId === productId)!.onHand,
      );
    const costOf = async (productId: string) =>
      (await http.get(`/v1/catalog/products/${productId}`).set(A()).expect(200)).body.cost as number;

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770007766', fullName: 'Aliou Ba', roleKey: 'cashier' })
        .expect(201);
      cashier = (await login('+221770007766')).accessToken;
      supplier = (
        await http
          .post('/v1/contacts')
          .set(A())
          .send({ type: 'supplier', name: 'Grossiste Sandaga', phone: '77 300 40 50' })
          .expect(201)
      ).body.id;
      huile = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Huile 1 L', price: 2000, cost: 1000 })
          .expect(201)
      ).body.id;
      sachet = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Sachets plastique (lot)', price: 0, cost: 500, trackStock: false })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: huile, type: 'purchase', quantity: 10, unitCost: 1000 })
        .expect(201);
    });

    it('bon de commande : brouillon, modification, confirmation ; caissier sans accès', async () => {
      await http
        .post('/v1/purchases')
        .set(auth(cashier, awaBiz))
        .send({ supplierId: supplier, lines: [{ productId: huile, quantity: 1 }] })
        .expect(403);

      const draft = await http
        .post('/v1/purchases')
        .set(A())
        .send({ supplierId: supplier, draft: true, lines: [{ productId: huile, quantity: 20, unitCost: 1400 }] })
        .expect(201);
      order = draft.body.id;
      expect(draft.body).toMatchObject({ number: `BC-${year}-0001`, status: 'draft', total: 28000, due: 0 });
      expect(draft.body.supplier.name).toBe('Grossiste Sandaga');

      const early = await http
        .post(`/v1/purchases/${order}/payments`)
        .set(A())
        .send({ amount: 1000, method: 'cash' })
        .expect(409);
      expect(early.body.error.message).toBe('Confirmez la commande avant de la payer');

      const edited = await http
        .patch(`/v1/purchases/${order}`)
        .set(A())
        .send({
          lines: [
            { productId: huile, quantity: 30, unitCost: 1400 },
            { productId: sachet, quantity: 5 },
          ],
          expectedDate: '2026-12-01',
        })
        .expect(200);
      expect(edited.body).toMatchObject({ total: 44500, expectedDate: '2026-12-01', lineCount: 2 });
      expect(edited.body.lines[1]).toMatchObject({ name: 'Sachets plastique (lot)', unitCost: 500, quantity: 5 });

      const confirmed = await http.post(`/v1/purchases/${order}/confirm`).set(A()).expect(200);
      expect(confirmed.body.status).toBe('ordered');
      expect((await http.get('/v1/purchases?filter=open').set(A()).expect(200)).body.totals).toMatchObject({
        openOrders: 1,
        toReceive: 44500,
        totalDue: 0,
      });
      // Le caissier n'a pas accès aux achats (prix d'achat, dettes fournisseurs)
      await http.get('/v1/purchases?filter=open').set(auth(cashier, awaBiz)).expect(403);
    });

    it('réception partielle puis complète : stock, coût moyen, statut, paiement à la livraison', async () => {
      const detail = (await http.get(`/v1/purchases/${order}`).set(A()).expect(200)).body;
      const huileLine = detail.lines.find((l: { productId: string }) => l.productId === huile).id;

      const part = await http
        .post(`/v1/purchases/${order}/receive`)
        .set(A())
        .send({ lines: [{ lineId: huileLine, quantity: 10 }], note: 'Premier camion' })
        .expect(201);
      expect(part.body.order).toMatchObject({ status: 'partial', receivedTotal: 14000, due: 14000 });
      expect(await stockOf(huile)).toBe(20);
      expect(await costOf(huile)).toBe(1200); // (10 × 1 000 + 10 × 1 400) / 20

      const over = await http
        .post(`/v1/purchases/${order}/receive`)
        .set(A())
        .send({ lines: [{ lineId: huileLine, quantity: 25 }] })
        .expect(422);
      expect(over.body.error.message).toBe('« Huile 1 L » : 25 reçu(s) pour 20 restant(s) à recevoir');

      // Le reste, avec un prix négocié à la livraison pour l'huile, et 20 000 F payés au livreur
      const rest = await http
        .post(`/v1/purchases/${order}/receive`)
        .set(A())
        .send({
          lines: [
            { lineId: huileLine, quantity: 20, unitCost: 1300 },
            { lineId: detail.lines[1].id, quantity: 5 },
          ],
          payment: { amount: 20000, method: 'cash' },
        })
        .expect(201);
      expect(rest.body.order).toMatchObject({ status: 'received', receivedTotal: 42500, paid: 20000, due: 22500 });
      expect(rest.body.order.receipts).toHaveLength(2);
      expect(rest.body.order.receipts[0]).toMatchObject({
        total: 14000,
        note: 'Premier camion',
        receivedBy: 'Awa Diallo',
      });
      expect(await stockOf(huile)).toBe(40);
      expect(await costOf(huile)).toBe(1250); // (20 × 1 200 + 20 × 1 300) / 40
      expect(await costOf(sachet)).toBe(500); // non suivi en stock : dernier prix

      const moves = (await http.get(`/v1/inventory/products/${huile}/movements`).set(A()).expect(200)).body.data;
      expect(moves[0]).toMatchObject({ type: 'purchase', quantity: 20, unitCost: 1300, note: `BC-${year}-0001` });

      await http.post(`/v1/purchases/${order}/receive`).set(A()).send({}).expect(409);
      const cancel = await http.post(`/v1/purchases/${order}/cancel`).set(A()).expect(409);
      expect(cancel.body.error.message).toContain('déjà été reçue');
      await http.patch(`/v1/purchases/${order}`).set(A()).send({ note: 'x' }).expect(409);
    });

    it('achat direct, fiche fournisseur et paiement global réparti du plus ancien au plus récent', async () => {
      const id = '01938000-0000-7000-8000-00000000ab01';
      const direct = await http
        .post('/v1/purchases')
        .set(A())
        .send({ id, supplierId: supplier, receive: true, lines: [{ productId: huile, quantity: 5, unitCost: 1500 }] })
        .expect(201);
      expect(direct.body).toMatchObject({
        number: `BC-${year}-0002`,
        status: 'received',
        receivedTotal: 7500,
        due: 7500,
      });
      // Renvoi du même achat (réseau coupé) : pas de doublon, pas de stock en double
      const again = await http
        .post('/v1/purchases')
        .set(A())
        .send({ id, supplierId: supplier, receive: true, lines: [{ productId: huile, quantity: 5, unitCost: 1500 }] })
        .expect(200);
      expect(again.body.number).toBe(`BC-${year}-0002`);
      expect(await stockOf(huile)).toBe(45);

      const list = (await http.get('/v1/suppliers').set(A()).expect(200)).body;
      expect(list[0]).toMatchObject({ id: supplier, due: 30000, purchased: 50000, ordersCount: 2, openOrders: 0 });

      const tooMuch = await http
        .post(`/v1/suppliers/${supplier}/payments`)
        .set(A())
        .send({ amount: 30001, method: 'wave' })
        .expect(422);
      expect(tooMuch.body.error.message).toBe('Le montant dépasse ce que vous devez à ce fournisseur');
      const paid = await http
        .post(`/v1/suppliers/${supplier}/payments`)
        .set(A())
        .send({ amount: 25000, method: 'wave' })
        .expect(201);
      expect(paid.body.allocations).toEqual([
        { orderId: order, amount: 22500 },
        { orderId: id, amount: 2500 },
      ]);
      expect(paid.body.due).toBe(5000);

      const o = (await http.get(`/v1/suppliers/${supplier}`).set(A()).expect(200)).body;
      expect(o.supplier).toMatchObject({ name: 'Grossiste Sandaga', phone: '+221773004050' });
      expect(o.due).toBe(5000);
      expect(o.stats).toMatchObject({ ordersCount: 2, purchased: 50000, paid: 45000 });
      expect(o.orders.map((x: { number: string }) => x.number)).toEqual([`BC-${year}-0002`, `BC-${year}-0001`]);
      expect(o.payments).toHaveLength(3);
      expect(o.products[0]).toMatchObject({ name: 'Huile 1 L', quantity: 35, lastCost: 1500 });

      const unpaid = (await http.get('/v1/purchases?filter=unpaid').set(A()).expect(200)).body;
      expect(unpaid.data.map((x: { id: string }) => x.id)).toEqual([id]);
      expect(unpaid.totals).toMatchObject({ totalDue: 5000, suppliersOwed: 1, openOrders: 0 });
    });

    it('annulation d’un bon non reçu ; un client peut devenir fournisseur', async () => {
      const client = (await http.post('/v1/contacts').set(A()).send({ name: 'Moussa revendeur' }).expect(201)).body.id;
      const o = await http
        .post('/v1/purchases')
        .set(A())
        .send({ supplierId: client, lines: [{ productId: huile, quantity: 2 }] })
        .expect(201);
      expect(o.body.lines[0].unitCost).toBe(1278); // coût moyen actuel par défaut : 57 500 / 45
      expect((await http.get(`/v1/contacts/${client}`).set(A())).body.type).toBe('both');
      const cancelled = await http.post(`/v1/purchases/${o.body.id}/cancel`).set(A()).expect(200);
      expect(cancelled.body).toMatchObject({ status: 'cancelled', due: 0 });
      await http.post(`/v1/purchases/${o.body.id}/cancel`).set(A()).expect(409);
      await http.post(`/v1/purchases/${o.body.id}/payments`).set(A()).send({ amount: 100, method: 'cash' }).expect(409);
    });
  });

  describe('Boutique en ligne', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let slug: string;
    let pagne: string;
    let bazin: string;
    let cache: string;
    let order: string;
    let cashier: string;
    const year = new Date().getUTCFullYear();
    const pub = () => `/v1/public/shops/${slug}`;

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770005544', fullName: 'Sokhna Diop', roleKey: 'cashier' })
        .expect(201);
      cashier = (await login('+221770005544')).accessToken;
      slug = (await http.get('/v1/shop').set(A()).expect(200)).body.slug;
      pagne = (await http.post('/v1/catalog/products').set(A()).send({ name: 'Pagne tissé', price: 7500 }).expect(201))
        .body.id;
      bazin = (await http.post('/v1/catalog/products').set(A()).send({ name: 'Bazin riche', price: 15000 }).expect(201))
        .body.id;
      cache = (await http.post('/v1/catalog/products').set(A()).send({ name: 'Produit caché', price: 100 }).expect(201))
        .body.id;
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: pagne, type: 'purchase', quantity: 5 })
        .expect(201);
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: bazin, type: 'purchase', quantity: 3 })
        .expect(201);
    });

    it('boutique fermée par défaut ; ouverture, réglages et publication', async () => {
      await http.get(pub()).expect(404);
      await http.get('/v1/public/shops/n-existe-pas').expect(404);
      const bad = await http.put('/v1/shop/settings').set(A()).send({ pickup: false, delivery: false }).expect(422);
      expect(bad.body.error.message).toContain('au moins');

      const s = await http
        .put('/v1/shop/settings')
        .set(A())
        .send({
          enabled: true,
          title: 'Awa Beauté en ligne',
          whatsapp: '77 111 22 33',
          deliveryFee: 1000,
          deliveryZone: 'Dakar',
          minOrder: 10000,
        })
        .expect(200);
      expect(s.body).toMatchObject({
        enabled: true,
        whatsapp: '+221771112233',
        deliveryFee: 1000,
        pickup: true,
        delivery: true,
      });

      const pubd = await http
        .post('/v1/shop/publish')
        .set(A())
        .send({ productIds: [pagne, bazin], published: true })
        .expect(200);
      expect(pubd.body.updated).toBe(2);
      // Le caissier ne publie pas
      await http.post('/v1/shop/publish').set(auth(cashier, awaBiz)).send({ published: true }).expect(403);
      await http.put('/v1/shop/settings').set(auth(cashier, awaBiz)).send({ enabled: false }).expect(403);

      // Vitrine : accroche et image de couverture (remplacée puis retirée)
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        'base64',
      );
      await http.put('/v1/shop/settings').set(A()).send({ tagline: 'Le beau pagne de Dakar' }).expect(200);
      const c1 = (await http.post('/v1/shop/cover').set(A()).attach('file', png, { filename: 'c.png' }).expect(201))
        .body;
      expect(c1).toMatchObject({ tagline: 'Le beau pagne de Dakar', coverFileId: expect.any(String) });
      const c2 = (await http.post('/v1/shop/cover').set(A()).attach('file', png, { filename: 'c.png' }).expect(201))
        .body;
      await http.get(`/v1/files/${c1.coverFileId}`).expect(404);
      await http.get(`/v1/files/${c2.coverFileId}`).expect(200);
      await http
        .post('/v1/shop/cover')
        .set(auth(cashier, awaBiz))
        .attach('file', png, { filename: 'c.png' })
        .expect(403);
      expect((await http.delete('/v1/shop/cover').set(A()).expect(200)).body.coverFileId).toBeNull();
      const c3 = (await http.post('/v1/shop/cover').set(A()).attach('file', png, { filename: 'c.png' }).expect(201))
        .body;

      const o = (await http.get('/v1/shop').set(A()).expect(200)).body;
      expect(o).toMatchObject({
        path: `/s/${slug}`,
        settings: { enabled: true, minOrder: 10000, coverFileId: c3.coverFileId },
      });
      expect(o.stats.publishedProducts).toBeGreaterThanOrEqual(2);
    });

    it('vitrine publique et page web', async () => {
      const v = (await http.get(pub()).expect(200)).body;
      expect(v.shop).toMatchObject({
        slug,
        name: 'Awa Beauté en ligne',
        tagline: 'Le beau pagne de Dakar',
        coverFileId: expect.any(String),
        whatsapp: '+221771112233',
        deliveryFee: 1000,
        minOrder: 10000,
      });
      const names = v.products.map((p: { name: string }) => p.name);
      expect(names).toEqual(expect.arrayContaining(['Pagne tissé', 'Bazin riche']));
      expect(names).not.toContain('Produit caché');
      expect(v.products.find((p: { id: string }) => p.id === bazin)).toMatchObject({
        available: true,
        maxQuantity: 3,
        price: 15000,
      });
      expect(JSON.stringify(v)).not.toMatch(/cost|onHand/); // ni coût d'achat ni stock exact

      const page = await http.get(`/s/${slug}`).expect(200);
      expect(page.headers['content-type']).toContain('text/html');
      expect(page.text).toContain(`var SLUG = "${slug}";`);
      await http.get(`/s/${slug}/c/01938000-0000-7000-8000-000000000001`).expect(200);
      await http.get('/s/Pas_Valide!').expect(404);
    });

    it('commande d’un client : contrôles, prix serveur, fiche client créée, sans doublon', async () => {
      order = '01938000-0000-7000-8000-00000000cd01';
      const base = { id: order, customerName: 'Ndèye Sarr', customerPhone: '76 555 44 33', mode: 'delivery' };
      const noAddress = await http
        .post(`${pub()}/orders`)
        .send({ ...base, items: [{ productId: bazin, quantity: 1 }] })
        .expect(422);
      expect(noAddress.body.error.message).toBe('Indiquez l’adresse de livraison');
      const tooMany = await http
        .post(`${pub()}/orders`)
        .send({ ...base, address: 'Ouakam', items: [{ productId: bazin, quantity: 4 }] })
        .expect(422);
      expect(tooMany.body.error.message).toBe('« Bazin riche » : 3 disponible(s) seulement');
      await http
        .post(`${pub()}/orders`)
        .send({ ...base, address: 'Ouakam', items: [{ productId: cache, quantity: 1 }] })
        .expect(404);
      const small = await http
        .post(`${pub()}/orders`)
        .send({ ...base, address: 'Ouakam', items: [{ productId: pagne, quantity: 0 }] })
        .expect(422);
      expect(small.body.error.code).toBe('VALIDATION_FAILED');
      const min = await http
        .post(`${pub()}/orders`)
        .send({ ...base, address: 'Ouakam', items: [{ productId: pagne, quantity: 0.5 }] })
        .expect(422);
      expect(min.body.error.code).toBe('VALIDATION_FAILED');
      await http
        .post(`${pub()}/orders`)
        .send({ ...base, customerPhone: '12', address: 'Ouakam', items: [{ productId: pagne, quantity: 1 }] })
        .expect(422);
      const below = await http
        .post(`${pub()}/orders`)
        .send({ ...base, address: 'Ouakam', items: [{ productId: pagne, quantity: 1 }] })
        .expect(422);
      expect(below.body.error.message).toBe('Commande minimum : 10 000 F');

      const body = {
        ...base,
        address: 'Ouakam, près de la mosquée',
        note: 'Appeler avant',
        items: [
          { productId: pagne, quantity: 2 },
          { productId: bazin, quantity: 1, unitPrice: 1 }, // un prix envoyé par le client est ignoré
        ],
      };
      const placed = await http.post(`${pub()}/orders`).send(body).expect(201);
      expect(placed.body).toMatchObject({
        number: `CMD-${year}-0001`,
        status: 'new',
        statusLabel: 'Nouvelle',
        subtotal: 30000,
        deliveryFee: 1000,
        total: 31000,
      });
      expect(placed.body.contactId).toBeUndefined();
      const again = await http.post(`${pub()}/orders`).send(body).expect(200);
      expect(again.body.number).toBe(`CMD-${year}-0001`);

      const contacts = (await http.get('/v1/contacts?search=Ndèye').set(A()).expect(200)).body.data;
      expect(contacts).toEqual([
        expect.objectContaining({ name: 'Ndèye Sarr', phone: '+221765554433', type: 'customer' }),
      ]);
      expect((await http.get('/v1/shop').set(A())).body.stats.newOrders).toBe(1);
    });

    it('suivi par le commerçant jusqu’à la vente : stock, caisse, crédit ; suivi client', async () => {
      // Le caissier voit et traite les commandes
      const list = (await http.get('/v1/shop/orders?filter=new').set(auth(cashier, awaBiz)).expect(200)).body;
      expect(list.data.map((o: { id: string }) => o.id)).toEqual([order]);
      expect(list.data[0]).toMatchObject({ customerName: 'Ndèye Sarr', mode: 'delivery', total: 31000, lineCount: 2 });
      const detail = (await http.get(`/v1/shop/orders/${order}`).set(auth(cashier, awaBiz)).expect(200)).body;
      expect(detail).toMatchObject({ address: 'Ouakam, près de la mosquée', note: 'Appeler avant', deliveryFee: 1000 });
      expect(detail.lines[1]).toMatchObject({ name: 'Bazin riche', quantity: 1, unitPrice: 15000 });
      const early = await http
        .post(`/v1/shop/orders/${order}/status`)
        .set(A())
        .send({ status: 'completed' })
        .expect(409);
      expect(early.body.error.message).toBe('Une commande « nouvelle » ne peut pas passer à « livrée »');

      await http.post(`/v1/shop/orders/${order}/status`).set(A()).send({ status: 'confirmed' }).expect(200);
      await http.post(`/v1/shop/orders/${order}/status`).set(A()).send({ status: 'ready' }).expect(200);
      await http.post(`/v1/shop/orders/${order}/status`).set(A()).send({ status: 'delivering' }).expect(200);
      expect((await http.get(`${pub()}/orders/${order}`).expect(200)).body).toMatchObject({
        status: 'delivering',
        statusLabel: 'En livraison',
      });

      // Le livreur encaisse 20 000 F par Wave : le reste (11 000 F) passe au carnet de crédit
      const done = await http
        .post(`/v1/shop/orders/${order}/status`)
        .set(A())
        .send({ status: 'completed', payment: { method: 'wave', amount: 20000 } })
        .expect(200);
      expect(done.body).toMatchObject({ status: 'completed', saleId: order });
      const sale = (await http.get(`/v1/sales/${order}`).set(A()).expect(200)).body;
      expect(sale).toMatchObject({ total: 31000, paid: 20000, due: 11000, note: `Commande en ligne CMD-${year}-0001` });
      expect(sale.items.map((i: { name: string }) => i.name)).toEqual(['Pagne tissé', 'Bazin riche', 'Livraison']);
      await relay.relayOnce();
      const stock = await waitFor(
        async () =>
          (await http.get('/v1/inventory/stock').set(A())).body.items as { productId: string; onHand: number }[],
        (items) => Number(items.find((i) => i.productId === bazin)?.onHand) === 2,
      );
      expect(Number(stock.find((i) => i.productId === pagne)?.onHand)).toBe(3);

      await http.post(`/v1/shop/orders/${order}/status`).set(A()).send({ status: 'cancelled' }).expect(409);
      expect((await http.get(`${pub()}/orders/${order}`).expect(200)).body.statusLabel).toBe('Livrée');
    });

    it('retrait en boutique : pas d’étape livraison ; annulation avec motif', async () => {
      const id = '01938000-0000-7000-8000-00000000cd02';
      const placed = await http
        .post(`${pub()}/orders`)
        .send({
          id,
          customerName: 'Ndèye Sarr',
          customerPhone: '+221765554433',
          mode: 'pickup',
          items: [{ productId: pagne, quantity: 2 }],
        })
        .expect(201);
      expect(placed.body).toMatchObject({ number: `CMD-${year}-0002`, deliveryFee: 0, total: 15000, address: null });
      // Même client : pas de doublon dans l'annuaire
      expect((await http.get('/v1/contacts?search=Ndèye').set(A())).body.data).toHaveLength(1);

      await http.post(`/v1/shop/orders/${id}/status`).set(A()).send({ status: 'confirmed' }).expect(200);
      const noRide = await http
        .post(`/v1/shop/orders/${id}/status`)
        .set(A())
        .send({ status: 'delivering' })
        .expect(409);
      expect(noRide.body.error.message).toBe('Une commande « confirmée » ne peut pas passer à « en livraison »');
      const cancelled = await http
        .post(`/v1/shop/orders/${id}/status`)
        .set(A())
        .send({ status: 'cancelled', reason: 'Client injoignable' })
        .expect(200);
      expect(cancelled.body).toMatchObject({ status: 'cancelled', cancelReason: 'Client injoignable', saleId: null });
      const done = (await http.get('/v1/shop/orders?filter=done').set(A()).expect(200)).body.data;
      expect(done.map((o: { id: string }) => o.id)).toEqual([id, order]);

      // Boutique refermée : la vitrine disparaît, le suivi aussi
      await http.put('/v1/shop/settings').set(A()).send({ enabled: false }).expect(200);
      await http.get(pub()).expect(404);
      await http.put('/v1/shop/settings').set(A()).send({ enabled: true }).expect(200);
    });

    it('couleur de la boutique : enregistrée, vérifiée, appliquée à la vitrine (lisible)', async () => {
      const A = () => auth(awa.accessToken, awaBiz);
      const r = await http.patch('/v1/business').set(A()).send({ brandColor: 'ffd600' }).expect(200);
      expect(r.body.business.brandColor).toBe('#FFD600');
      expect((await http.get('/v1/business').set(A()).expect(200)).body.business.brandColor).toBe('#FFD600');
      await http.patch('/v1/business').set(A()).send({ brandColor: 'jaune' }).expect(422);
      const slugNow = (await http.get('/v1/business').set(A())).body.business.slug as string;
      const shop = (await http.get(`/v1/public/shops/${slugNow}`).expect(200)).body.shop;
      // Jaune trop clair pour du texte blanc : la vitrine reçoit une version assombrie
      expect(shop.brandColor).toMatch(/^#[0-9A-F]{6}$/);
      expect(shop.brandColor).not.toBe('#FFD600');
      await http.patch('/v1/business').set(A()).send({ brandColor: null }).expect(200);
      expect((await http.get(`/v1/public/shops/${slugNow}`).expect(200)).body.shop.brandColor).toBeNull();
    });
  });

  describe('Clôture de caisse', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let cashier: string;
    let other: string;
    let product: string;
    let client: string;
    let session: string;
    const year = new Date().getUTCFullYear();
    const C = () => auth(cashier, awaBiz);

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770003322', fullName: 'Modou Gaye', roleKey: 'cashier' })
        .expect(201);
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770003311', fullName: 'Fama Ndao', roleKey: 'cashier' })
        .expect(201);
      cashier = (await login('+221770003322')).accessToken;
      modouToken = cashier;
      other = (await login('+221770003311')).accessToken;
      product = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Thé Ataya', price: 5000, trackStock: false })
          .expect(201)
      ).body.id;
      client = (await http.post('/v1/contacts').set(A()).send({ name: 'Pape Diouf' }).expect(201)).body.id;
    });

    it('ouverture avec fond de caisse, une seule caisse ouverte par vendeur', async () => {
      expect((await http.get('/v1/cash/current').set(C()).expect(200)).body.session).toBeNull();
      await http
        .post('/v1/cash/current/movements')
        .set(C())
        .send({ direction: 'in', amount: 100, reason: 'Monnaie' })
        .expect(409);
      const opened = await http
        .post('/v1/cash/open')
        .set(C())
        .send({ openingFloat: 10000, note: 'Monnaie du matin' })
        .expect(201);
      session = opened.body.id;
      expect(opened.body).toMatchObject({
        number: `Z-${year}-0001`,
        status: 'open',
        openingFloat: 10000,
        userName: 'Modou Gaye',
      });
      expect(opened.body.report.methods).toEqual([expect.objectContaining({ method: 'cash', expected: 10000 })]);
      const again = await http.post('/v1/cash/open').set(C()).send({ openingFloat: 0 }).expect(409);
      expect(again.body.error.message).toBe(`Votre caisse est déjà ouverte depuis Z-${year}-0001`);
    });

    it('attendu en direct : ventes, crédit, remboursements, dépenses, mouvements', async () => {
      const sell = (body: Record<string, unknown>, token = cashier) =>
        http.post('/v1/sales').set(auth(token, awaBiz)).send(body).expect(201);
      await sell({
        items: [{ productId: product, quantity: 2 }],
        payments: [
          { method: 'cash', amount: 6000 },
          { method: 'wave', amount: 4000 },
        ],
      });
      await sell({
        customerId: client,
        items: [{ productId: product, quantity: 1 }],
        payments: [{ method: 'cash', amount: 1000 }],
      });
      // Vente d'un autre vendeur : pas dans cette caisse
      await sell({ items: [{ productId: product, quantity: 1 }], payments: [{ method: 'cash', amount: 5000 }] }, other);
      await http
        .post(`/v1/sales/customers/${client}/repayments`)
        .set(C())
        .send({ amount: 1500, method: 'orange_money' })
        .expect(201);
      await http
        .post('/v1/sales/expenses')
        .set(C())
        .send({ category: 'Transport', amount: 2000, method: 'cash' })
        .expect(201);

      const tooMuch = await http
        .post('/v1/cash/current/movements')
        .set(C())
        .send({ direction: 'out', amount: 50000, reason: 'Dépôt banque' })
        .expect(422);
      expect(tooMuch.body.error.message).toBe('Il n’y a que 15 000 F en espèces dans la caisse');
      await http
        .post('/v1/cash/current/movements')
        .set(C())
        .send({ direction: 'out', amount: 3000, reason: 'Dépôt à la banque' })
        .expect(201);
      const cur = (
        await http
          .post('/v1/cash/current/movements')
          .set(C())
          .send({ direction: 'in', amount: 500, reason: 'Appoint du gérant' })
          .expect(201)
      ).body;

      expect(cur.report).toMatchObject({ salesCount: 2, salesTotal: 15000, creditTotal: 4000 });
      const by = Object.fromEntries(
        cur.report.methods.map((m: { method: string; expected: number }) => [m.method, m.expected]),
      );
      expect(by).toEqual({ cash: 10000 + 6000 + 1000 - 2000 - 3000 + 500, wave: 4000, orange_money: 1500 });
      expect(cur.movements.map((m: { direction: string; amount: number }) => [m.direction, m.amount])).toEqual([
        ['out', 3000],
        ['in', 500],
      ]);
    });

    it('clôture : comptage, écarts, rapport Z figé ; droits', async () => {
      // Un autre vendeur ne voit pas ma caisse, ne peut pas la clôturer
      await http.get(`/v1/cash/sessions/${session}`).set(auth(other, awaBiz)).expect(403);
      await http.post(`/v1/cash/sessions/${session}/close`).set(auth(other, awaBiz)).send({ counted: {} }).expect(403);

      const closed = await http
        .post('/v1/cash/current/close')
        .set(C())
        .send({ counted: { cash: 12000, wave: 4000 }, note: 'Manque 500 F' })
        .expect(200);
      expect(closed.body).toMatchObject({
        status: 'closed',
        difference: -500,
        closingNote: 'Manque 500 F',
        closedByName: 'Modou Gaye',
      });
      expect(closed.body.lines).toEqual([
        { method: 'cash', expected: 12500, counted: 12000, difference: -500 },
        { method: 'wave', expected: 4000, counted: 4000, difference: 0 },
        { method: 'orange_money', expected: 1500, counted: 1500, difference: 0 },
      ]);
      await http.post('/v1/cash/current/close').set(C()).send({ counted: {} }).expect(409);
      expect((await http.get('/v1/cash/current').set(C())).body.session).toBeNull();

      // Une vente après la clôture ne change pas le rapport figé
      await http
        .post('/v1/sales')
        .set(C())
        .send({ items: [{ productId: product, quantity: 1 }], payments: [{ method: 'cash', amount: 5000 }] })
        .expect(201);
      const z = (await http.get(`/v1/cash/sessions/${session}`).set(C()).expect(200)).body;
      expect(z.report.salesTotal).toBe(15000);

      const mine = (await http.get('/v1/cash/sessions').set(C()).expect(200)).body.data;
      expect(mine).toEqual([
        expect.objectContaining({ id: session, salesTotal: 15000, countedTotal: 17500, difference: -500 }),
      ]);
    });

    it('le gérant voit toutes les caisses et clôture celle d’un vendeur parti', async () => {
      const s2 = (await http.post('/v1/cash/open').set(auth(other, awaBiz)).send({ openingFloat: 5000 }).expect(201))
        .body.id;
      const all = (await http.get('/v1/cash/sessions').set(A()).expect(200)).body.data;
      expect(all.map((x: { userName: string }) => x.userName)).toEqual(
        expect.arrayContaining(['Modou Gaye', 'Fama Ndao']),
      );
      const z = await http
        .post(`/v1/cash/sessions/${s2}/close`)
        .set(A())
        .send({ counted: { cash: 5000 } })
        .expect(200);
      expect(z.body).toMatchObject({
        status: 'closed',
        userName: 'Fama Ndao',
        closedByName: 'Awa Diallo',
        difference: 0,
      });
    });
  });

  describe('Photos produit', () => {
    // PNG 1×1 valide et en-tête JPEG minimal
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      'base64',
    );
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200, 1)]);
    let productId: string;
    let firstFile: string;
    const A = () => auth(awa.accessToken, awaBiz);

    it('envoie une photo et la sert publiquement avec un cache long', async () => {
      productId = (await http.get('/v1/catalog/products?search=Huile').set(A()).expect(200)).body.data[0].id;
      const res = await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(A())
        .attach('file', png, { filename: 'photo.png', contentType: 'image/png' })
        .expect(200);
      expect(res.body.imageFileIds).toHaveLength(1);
      firstFile = res.body.imageFileIds[0];

      const file = await http.get(`/v1/files/${firstFile}`).buffer(true).expect(200); // sans jeton
      expect(file.headers['content-type']).toBe('image/png');
      expect(file.headers['cache-control']).toContain('immutable');
      expect(Buffer.compare(file.body as Buffer, png)).toBe(0);

      const stock = await http.get('/v1/inventory/stock').set(A()).expect(200);
      expect(stock.body.items.find((i: { productId: string }) => i.productId === productId).imageFileId).toBe(
        firstFile,
      );
    });

    it('remplace la photo : l’ancienne disparaît', async () => {
      const res = await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(A())
        .attach('file', jpeg, { filename: 'photo.jpg', contentType: 'image/jpeg' })
        .expect(200);
      expect(res.body.imageFileIds).toHaveLength(1);
      expect(res.body.imageFileIds[0]).not.toBe(firstFile);
      await http.get(`/v1/files/${firstFile}`).expect(404);
      const served = await http.get(`/v1/files/${res.body.imageFileIds[0]}`).expect(200);
      expect(served.headers['content-type']).toBe('image/jpeg');
    });

    it('refuse un faux fichier image, une photo absente ou trop lourde', async () => {
      const fake = await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(A())
        .attach('file', Buffer.from('<svg onload="alert(1)"></svg>'), { filename: 'x.png', contentType: 'image/png' })
        .expect(422);
      expect(fake.body.error.message).toContain('JPEG, PNG ou WebP');

      await http.post(`/v1/catalog/products/${productId}/image`).set(A()).expect(422);

      const big = Buffer.concat([jpeg, Buffer.alloc(1.5 * 1024 * 1024)]);
      const tooBig = await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(A())
        .attach('file', big, { filename: 'big.jpg', contentType: 'image/jpeg' })
        .expect(413);
      expect(tooBig.body.error.code).toBe('PAYLOAD_TOO_LARGE');
    });

    it('protège les photos : droits et isolation entre entreprises', async () => {
      // Un autre commerçant, dans sa propre entreprise, ne voit pas ce produit
      await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(auth(moussa.accessToken, moussaBiz))
        .attach('file', png, { filename: 'p.png', contentType: 'image/png' })
        .expect(404);
      // Le caissier n'a pas catalog:write
      const cashierRes = await http
        .post(`/v1/catalog/products/${productId}/image`)
        .set(auth(cashierToken, awaBiz))
        .attach('file', png, { filename: 'p.png', contentType: 'image/png' })
        .expect(403);
      expect(cashierRes.body.error.code).toBe('INSUFFICIENT_PERMISSION');
      await http.get('/v1/files/not-a-uuid').expect(400);
      await http.get('/v1/files/01930000-0000-7000-8000-0000000000ff').expect(404);
    });

    it('supprime la photo', async () => {
      const before = (await http.get(`/v1/catalog/products/${productId}`).set(A())).body.imageFileIds[0];
      const res = await http.delete(`/v1/catalog/products/${productId}/image`).set(A()).expect(200);
      expect(res.body.imageFileIds).toEqual([]);
      await http.get(`/v1/files/${before}`).expect(404);
    });

    it('galerie : plusieurs photos, photo principale au choix, 5 au maximum', async () => {
      const add = async () =>
        (
          await http
            .post(`/v1/catalog/products/${productId}/images`)
            .set(A())
            .attach('file', png, { filename: 'p.png', contentType: 'image/png' })
            .expect(200)
        ).body.imageFileIds as string[];
      await add();
      await add();
      const three = await add();
      expect(three).toHaveLength(3);

      // La troisième devient la principale (inventaire et caisse la montrent)
      const order = [three[2], three[0], three[1]];
      const ordered = await http
        .put(`/v1/catalog/products/${productId}/images`)
        .set(A())
        .send({ fileIds: order })
        .expect(200);
      expect(ordered.body.imageFileIds).toEqual(order);
      const stock = await http.get('/v1/inventory/stock').set(A()).expect(200);
      expect(stock.body.items.find((i: { productId: string }) => i.productId === productId).imageFileId).toBe(three[2]);
      // Ordre avec une photo inconnue : refusé
      await http
        .put(`/v1/catalog/products/${productId}/images`)
        .set(A())
        .send({ fileIds: [three[0], three[1]] })
        .expect(422);

      // Retirer une photo : le fichier disparaît, les autres restent dans l'ordre
      const removed = await http.delete(`/v1/catalog/products/${productId}/images/${three[0]}`).set(A()).expect(200);
      expect(removed.body.imageFileIds).toEqual([three[2], three[1]]);
      await http.get(`/v1/files/${three[0]}`).expect(404);

      await add();
      await add();
      await add(); // 5
      const full = await http
        .post(`/v1/catalog/products/${productId}/images`)
        .set(A())
        .attach('file', png, { filename: 'p.png', contentType: 'image/png' })
        .expect(422);
      expect(full.body.error.message).toContain('5 photos');
      // Le caissier ne touche pas aux photos
      await http
        .delete(`/v1/catalog/products/${productId}/images/${three[1]}`)
        .set(auth(cashierToken, awaBiz))
        .expect(403);
    });
  });

  describe('Photo de profil', () => {
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      'base64',
    );
    const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200, 1)]);

    it('ajoute, remplace et retire la photo de profil', async () => {
      const A = () => auth(awa.accessToken);
      const first = await http
        .post('/v1/me/avatar')
        .set(A())
        .attach('file', png, { filename: 'moi.png', contentType: 'image/png' })
        .expect(201);
      const firstId = first.body.user.avatarFileId;
      expect(firstId).toEqual(expect.any(String));
      expect((await http.get('/v1/me').set(A()).expect(200)).body.user.avatarFileId).toBe(firstId);
      await http.get(`/v1/files/${firstId}`).expect(200);

      // Remplacement : l'ancienne photo est supprimée
      const second = await http
        .post('/v1/me/avatar')
        .set(A())
        .attach('file', jpeg, { filename: 'moi.jpg', contentType: 'image/jpeg' })
        .expect(201);
      expect(second.body.user.avatarFileId).not.toBe(firstId);
      await http.get(`/v1/files/${firstId}`).expect(404);

      // Faux fichier refusé, sans jeton refusé
      await http
        .post('/v1/me/avatar')
        .set(A())
        .attach('file', Buffer.from('pas une image'), { filename: 'x.png', contentType: 'image/png' })
        .expect(422);
      await http.post('/v1/me/avatar').attach('file', png, { filename: 'moi.png' }).expect(401);

      const removed = await http.delete('/v1/me/avatar').set(A()).expect(200);
      expect(removed.body.user.avatarFileId).toBeNull();
      await http.get(`/v1/files/${second.body.user.avatarFileId}`).expect(404);
    });
  });

  describe('Notifications', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let cashier: string;
    let manager: string;
    const M = () => auth(manager, awaBiz);
    const C = () => auth(cashier, awaBiz);
    type N = { id: string; kind: string; title: string; body: string; link: string | null; read: boolean };
    const list = async (h: Record<string, string>) =>
      (
        await http
          .get('/v1/notifications')
          .set(h)
          .expect((r) => {
            if (r.status !== 200) throw new Error(JSON.stringify(r.body));
          })
      ).body as { items: N[]; unread: number };

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770004411', fullName: 'Ndèye Fall', roleKey: 'manager' })
        .expect(201);
      manager = (await login('+221770004411')).accessToken;
      cashier = modouToken; // Modou Gaye, vendeur
    });

    it('les événements deviennent des notifications selon le rôle', async () => {
      const mine = await waitFor(
        () => list(A()),
        (l) => l.items.some((n) => n.kind === 'shop_order'),
      );
      const kinds = new Set(mine.items.map((n) => n.kind));
      expect([...kinds]).toEqual(expect.arrayContaining(['welcome', 'stock_low', 'shop_order']));
      const low = mine.items.find((n) => n.title === 'Stock bas : Huile de coco 500 ml');
      expect(low).toMatchObject({ kind: 'stock_low', read: false });
      expect(low!.link).toMatch(/^\/products\/[0-9a-f-]{36}$/);
      expect(mine.unread).toBe(mine.items.filter((n) => !n.read).length);
      expect((await http.get('/v1/notifications/unread-count').set(A()).expect(200)).body.unread).toBe(mine.unread);

      // Le vendeur voit le stock et les commandes, mais pas les annulations de ventes
      const sale = (
        await http
          .post('/v1/sales')
          .set(C())
          .send({
            items: [{ name: 'Sachet de bissap', quantity: 1, unitPrice: 500 }],
            payments: [{ method: 'cash', amount: 500 }],
          })
      ).body;
      if (sale.id) await http.post(`/v1/sales/${sale.id}/void`).set(A()).send({ reason: 'Erreur de prix' }).expect(200);
      await relay.relayOnce();
      const forManager = sale.id
        ? await waitFor(
            () => list(M()),
            (l) => l.items.some((n) => n.link === `/sales/${sale.id}`),
          )
        : await list(M());
      if (sale.id) {
        expect(forManager.items.find((n) => n.link === `/sales/${sale.id}`)).toMatchObject({
          kind: 'sale_voided',
          title: `Vente ${sale.number} annulée`,
          body: 'Annulée par Awa Diallo. La marchandise est revenue en stock.',
          link: `/sales/${sale.id}`,
        });
        // Celle qui a annulé ne reçoit pas sa propre notification ; le vendeur n'y a pas accès
        expect((await list(A())).items.some((n) => n.link === `/sales/${sale.id}`)).toBe(false);
      }
      const forCashier = await list(C());
      expect(forCashier.items.some((n) => n.kind === 'stock_low')).toBe(true);
      expect(forCashier.items.some((n) => n.kind === 'sale_voided')).toBe(false);
    });

    it('rappels : caisse restée ouverte, factures en retard, crédits anciens — une fois par jour', async () => {
      const cur = (await http.get('/v1/cash/current').set(C()).expect(200)).body.session;
      const sessionId =
        cur?.id ?? (await http.post('/v1/cash/open').set(C()).send({ openingFloat: 0 }).expect(201)).body.id;
      await dbs.withTenant(awaBiz, async (tx) => {
        await tx.execute(
          sql`UPDATE sales.cash_sessions SET opened_at = now() - interval '1 day' WHERE id = ${sessionId}`,
        );
        await tx.execute(sql`UPDATE invoicing.documents SET due_date = current_date - 3
          WHERE kind = 'invoice' AND status IN ('unpaid', 'partial')`);
        await tx.execute(sql`UPDATE sales.customer_ledger SET occurred_at = occurred_at - interval '40 days'`);
      });
      const unpaid = await dbs.withTenant(
        awaBiz,
        async (tx) =>
          (
            await tx.execute(sql`SELECT count(*)::int AS n FROM invoicing.documents
          WHERE kind = 'invoice' AND status IN ('unpaid', 'partial')`)
          ).rows[0] as { n: number },
      );

      const forCashier = await list(C());
      expect(forCashier.items.find((n) => n.kind === 'cash_open')).toMatchObject({
        title: 'Votre caisse est toujours ouverte',
        link: '/cash',
      });
      expect(forCashier.items.some((n) => n.kind === 'cash_open_team')).toBe(false);

      const forOwner = await list(A());
      expect(forOwner.items.some((n) => n.kind === 'cash_open')).toBe(false); // personnelle au vendeur
      expect(forOwner.items.find((n) => n.kind === 'cash_open_team')?.title).toMatch(/caisses? (sont|est) restée/);
      if (unpaid.n > 0) {
        expect(forOwner.items.find((n) => n.kind === 'invoices_overdue')).toMatchObject({
          title: unpaid.n > 1 ? `${unpaid.n} factures en retard` : '1 facture en retard',
          link: '/reminders',
        });
      }
      expect(forOwner.items.find((n) => n.kind === 'credit_stale')?.title).toMatch(/rien remboursé depuis 30 jours/);

      // Pas de doublon en rouvrant la cloche
      const again = await list(A());
      expect(again.items.filter((n) => n.kind === 'cash_open_team')).toHaveLength(1);
      expect(again.items.filter((n) => n.kind === 'credit_stale')).toHaveLength(1);
    });

    it('lu, tout lu, et pas d’accès aux notifications des autres', async () => {
      const before = await list(A());
      const first = before.items.find((n) => !n.read)!;
      const res = await http.post(`/v1/notifications/${first.id}/read`).set(A()).expect(200);
      expect(res.body.unread).toBe(before.unread - 1);
      // Lu pour Awa seulement
      const sameForManager = (await list(M())).items.find((n) => n.id === first.id);
      if (sameForManager) expect(sameForManager.read).toBe(false);

      // La notification personnelle du vendeur n'existe pas pour Awa
      const personal = (await list(C())).items.find((n) => n.kind === 'cash_open')!;
      await http.post(`/v1/notifications/${personal.id}/read`).set(A()).expect(404);
      await http.post('/v1/notifications/0193aaaa-0000-7000-8000-000000000000/read').set(A()).expect(404);

      expect((await http.post('/v1/notifications/read-all').set(A()).expect(200)).body.unread).toBe(0);
      const after = await list(A());
      expect(after.unread).toBe(0);
      expect(after.items.every((n) => n.read)).toBe(true);
    });
  });

  describe('Relances', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    type Item = {
      kind: string;
      id: string;
      customerId: string;
      name: string;
      amount: number;
      daysLate: number;
      due: boolean;
      lastRemindedAt: string | null;
      invoiceNumber: string | null;
    };
    type Queue = {
      items: Item[];
      summary: { dueCount: number; dueAmount: number; totalCount: number; remindedThisWeek: number };
      history: {
        channel: string;
        amount: number;
        customerName: string;
        invoiceNumber: string | null;
        byName: string | null;
      }[];
    };
    const queue = async () => (await http.get('/v1/reminders').set(A()).expect(200)).body as Queue;

    beforeAll(async () => {
      const client = (
        await http
          .post('/v1/contacts')
          .set(A())
          .send({ name: 'Restaurant Le Lagon', phone: '33 821 00 00' })
          .expect(201)
      ).body.id;
      const inv = (
        await http
          .post('/v1/invoicing/documents')
          .set(A())
          .send({
            kind: 'invoice',
            customerId: client,
            lines: [{ name: 'Traiteur 40 couverts', quantity: 1, unitPrice: 120000 }],
          })
          .expect(201)
      ).body;
      await dbs.withTenant(awaBiz, (tx) =>
        tx.execute(sql`UPDATE invoicing.documents SET due_date = current_date - 3 WHERE id = ${inv.id}`),
      );
    });

    it('réunit crédits et factures impayées, à relancer d’abord', async () => {
      const q = await queue();
      const credit = q.items.find((i) => i.kind === 'credit' && i.name === 'Ndèye Sarr')!;
      expect(credit).toMatchObject({ due: true, lastRemindedAt: null });
      expect(credit.amount).toBeGreaterThan(0);
      expect(credit.daysLate).toBeGreaterThanOrEqual(40); // dettes reculées de 40 jours plus haut
      const invoices = q.items.filter((i) => i.kind === 'invoice');
      expect(invoices.length).toBeGreaterThan(0);
      for (const i of invoices) {
        expect(i.invoiceNumber).toMatch(/^FAC-/);
        expect(i.daysLate).toBe(3);
        expect(i.due).toBe(true);
      }
      // À relancer en tête de liste
      const firstNotDue = q.items.findIndex((i) => !i.due);
      if (firstNotDue >= 0) expect(q.items.slice(firstNotDue).every((i) => !i.due)).toBe(true);
      expect(q.summary.dueCount).toBe(q.items.filter((i) => i.due).length);
      expect(q.summary.dueAmount).toBe(q.items.filter((i) => i.due).reduce((s, i) => s + i.amount, 0));
      expect(q.summary.totalCount).toBe(q.items.length);
    });

    it('un rappel sort la ligne de la file pour une semaine et entre dans l’historique', async () => {
      const q = await queue();
      const credit = q.items.find((i) => i.kind === 'credit' && i.name === 'Ndèye Sarr')!;
      const invoice = q.items.find((i) => i.kind === 'invoice')!;

      await http
        .post('/v1/reminders')
        .set(A())
        .send({ kind: 'credit', id: credit.id, channel: 'whatsapp' })
        .expect(201);
      await http.post('/v1/reminders').set(A()).send({ kind: 'invoice', id: invoice.id, channel: 'sms' }).expect(201);
      // L'ancienne route de la fiche client passe aussi par l'historique
      await http.post(`/v1/customers/${credit.id}/reminders`).set(A()).send({ channel: 'call' }).expect(201);

      const after = await queue();
      expect(after.items.find((i) => i.id === credit.id)).toMatchObject({ due: false });
      expect(after.items.find((i) => i.id === credit.id)!.lastRemindedAt).not.toBeNull();
      expect(after.items.find((i) => i.id === invoice.id)).toMatchObject({ due: false });
      expect(after.summary.dueCount).toBe(q.summary.dueCount - 2);
      expect(after.summary.remindedThisWeek).toBe(q.summary.remindedThisWeek + 3);
      expect(after.history.slice(0, 3)).toEqual([
        expect.objectContaining({
          channel: 'call',
          customerName: 'Ndèye Sarr',
          invoiceNumber: null,
          byName: 'Awa Diallo',
        }),
        expect.objectContaining({ channel: 'sms', invoiceNumber: invoice.invoiceNumber, amount: invoice.amount }),
        expect.objectContaining({ channel: 'whatsapp', customerName: 'Ndèye Sarr', amount: credit.amount }),
      ]);

      await http
        .post('/v1/reminders')
        .set(A())
        .send({ kind: 'invoice', id: '0193aaaa-0000-7000-8000-000000000000' })
        .expect(404);
      await http.post('/v1/reminders').set(A()).send({ kind: 'devis', id: invoice.id }).expect(422);
    });
  });

  describe('Fidélité', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const now = new Date();
    let khady: string;
    const sell = (body: Record<string, unknown>) => http.post('/v1/sales').set(A()).send(body);
    const card = async () => (await http.get(`/v1/loyalty/customers/${khady}`).set(A()).expect(200)).body;

    beforeAll(async () => {
      khady = (
        await http
          .post('/v1/contacts')
          .set(A())
          .send({
            name: 'Khady Ndiaye',
            phone: '77 640 11 22',
            birthDay: now.getUTCDate(),
            birthMonth: now.getUTCMonth() + 1,
          })
          .expect(201)
      ).body.id;
    });

    it('programme désactivé par défaut ; réglages réservés au gérant et vérifiés', async () => {
      expect((await http.get('/v1/loyalty/settings').set(A()).expect(200)).body.enabled).toBe(false);
      const s = await sell({
        customerId: khady,
        items: [{ name: 'Thiouraye', quantity: 1, unitPrice: 5000 }],
        payments: [{ method: 'cash', amount: 5000 }],
      }).expect(201);
      expect(s.body.loyalty).toBeNull();

      await http
        .put('/v1/loyalty/settings')
        .set(auth(modouToken, awaBiz))
        .send({ enabled: true, earnPer: 1000, rewardPoints: 10, rewardValue: 500 })
        .expect(403);
      await http
        .put('/v1/loyalty/settings')
        .set(A())
        .send({ enabled: true, earnPer: 100, rewardPoints: 1, rewardValue: 500 })
        .expect(422);
      const r = await http
        .put('/v1/loyalty/settings')
        .set(A())
        .send({ enabled: true, earnPer: 1000, rewardPoints: 10, rewardValue: 500 })
        .expect(200);
      expect(r.body).toEqual({ enabled: true, earnPer: 1000, rewardPoints: 10, rewardValue: 500 });
      expect((await http.get(`/v1/customers/${khady}`).set(A()).expect(200)).body.customer).toMatchObject({
        birthDay: now.getUTCDate(),
        birthMonth: now.getUTCMonth() + 1,
      });
    });

    let firstSale: string;
    let secondSale: string;
    it('points gagnés à l’achat, récompense utilisée en remise', async () => {
      const s1 = await sell({
        customerId: khady,
        items: [{ name: 'Bazin', quantity: 1, unitPrice: 12500 }],
        payments: [{ method: 'cash', amount: 12500 }],
      }).expect(201);
      firstSale = s1.body.id;
      expect(s1.body.loyalty).toEqual({ earned: 12, redeemed: 0, balance: 12 });
      expect(await card()).toMatchObject({ balance: 12, rewardsAvailable: 1, pointsToNextReward: 8 });

      const s2 = await sell({
        customerId: khady,
        items: [{ name: 'Encens', quantity: 1, unitPrice: 3000 }],
        redeemRewards: 1,
        payments: [{ method: 'cash', amount: 2500 }],
      }).expect(201);
      secondSale = s2.body.id;
      expect(s2.body).toMatchObject({ subtotal: 3000, discount: 500, total: 2500, paid: 2500 });
      expect(s2.body.loyalty).toEqual({ earned: 2, redeemed: 10, balance: 4 });

      const refused = await sell({
        customerId: khady,
        items: [{ name: 'Encens', quantity: 1, unitPrice: 3000 }],
        redeemRewards: 1,
        payments: [{ method: 'cash', amount: 2500 }],
      }).expect(409);
      expect(refused.body.error.details).toEqual({ balance: 4, points: 10 });
      await sell({
        items: [{ name: 'Encens', quantity: 1, unitPrice: 3000 }],
        redeemRewards: 1,
        payments: [{ method: 'cash', amount: 2500 }],
      }).expect(422);
      expect(firstSale).toBeTruthy();
    });

    it('vente annulée : points gagnés retirés, points utilisés rendus', async () => {
      await http.post(`/v1/sales/${secondSale}/void`).set(A()).send({ reason: 'Erreur de caisse' }).expect(200);
      expect((await card()).balance).toBe(12);
      const kinds = (await card()).history.map((h: { kind: string; points: number }) => [h.kind, h.points]);
      expect(kinds[0]).toEqual(['reverse', 8]);
    });

    it('cadeau du gérant, pas de solde négatif', async () => {
      expect(
        (
          await http
            .post(`/v1/loyalty/customers/${khady}/adjust`)
            .set(A())
            .send({ points: 5, reason: 'Cadeau fidélité' })
            .expect(201)
        ).body.balance,
      ).toBe(17);
      await http
        .post(`/v1/loyalty/customers/${khady}/adjust`)
        .set(A())
        .send({ points: -100, reason: 'Erreur' })
        .expect(409);
      await http
        .post(`/v1/loyalty/customers/${khady}/adjust`)
        .set(auth(modouToken, awaBiz))
        .send({ points: 5, reason: 'Moi' })
        .expect(403);
    });

    it('tableau de bord : meilleurs clients, anniversaires, et notification du jour', async () => {
      const d = (await http.get('/v1/loyalty').set(A()).expect(200)).body;
      expect(d.settings.enabled).toBe(true);
      expect(d.top.find((t: { name: string }) => t.name === 'Khady Ndiaye')).toMatchObject({ visits: 2, points: 17 });
      expect(d.birthdays[0]).toMatchObject({ name: 'Khady Ndiaye', inDays: 0, points: 17 });
      expect(d.stats.members).toBeGreaterThanOrEqual(1);
      const notifs = (await http.get('/v1/notifications').set(A()).expect(200)).body.items as {
        kind: string;
        title: string;
      }[];
      expect(notifs.find((n) => n.kind === 'birthday')?.title).toBe('Anniversaire de Khady Ndiaye aujourd’hui');
    });
  });

  describe('Analyses', () => {
    const A = () => auth(awa.accessToken, awaBiz);

    it('heures de pointe, marges par produit, produits qui dorment ; droits et validation', async () => {
      const r = (await http.get('/v1/reports/insights?days=30').set(A()).expect(200)).body;
      expect(r.period.days).toBe(30);
      expect(r.byHour).toHaveLength(24);
      expect(r.byWeekday).toHaveLength(7);
      const sold = r.byHour.reduce((s: number, h: { salesCount: number }) => s + h.salesCount, 0);
      expect(sold).toBeGreaterThan(0);
      expect(r.peak).toEqual(expect.objectContaining({ from: expect.any(Number), share: expect.any(Number) }));

      const karite = r.margins.products.find((p: { name: string }) => p.name === 'Beurre de karité 250 g');
      expect(karite).toMatchObject({ costKnown: true });
      expect(karite.profit).toBe(karite.revenue - karite.cost);
      // Lignes libres sans coût (« Thiouraye ») : marge inconnue, pas comptée comme faible
      const libre = r.margins.products.find((p: { name: string }) => p.name === 'Thiouraye');
      expect(libre).toMatchObject({ costKnown: false, marginRate: null });
      expect(r.margins.lowMargin.every((p: { costKnown: boolean }) => p.costKnown)).toBe(true);
      expect(r.margins.unknownCostCount).toBeGreaterThan(0);

      // Produits tout juste créés : jamais « dormants » (il faut avoir eu le temps de les vendre)
      expect(r.dormant).toMatchObject({ days: 30, count: 0, stockValue: 0, items: [] });

      await http.get('/v1/reports/insights?days=3').set(A()).expect(422);
      await http.get('/v1/reports/insights').set(auth(modouToken, awaBiz)).expect(403);
    });

    it('rapport de la semaine : chiffres et texte prêt pour WhatsApp', async () => {
      const today = new Date().toISOString().slice(0, 10);
      const w = (await http.get(`/v1/reports/weekly?week=${today}`).set(A()).expect(200)).body;
      expect(w.businessName).toBeTruthy();
      expect(w.salesCount).toBeGreaterThan(0);
      expect(w.text).toContain(`*${w.businessName} — semaine du`);
      expect(w.text).toContain("Chiffre d'affaires");
      expect(w.text).toContain('Envoyé depuis Sama360');
      // Sans date : la semaine complète précédente (lundi → dimanche)
      const last = (await http.get('/v1/reports/weekly').set(A()).expect(200)).body;
      expect(new Date(`${last.from}T00:00:00Z`).getUTCDay()).toBe(1);
      expect(new Date(`${last.to}T00:00:00Z`).getUTCDay()).toBe(0);
      await http.get('/v1/reports/weekly?week=17-11-2026').set(A()).expect(422);
      await http.get('/v1/reports/weekly').set(auth(modouToken, awaBiz)).expect(403);
    });
  });

  describe('Caisse obligatoire', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let seller: string;
    const S = () => auth(seller, awaBiz);
    const sale = (extra: Record<string, unknown> = {}) => ({
      items: [{ name: 'Sachet', quantity: 1, unitPrice: 100 }],
      payments: [{ method: 'cash', amount: 100 }],
      ...extra,
    });

    beforeAll(async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770003399', fullName: 'Ibou Sarr', roleKey: 'cashier' })
        .expect(201);
      seller = (await login('+221770003399')).accessToken;
    });

    afterAll(async () => {
      await http.patch('/v1/business').set(A()).send({ requireOpenCash: false }).expect(200);
    });

    it('désactivée par défaut ; seul le patron peut l’activer', async () => {
      expect((await http.get('/v1/business').set(A()).expect(200)).body.business.requireOpenCash).toBe(false);
      await http.post('/v1/sales').set(S()).send(sale()).expect(201);
      await http.patch('/v1/business').set(S()).send({ requireOpenCash: true }).expect(403);
      const r = await http.patch('/v1/business').set(A()).send({ requireOpenCash: true }).expect(200);
      expect(r.body.business.requireOpenCash).toBe(true);
    });

    it('activée : vente refusée sans caisse ouverte, acceptée après ouverture ; hors ligne toujours acceptée', async () => {
      const refused = await http.post('/v1/sales').set(S()).send(sale()).expect(409);
      expect(refused.body.error).toMatchObject({ code: 'CASH_CLOSED', message: 'Ouvrez la caisse pour vendre' });

      // Vente faite hors ligne (déjà conclue en boutique) : enregistrée quand même
      const soldAt = new Date(Date.now() - 3600 * 1000).toISOString();
      await http
        .post('/v1/sales')
        .set(S())
        .send(sale({ id: '01937a00-0000-7000-8000-0000000cc001', soldAt }))
        .expect(201);

      await http.post('/v1/cash/open').set(S()).send({ openingFloat: 0 }).expect(201);
      await http.post('/v1/sales').set(S()).send(sale()).expect(201);
    });
  });

  describe('Documents', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const png = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
      'base64',
    );
    const pdf = Buffer.from('%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n');
    const inDays = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
    let bail: string;

    it('ajout d’un PDF avec échéance, liste par catégorie, recherche', async () => {
      const r = await http
        .post('/v1/documents')
        .set(A())
        .field('title', 'Bail boutique Sandaga')
        .field('category', 'contract')
        .field('note', 'Loyer payé le 5 du mois')
        .field('expiresOn', inDays(10))
        .attach('file', pdf, { filename: 'bail.pdf' })
        .expect(201);
      bail = r.body.id;
      expect(r.body).toMatchObject({
        title: 'Bail boutique Sandaga',
        category: 'contract',
        mime: 'application/pdf',
        expiresInDays: 10,
        expiry: 'soon',
        createdByName: 'Awa Diallo',
      });
      expect(r.body.fileId).toBeUndefined();

      await http
        .post('/v1/documents')
        .set(A())
        .field('title', 'NINEA')
        .field('category', 'admin')
        .field('expiresOn', '')
        .attach('file', png, { filename: 'ninea.png' })
        .expect(201);

      const list = (await http.get('/v1/documents').set(A()).expect(200)).body;
      expect(list.total).toBe(2);
      expect(list.counts).toEqual({ contract: 1, admin: 1 });
      expect(list.attention).toBe(1);
      const contracts = (await http.get('/v1/documents?category=contract').set(A()).expect(200)).body;
      expect(contracts.items.map((d: { title: string }) => d.title)).toEqual(['Bail boutique Sandaga']);
      const found = (await http.get('/v1/documents?search=loyer').set(A()).expect(200)).body;
      expect(found.items).toHaveLength(1);
    });

    it('fichier réservé aux membres autorisés, jamais public', async () => {
      const f = await http.get(`/v1/documents/${bail}/file`).set(A()).expect(200);
      expect(f.headers['content-type']).toBe('application/pdf');
      expect(f.headers['cache-control']).toBe('private, no-store');
      expect(f.headers['content-disposition']).toBe('inline; filename="Bail boutique Sandaga.pdf"');

      // Vendeur : pas d'accès ; autre commerçant : rien
      await http.get('/v1/documents').set(auth(modouToken, awaBiz)).expect(403);
      await http.get(`/v1/documents/${bail}/file`).set(auth(modouToken, awaBiz)).expect(403);
      await http.get(`/v1/documents/${bail}`).set(auth(moussa.accessToken, moussaBiz)).expect(404);
    });

    it('formats refusés, modification, alerte d’échéance, suppression', async () => {
      const bad = await http
        .post('/v1/documents')
        .set(A())
        .field('title', 'Texte')
        .field('category', 'other')
        .attach('file', Buffer.from('juste du texte'), { filename: 'a.txt' })
        .expect(422);
      expect(bad.body.error.message).toBe('Format non accepté : photo (JPEG, PNG, WebP) ou PDF');
      await http.post('/v1/documents').set(A()).field('title', 'Sans fichier').field('category', 'other').expect(422);
      await http
        .post('/v1/documents')
        .set(A())
        .field('title', 'X')
        .field('category', 'inconnu')
        .attach('file', pdf, { filename: 'x.pdf' })
        .expect(422);

      const up = await http
        .patch(`/v1/documents/${bail}`)
        .set(A())
        .send({ title: 'Bail 2026', expiresOn: inDays(5) })
        .expect(200);
      expect(up.body).toMatchObject({ title: 'Bail 2026', expiresInDays: 5, note: 'Loyer payé le 5 du mois' });

      const notifs = (await http.get('/v1/notifications').set(A()).expect(200)).body.items as {
        kind: string;
        title: string;
        link: string;
      }[];
      expect(notifs).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: 'document_expiring',
            title: 'Bail 2026 : échéance bientôt',
            link: `/documents/${bail}`,
          }),
        ]),
      );

      await http.delete(`/v1/documents/${bail}`).set(A()).expect(204);
      await http.get(`/v1/documents/${bail}`).set(A()).expect(404);
      await http.get(`/v1/documents/${bail}/file`).set(A()).expect(404);
    });
  });

  describe('Assistant IA', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    type Reply = { reply: string; tools: string[]; remaining: number };
    const ask = async (h: Record<string, string>, q: string, status = 200) =>
      (
        await http
          .post('/v1/assistant/chat')
          .set(h)
          .send({ messages: [{ role: 'user', content: q }] })
          .expect(status)
      ).body as Reply;

    it('état : activé, questions restantes, suggestions selon le rôle', async () => {
      const s = (await http.get('/v1/assistant').set(A()).expect(200)).body;
      expect(s).toMatchObject({ enabled: true, remaining: 6 });
      expect(s.suggestions).toContain('Quel est mon bénéfice ce mois-ci ?');
      const c = (await http.get('/v1/assistant').set(auth(modouToken, awaBiz)).expect(200)).body;
      expect(c.suggestions).not.toContain('Quel est mon bénéfice ce mois-ci ?');
    });

    it('répond avec les vraies données (outils), selon les droits', async () => {
      const r = await ask(A(), "Combien j'ai vendu aujourd'hui ?");
      expect(r.tools).toEqual(['sales_summary']);
      expect(r.reply).toContain('"revenue":');
      expect(r.reply).toContain('"netProfit":');
      expect(r.remaining).toBe(5);

      const owing = await ask(A(), 'Qui me doit le plus ?');
      expect(owing.tools).toEqual(['customers_owing']);
      expect(owing.reply).toContain('"totalDue":');

      // Vendeur : pas d'accès aux bénéfices ; il ne voit que ses propres ventes du jour
      const mine = await ask(auth(modouToken, awaBiz), "Combien j'ai vendu aujourd'hui ?");
      expect(mine.tools).toEqual(['my_sales_today']);
      expect(mine.reply).not.toContain('netProfit');
      const denied = await ask(auth(modouToken, awaBiz), 'Quels produits ne se vendent plus ?');
      expect(denied.tools).toEqual([]);
      expect(denied.reply).toContain('réservée au propriétaire');
    });

    it('validation et plafond quotidien par boutique', async () => {
      await http.post('/v1/assistant/chat').set(A()).send({ messages: [] }).expect(422);
      await http
        .post('/v1/assistant/chat')
        .set(A())
        .send({ messages: [{ role: 'assistant', content: 'Bonjour' }] })
        .expect(422);
      // 4 questions déjà posées aujourd'hui (Awa et Modou, même boutique) : la 5e et la 6e passent, pas la 7e
      expect((await ask(A(), 'Quels produits sont presque épuisés ?')).tools).toEqual(['low_stock']);
      expect((await ask(A(), 'À quelle heure je vends le plus ?')).remaining).toBe(0);
      const over = await http
        .post('/v1/assistant/chat')
        .set(A())
        .send({ messages: [{ role: 'user', content: 'Encore une ?' }] })
        .expect(429);
      expect(over.body.error.code).toBe('ASSISTANT_LIMIT');
    });
  });

  describe('Réservation', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const today = new Date().toISOString().slice(0, 10);
    const at = (h: number, m = 0) => `${today}T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00.000Z`;
    let tresses: string;
    let first: string;

    it('prise de rendez-vous : client de passage ou fiche client, prestation du catalogue', async () => {
      tresses = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Tresses africaines', price: 15000, type: 'service', trackStock: false })
          .expect(201)
      ).body.id;
      const walkIn = await http
        .post('/v1/appointments')
        .set(A())
        .send({
          customerName: 'Fatou Sow',
          customerPhone: '77 555 66 77',
          serviceId: tresses,
          startsAt: at(23, 0),
          durationMinutes: 120,
          note: 'Mèches fournies',
        })
        .expect(201);
      first = walkIn.body.id;
      expect(walkIn.body).toMatchObject({
        customerName: 'Fatou Sow',
        customerPhone: '+221775556677',
        serviceName: 'Tresses africaines',
        price: 15000,
        status: 'booked',
      });

      // Par le vendeur (droit de vendre), avec une fiche client et une prestation libre
      const client = (
        await http.post('/v1/contacts').set(A()).send({ name: 'Mariama Ba', phone: '770001122' }).expect(201)
      ).body.id;
      const r = await http
        .post('/v1/appointments')
        .set(auth(modouToken, awaBiz))
        .send({ customerId: client, serviceName: 'Brushing', price: 3000, startsAt: at(23, 30), durationMinutes: 30 })
        .expect(201);
      expect(r.body).toMatchObject({ customerName: 'Mariama Ba', customerPhone: '+221770001122', serviceId: null });

      const list = (await http.get(`/v1/appointments?from=${today}&to=${today}`).set(A()).expect(200)).body;
      expect(list.items.map((a: { customerName: string; overlaps: boolean }) => [a.customerName, a.overlaps])).toEqual([
        ['Fatou Sow', true],
        ['Mariama Ba', true],
      ]);
      expect(list.bookedByDay[today]).toBe(2);
    });

    it('validation et droits', async () => {
      await http
        .post('/v1/appointments')
        .set(A())
        .send({ serviceName: 'Brushing', startsAt: at(10), durationMinutes: 30 })
        .expect(422);
      await http
        .post('/v1/appointments')
        .set(A())
        .send({ customerName: 'X', serviceName: 'Y', startsAt: at(10), durationMinutes: 2 })
        .expect(422);
      await http.get(`/v1/appointments?from=${today}&to=2030-01-01`).set(A()).expect(422);
      await http
        .get(`/v1/appointments?from=${today}&to=${today}`)
        .set(auth(moussa.accessToken, moussaBiz))
        .expect(200)
        .expect((res) => expect(res.body.items).toEqual([]));
    });

    it('déplacer, puis venu / absent / annulé ; notification des rendez-vous du jour', async () => {
      const moved = await http
        .patch(`/v1/appointments/${first}`)
        .set(A())
        .send({ startsAt: at(22, 0) })
        .expect(200);
      expect(moved.body.startsAt).toBe(at(22, 0));
      const notifs = (await http.get('/v1/notifications').set(A()).expect(200)).body.items as {
        kind: string;
        title: string;
        body: string;
      }[];
      expect(notifs).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            kind: 'appointments_today',
            title: '2 rendez-vous aujourd’hui',
            body: 'Premier à 22 h : Fatou Sow (Tresses africaines).',
          }),
        ]),
      );
      const done = await http.patch(`/v1/appointments/${first}`).set(A()).send({ status: 'done' }).expect(200);
      expect(done.body.status).toBe('done');
      await http.patch(`/v1/appointments/${first}`).set(A()).send({ status: 'perdu' }).expect(422);
    });
  });

  describe('Réservation en ligne', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let slug: string;
    let coupe: string;
    // Un jour ouvré dans une semaine (créneaux du matin, sans souci de préavis)
    const day = (() => {
      const d = new Date(Date.now() + 7 * 86_400_000);
      while (d.getUTCDay() === 0) d.setUTCDate(d.getUTCDate() + 1);
      return d.toISOString().slice(0, 10);
    })();
    const settings = {
      onlineEnabled: true,
      openDays: [1, 2, 3, 4, 5, 6],
      openTime: '09:00',
      closeTime: '11:00',
      slotMinutes: 30,
      capacity: 1,
      minNoticeMinutes: 60,
      maxDaysAhead: 30,
    };

    it('fermée par défaut ; le patron l’ouvre (horaires, créneaux) ; durée des prestations', async () => {
      slug = (await http.get('/v1/shop').set(A()).expect(200)).body.slug;
      const def = (await http.get('/v1/appointments/settings').set(A()).expect(200)).body;
      expect(def).toMatchObject({ onlineEnabled: false, openTime: '09:00', bookingPath: `/r/${slug}` });
      await http.get(`/v1/public/shops/${slug}/booking`).expect(404);

      await http.put('/v1/appointments/settings').set(auth(modouToken, awaBiz)).send(settings).expect(403);
      await http
        .put('/v1/appointments/settings')
        .set(A())
        .send({ ...settings, closeTime: '08:00' })
        .expect(422);
      const saved = (await http.put('/v1/appointments/settings').set(A()).send(settings).expect(200)).body;
      expect(saved).toMatchObject({ onlineEnabled: true, closeTime: '11:00', slotMinutes: 30 });

      coupe = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Coupe homme', price: 2000, type: 'service', trackStock: false, durationMinutes: 60 })
          .expect(201)
      ).body.id;
      const info = (await http.get(`/v1/public/shops/${slug}/booking`).expect(200)).body;
      expect(info.services).toEqual(
        expect.arrayContaining([{ id: coupe, name: 'Coupe homme', price: 2000, duration: 60 }]),
      );
      expect(info.days).toContain(day);
      expect((await http.get(`/v1/public/shops/${slug}`).expect(200)).body.shop.booking).toBe(true);
      const page = await http.get(`/r/${slug}`).expect(200);
      expect(page.headers['content-type']).toContain('text/html');
    });

    it('créneaux libres, réservation, créneau pris, renvoi idempotent, notification', async () => {
      const slots = async () =>
        (await http.get(`/v1/public/shops/${slug}/booking/slots?serviceId=${coupe}&day=${day}`).expect(200)).body.slots;
      expect(await slots()).toEqual(['09:00', '09:30', '10:00']);

      const body = {
        id: '01937b00-0000-7000-8000-0000000bb001',
        serviceId: coupe,
        day,
        time: '09:30',
        name: 'Ousmane Diop',
        phone: '77 444 55 66',
        note: 'Dégradé',
      };
      const r = await http.post(`/v1/public/shops/${slug}/booking`).send(body).expect(201);
      expect(r.body).toMatchObject({
        serviceName: 'Coupe homme',
        price: 2000,
        durationMinutes: 60,
        customerPhone: '+221774445566',
        source: 'online',
        status: 'booked',
        startsAt: `${day}T09:30:00.000Z`,
      });
      await http.post(`/v1/public/shops/${slug}/booking`).send(body).expect(200);

      // 9 h 30 – 10 h 30 pris : il ne reste aucun créneau d'1 h (capacité 1, fermeture à 11 h)
      expect(await slots()).toEqual([]);
      const taken = await http
        .post(`/v1/public/shops/${slug}/booking`)
        .send({ ...body, id: '01937b00-0000-7000-8000-0000000bb002', time: '09:00' })
        .expect(409);
      expect(taken.body.error.code).toBe('SLOT_TAKEN');
      await http
        .post(`/v1/public/shops/${slug}/booking`)
        .send({ ...body, id: '01937b00-0000-7000-8000-0000000bb003', time: '07:00' })
        .expect(409);
      await http
        .post(`/v1/public/shops/${slug}/booking`)
        .send({ ...body, id: '01937b00-0000-7000-8000-0000000bb004', phone: '12' })
        .expect(422);

      const agenda = (await http.get(`/v1/appointments?from=${day}&to=${day}`).set(A()).expect(200)).body.items;
      expect(agenda).toEqual([expect.objectContaining({ customerName: 'Ousmane Diop', source: 'online' })]);
      const notifs = (await http.get('/v1/notifications').set(A()).expect(200)).body.items as {
        kind: string;
        body: string;
      }[];
      expect(notifs.find((n) => n.kind === 'appointment_online')?.body).toContain('Ousmane Diop · Coupe homme ·');
    });
  });

  describe('Premiers pas', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    type Step = { key: string; done: boolean };

    it('étapes cochées d’après les données ; activité ; guide masqué sans rien écraser', async () => {
      const o = (await http.get('/v1/business/onboarding').set(A()).expect(200)).body;
      expect(o).toMatchObject({ focus: null, dismissed: false });
      const done = (steps: Step[]) => steps.filter((x) => x.done).map((x) => x.key);
      expect(done(o.steps)).toEqual(expect.arrayContaining(['add_products', 'first_sale', 'invite_member']));

      await http.patch('/v1/business').set(A()).send({ focus: 'coiffure' }).expect(422);
      await http.patch('/v1/business').set(auth(modouToken, awaBiz)).send({ focus: 'services' }).expect(403);
      await http.patch('/v1/business').set(A()).send({ focus: 'services' }).expect(200);
      const s = (await http.get('/v1/business/onboarding').set(A()).expect(200)).body;
      expect(s.focus).toBe('services');
      expect(s.steps.map((x: Step) => x.key)).toEqual([
        'add_services',
        'first_appointment',
        'first_sale',
        'logo_phone',
        'booking_online',
        'invite_member',
      ]);
      expect(done(s.steps)).toEqual(expect.arrayContaining(['add_services', 'first_appointment', 'booking_online']));

      await http.patch('/v1/business').set(A()).send({ onboardingDismissed: true }).expect(200);
      const d = (await http.get('/v1/business/onboarding').set(A()).expect(200)).body;
      expect(d).toMatchObject({ focus: 'services', dismissed: true });

      // Services selon le métier : choisis par le commerçant, sans toucher aux autres réglages
      await http
        .patch('/v1/business')
        .set(A())
        .send({ services: ['loyalty', 'bidon'] })
        .expect(422);
      await http
        .patch('/v1/business')
        .set(A())
        .send({ category: 'salon', services: ['booking', 'loyalty', 'booking'] })
        .expect(200);
      let b = (await http.get('/v1/business').set(A()).expect(200)).body.business;
      expect(b.category).toBe('salon');
      expect(b.settings).toMatchObject({
        focus: 'services',
        onboardingDismissed: true,
        services: ['booking', 'loyalty'],
      });
      // null : retour aux services du métier
      await http.patch('/v1/business').set(A()).send({ services: null }).expect(200);
      b = (await http.get('/v1/business').set(A()).expect(200)).body.business;
      expect(b.settings.services).toBeUndefined();
      expect(b.settings.focus).toBe('services');
    });

    it('activité choisie dès la création de l’entreprise', async () => {
      const biz = await http
        .post('/v1/businesses')
        .set(auth(moussa.accessToken))
        .send({ name: 'Moussa Couture', category: 'couture', focus: 'both' })
        .expect(201);
      const o = (
        await http.get('/v1/business/onboarding').set(auth(moussa.accessToken, biz.body.business.id)).expect(200)
      ).body;
      expect(o.focus).toBe('both');
      expect(o.steps).toHaveLength(7);
      expect(o.steps.every((x: Step) => !x.done || x.key === 'logo_phone')).toBe(true);
    });
  });

  describe("Pays : Côte d'Ivoire et Congo", () => {
    it('boutique ivoirienne : monnaie XOF, numéros à 10 chiffres, MTN MoMo', async () => {
      const kone = await login('+2250707123456');
      const res = await http
        .post('/v1/businesses')
        .set(auth(kone.accessToken))
        .send({ name: 'Koné Market', city: 'Abidjan', country: 'CI' })
        .expect(201);
      const biz = res.body.business.id;
      expect(res.body.business).toMatchObject({ country: 'CI', currency: 'XOF' });
      const K = () => auth(kone.accessToken, biz);

      const client = (
        await http.post('/v1/contacts').set(K()).send({ name: 'Adjoua', phone: '05 44 33 22 11' }).expect(201)
      ).body;
      expect(client.phone).toBe('+2250544332211');
      // Un numéro sénégalais sans indicatif n'est pas un numéro ivoirien
      await http.post('/v1/contacts').set(K()).send({ name: 'X', phone: '77 123 45 67' }).expect(422);
      await http.post('/v1/contacts').set(K()).send({ name: 'Moussa', phone: '+221 77 123 45 67' }).expect(201);

      const attieke = (
        await http
          .post('/v1/catalog/products')
          .set(K())
          .send({ name: 'Attiéké', price: 500, trackStock: false })
          .expect(201)
      ).body.id;
      const sale = await http
        .post('/v1/sales')
        .set(K())
        .send({
          id: '01938000-0000-7000-8000-0000000c1001',
          items: [{ productId: attieke, quantity: 4 }],
          payments: [{ method: 'mtn_momo', amount: 2000 }],
        })
        .expect(201);
      expect(sale.body.total).toBe(2000);
    });

    it('boutique congolaise : XAF, numéros +242, Airtel Money, page publique adaptée', async () => {
      const mav = await login('+242066123456');
      const res = await http
        .post('/v1/businesses')
        .set(auth(mav.accessToken))
        .send({ name: 'Chez Maman Mav', city: 'Brazzaville', country: 'CG' })
        .expect(201);
      const biz = res.body.business.id;
      expect(res.body.business).toMatchObject({ country: 'CG', currency: 'XAF' });
      const M = () => auth(mav.accessToken, biz);
      const c = (await http.post('/v1/couriers').set(M()).send({ name: 'Bienvenu', phone: '05 553 00 50' }).expect(201))
        .body;
      expect(c.phone).toBe('+242055530050');

      await http.put('/v1/shop/settings').set(M()).send({ enabled: true, whatsapp: '06 612 34 56' }).expect(200);
      const shop = (await http.get('/v1/shop').set(M()).expect(200)).body;
      const pub = (await http.get(`/v1/public/shops/${shop.slug}`).expect(200)).body.shop;
      expect(pub).toMatchObject({
        country: 'CG',
        phoneExample: '06 612 34 56',
        payHint: 'espèces, MTN MoMo, Airtel Money',
        whatsapp: '+242066123456',
      });
    });

    it('refuse un pays non pris en charge', async () => {
      await http
        .post('/v1/businesses')
        .set(auth(awa.accessToken))
        .send({ name: 'Ailleurs', country: 'FR' })
        .expect(422);
    });
  });

  describe('Sama360 Pro et parrainage', () => {
    it('essai, fonctions verrouillées après la fin, paiement validé, mois offert au parrain', async () => {
      const { sql } = await import('drizzle-orm');
      // Le parrain
      const fatou = await login('+221770010001');
      const fBiz = (
        await http.post('/v1/businesses').set(auth(fatou.accessToken)).send({ name: 'Fatou Mode' }).expect(201)
      ).body.business.id;
      const F = () => auth(fatou.accessToken, fBiz);
      const fSub = (await http.get('/v1/subscription').set(F()).expect(200)).body;
      expect(fSub).toMatchObject({ pro: true, state: 'trial', daysLeft: 30, currency: 'XOF' });
      expect(fSub.prices).toEqual({ weekly: 1500, monthly: 5000, yearly: 50000 });
      expect(fSub.payTo).toBe('Wave au 77 000 00 00 (Zolaa Tech)');
      expect(fSub.referralCode).toMatch(/^FAT[A-Z2-9]{3}$/);
      const fatouEnd = Date.parse(fSub.endsAt);

      // Le filleul s'inscrit avec le code (en minuscules)
      const ibou = await login('+221770010002');
      const iBiz = (
        await http
          .post('/v1/businesses')
          .set(auth(ibou.accessToken))
          .send({ name: 'Ibou Quincaillerie', referralCode: fSub.referralCode.toLowerCase() })
          .expect(201)
      ).body.business.id;
      const I = () => auth(ibou.accessToken, iBiz);
      await http.put('/v1/shop/settings').set(I()).send({ enabled: true }).expect(200);
      const slug = (await http.get('/v1/shop').set(I()).expect(200)).body.slug;
      await http.get(`/v1/public/shops/${slug}`).expect(200);

      let refs = (await http.get('/v1/referrals').set(F()).expect(200)).body;
      expect(refs.referrals).toEqual([expect.objectContaining({ name: 'Ibou Quincaillerie', rewarded: false })]);

      // Fin de l'essai : les fonctions Pro sont verrouillées, le reste marche
      await dbs.db.execute(
        sql`UPDATE core.subscriptions SET current_period_end = now() - interval '1 day' WHERE business_id = ${iBiz}`,
      );
      const locked = await http.post('/v1/couriers').set(I()).send({ name: 'Modou' }).expect(402);
      expect(locked.body.error).toMatchObject({ code: 'PRO_REQUIRED', details: { feature: 'delivery' } });
      await http.post('/v1/members').set(I()).send({ phone: '+221770010003', roleKey: 'cashier' }).expect(402);
      await http.get('/v1/reports/insights').set(I()).expect(402);
      await http.get(`/v1/public/shops/${slug}`).expect(404); // boutique en ligne fermée
      await http.get('/v1/catalog/products').set(I()).expect(200);
      expect((await http.get('/v1/subscription').set(I()).expect(200)).body).toMatchObject({
        pro: false,
        state: 'expired',
      });

      // Gratuit : 50 produits (les variantes ne comptent pas), rapports et ventes des 30 derniers jours
      await dbs.withTenant(iBiz, (tx) =>
        tx.execute(sql`
          INSERT INTO catalog.products (id, business_id, name, price)
          SELECT gen_random_uuid(), ${iBiz}, 'Article ' || i, 1000 FROM generate_series(1, 50) i`),
      );
      const full = await http
        .post('/v1/catalog/products')
        .set(I())
        .send({ name: 'Un de trop', price: 500 })
        .expect(402);
      expect(full.body.error).toMatchObject({ code: 'PRO_REQUIRED', details: { feature: 'catalog', limit: 50 } });
      const today = new Date().toISOString().slice(0, 10);
      const old = new Date(Date.now() - 45 * 86_400_000).toISOString().slice(0, 10);
      const recent = new Date(Date.now() - 29 * 86_400_000).toISOString().slice(0, 10);
      await http.get(`/v1/reports/overview?from=${recent}&to=${today}`).set(I()).expect(200);
      const hist = await http.get(`/v1/reports/overview?from=${old}&to=${today}`).set(I()).expect(402);
      expect(hist.body.error).toMatchObject({ code: 'PRO_REQUIRED', details: { feature: 'history', days: 30 } });
      const offer = (await http.get('/v1/subscription').set(I()).expect(200)).body;
      expect(offer.prices).toEqual({ weekly: 1500, monthly: 5000, yearly: 50000 });
      expect(offer.freeLimits).toEqual({ products: 50, historyDays: 30 });
      expect(offer.features.map((f: { key: string }) => f.key)).toEqual(expect.arrayContaining(['catalog', 'history']));

      // Rappel de fin d'essai à J-3, avec ce que CE commerçant va perdre
      await dbs.withTenant(iBiz, (tx) =>
        tx.execute(sql`
          INSERT INTO catalog.products (id, business_id, name, price)
          SELECT gen_random_uuid(), ${iBiz}, 'En plus ' || i, 1000 FROM generate_series(1, 2) i`),
      );
      await dbs.db.execute(
        sql`UPDATE core.subscriptions SET current_period_end = now() + interval '2 days 12 hours' WHERE business_id = ${iBiz}`,
      );
      const reminders = (await http.get('/v1/notifications').set(I()).expect(200)).body.items as {
        kind: string;
        title: string;
        body: string;
      }[];
      const ending = reminders.find((n) => n.kind === 'pro_ending');
      expect(ending?.title).toMatch(/se termine dans 3 jours/);
      expect(ending?.body).toContain('vous en avez 52, 50 en gratuit');
      expect(ending?.body).toContain('1 500 F la semaine');
      await dbs.db.execute(
        sql`UPDATE core.subscriptions SET current_period_end = now() - interval '1 day' WHERE business_id = ${iBiz}`,
      );

      // « J'ai payé »
      const req = (
        await http
          .post('/v1/subscription/requests')
          .set(I())
          .send({ cycle: 'monthly', method: 'wave', reference: 'TX-AB12CD', payerPhone: '77 001 00 02' })
          .expect(201)
      ).body;
      expect(req).toMatchObject({ status: 'pending', amount: 5000, currency: 'XOF', payerPhone: '+221770010002' });
      await http
        .post('/v1/subscription/requests')
        .set(I())
        .send({ cycle: 'monthly', method: 'wave', reference: 'TX-AUTRE' })
        .expect(409);

      // L'équipe Sama360 valide
      await http.get('/v1/admin/subscription-requests').set(auth(ibou.accessToken)).expect(403);
      const admin = await login('+221700000099');
      adminToken = admin.accessToken;
      expect((await http.get('/v1/admin/me').set(auth(admin.accessToken)).expect(200)).body).toEqual({ admin: true });
      const list = (await http.get('/v1/admin/subscription-requests').set(auth(admin.accessToken)).expect(200)).body;
      expect(list).toEqual([
        expect.objectContaining({ id: req.id, business: expect.objectContaining({ name: 'Ibou Quincaillerie' }) }),
      ]);
      const ok = (
        await http.post(`/v1/admin/subscription-requests/${req.id}/approve`).set(auth(admin.accessToken)).expect(201)
      ).body;
      expect(ok.sponsorRewarded).toBe(true);
      // 30 jours payés + 30 jours offerts (premier paiement d'un filleul)
      const days = (Date.parse(ok.endsAt) - Date.now()) / 86_400_000;
      expect(days).toBeGreaterThan(59);
      expect(days).toBeLessThan(61);
      await http.post(`/v1/admin/subscription-requests/${req.id}/approve`).set(auth(admin.accessToken)).expect(409);

      await http.post('/v1/couriers').set(I()).send({ name: 'Modou' }).expect(201);
      await http.get(`/v1/public/shops/${slug}`).expect(200);
      const iSub = (await http.get('/v1/subscription').set(I()).expect(200)).body;
      expect(iSub).toMatchObject({ pro: true, state: 'active', pending: null });
      expect(iSub.history[0]).toMatchObject({ status: 'approved' });

      // Le parrain gagne un mois, une seule fois
      const fAfter = (await http.get('/v1/subscription').set(F()).expect(200)).body;
      expect(Math.round((Date.parse(fAfter.endsAt) - fatouEnd) / 86_400_000)).toBe(30);
      refs = (await http.get('/v1/referrals').set(F()).expect(200)).body;
      expect(refs).toMatchObject({ daysEarned: 30, referrals: [expect.objectContaining({ rewarded: true })] });
      const notes = (await http.get('/v1/notifications').set(F()).expect(200)).body;
      expect(JSON.stringify(notes)).toContain('Parrainage : un mois Pro offert');

      // Un 2e paiement : pas de nouveau mois offert ; un paiement refusé est signalé
      const r2 = (
        await http
          .post('/v1/subscription/requests')
          .set(I())
          .send({ cycle: 'yearly', method: 'orange_money', reference: 'OM-998877' })
          .expect(201)
      ).body;
      expect(r2.amount).toBe(50000);
      await http
        .post(`/v1/admin/subscription-requests/${r2.id}/reject`)
        .set(auth(admin.accessToken))
        .send({ note: 'Référence introuvable sur notre compte Orange Money' })
        .expect(201);
      expect((await http.get('/v1/subscription').set(I()).expect(200)).body.history[0]).toMatchObject({
        status: 'rejected',
        note: 'Référence introuvable sur notre compte Orange Money',
      });
      // Un code de parrainage inconnu est simplement ignoré
      const x = await login('+221770010004');
      await http
        .post('/v1/businesses')
        .set(auth(x.accessToken))
        .send({ name: 'Sans parrain', referralCode: 'ZZZZZZ' })
        .expect(201);
    });

    it('Pro payé en ligne (Chariow) : page de paiement, Pulse signé, Pro prolongé une seule fois', async () => {
      const { createHmac } = await import('node:crypto');
      const { sql } = await import('drizzle-orm');
      const awa = await login('+221770020001');
      const biz = (
        await http.post('/v1/businesses').set(auth(awa.accessToken)).send({ name: 'Awa Couture' }).expect(201)
      ).body.business.id;
      const A = () => auth(awa.accessToken, biz);
      const before = (await http.get('/v1/subscription').set(A()).expect(200)).body;
      expect(before.online).toBe(true);

      // Chariow simulé
      const calls: { url: string; body: any; auth: string }[] = [];
      const realFetch = global.fetch;
      const spy = jest.spyOn(global, 'fetch').mockImplementation(async (url: any, init?: any) => {
        if (!String(url).startsWith('https://chariow.test/')) return realFetch(url, init);
        calls.push({ url: String(url), body: JSON.parse(init.body), auth: init.headers.Authorization });
        return new Response(
          JSON.stringify({
            message: 'success',
            data: {
              step: 'payment',
              purchase: { id: 'sal_awa1' },
              payment: { checkout_url: 'https://pay.chariow.test/c/abc', transaction_id: 'tx1', gateway: 'x' },
            },
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        );
      });
      try {
        await http
          .post('/v1/subscription/checkout')
          .set(A())
          .send({ cycle: 'yearly', email: 'pas-un-email' })
          .expect(422);
        const co = (
          await http
            .post('/v1/subscription/checkout')
            .set(A())
            .send({ cycle: 'yearly', email: 'Awa@Exemple.sn' })
            .expect(201)
        ).body;
        expect(co.checkoutUrl).toBe('https://pay.chariow.test/c/abc');
        expect(calls).toHaveLength(1);
        expect(calls[0].url).toBe('https://chariow.test/v1/checkout');
        expect(calls[0].auth).toBe('Bearer sk_test_sama');
        expect(calls[0].body).toMatchObject({
          product_id: 'prd_annee',
          email: 'awa@exemple.sn',
          phone: { number: '770020001', country_code: 'SN' },
          custom_metadata: { payment_id: co.paymentId, business_id: biz, cycle: 'yearly' },
        });
        expect(calls[0].body.redirect_url).toMatch(new RegExp(`/app/#/pro\\?paid=${co.paymentId}$`));
        expect((await http.get(`/v1/subscription/online/${co.paymentId}`).set(A()).expect(200)).body).toMatchObject({
          status: 'pending',
        });

        // Pulse : signature obligatoire
        const pulse = (event: string, metadata: object, productId = 'prd_annee') =>
          JSON.stringify({
            event,
            sale: {
              id: 'sal_awa1',
              status: 'completed',
              custom_metadata: metadata,
              payment: { amount: { value: 50000, currency: 'XOF' } },
            },
            product: { id: productId },
            customer: { email: 'awa@exemple.sn' },
          });
        const send = (body: string, sig: string, delivery: string) =>
          http
            .post('/v1/webhooks/chariow')
            .set('Content-Type', 'application/json')
            .set('x-chariow-signature', sig)
            .set('x-pulse-delivery-id', delivery)
            .send(body);
        const sign = (body: string) => 'sha256=' + createHmac('sha256', 'whsec_test_sama').update(body).digest('hex');
        const good = pulse('successful.sale', { payment_id: co.paymentId, business_id: biz, cycle: 'yearly' });
        await send(good, 'sha256=' + '0'.repeat(64), 'd-bad').expect(401);
        // Autre produit : refusé sans créditer
        const wrong = pulse('successful.sale', { payment_id: co.paymentId }, 'prd_mois');
        expect((await send(wrong, sign(wrong), 'd-0').expect(200)).body).toMatchObject({ credited: false });
        // Vente abandonnée, vente étrangère à Sama360 : ignorées
        const ab = pulse('abandoned.sale', { payment_id: co.paymentId });
        await send(ab, sign(ab), 'd-1').expect(200);
        const other = pulse('successful.sale', { book: 'x' });
        expect((await send(other, sign(other), 'd-2').expect(200)).body).toMatchObject({ ignored: 'not_sama360' });

        const ok = (await send(good, sign(good), 'd-3').expect(200)).body;
        expect(ok).toMatchObject({ credited: true });
        const after = (await http.get('/v1/subscription').set(A()).expect(200)).body;
        expect(after).toMatchObject({ pro: true, state: 'active' });
        expect(Math.round((Date.parse(after.endsAt) - Date.parse(before.endsAt)) / 86_400_000)).toBe(365);
        expect((await http.get(`/v1/subscription/online/${co.paymentId}`).set(A()).expect(200)).body).toMatchObject({
          status: 'paid',
        });
        // Rejoué (même livraison, puis nouvelle livraison du même paiement) : pas de second crédit
        expect((await send(good, sign(good), 'd-3').expect(200)).body).toMatchObject({ duplicate: true });
        expect((await send(good, sign(good), 'd-4').expect(200)).body).toMatchObject({ credited: false });
        const again = (await http.get('/v1/subscription').set(A()).expect(200)).body;
        expect(again.endsAt).toBe(after.endsAt);
        const row = (
          await dbs.db.execute(
            sql`SELECT amount, currency, sale_id FROM core.online_payments WHERE id = ${co.paymentId}`,
          )
        ).rows[0];
        expect(row).toMatchObject({ amount: 50000, currency: 'XOF', sale_id: 'sal_awa1' });
        // L'e-mail est gardé pour la prochaine fois
        const u = (await dbs.db.execute(sql`SELECT email FROM core.users WHERE phone = '+221770020001'`)).rows[0];
        expect(u).toMatchObject({ email: 'awa@exemple.sn' });
        // Sans entreprise choisie : refusé
        await http
          .get(`/v1/subscription/online/${co.paymentId}`)
          .set(auth(awa.accessToken))
          .expect((r) => {
            if (r.status < 400) throw new Error('sans entreprise : refusé');
          });
      } finally {
        spy.mockRestore();
      }
    });
  });

  describe('Livraison', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    let slug: string;
    let order: string;
    let moto: string;
    let delivery: string;

    it('livreurs : ajout, numéro normalisé, désactivation', async () => {
      moto = (
        await http
          .post('/v1/couriers')
          .set(A())
          .send({ name: 'Ibou Faye', phone: '78 111 22 33', vehicle: 'moto' })
          .expect(201)
      ).body.id;
      const other = (await http.post('/v1/couriers').set(A()).send({ name: 'Lamine' }).expect(201)).body.id;
      await http.patch(`/v1/couriers/${other}`).set(A()).send({ active: false }).expect(200);
      const list = (await http.get('/v1/couriers').set(A()).expect(200)).body;
      expect(list[0]).toMatchObject({ name: 'Ibou Faye', phone: '+221781112233', vehicle: 'moto', active: true });
      await http.post('/v1/couriers').set(A()).send({ name: 'X', phone: '12' }).expect(422);
    });

    it('commande en ligne à livrer → assignée → en route → livrée (vente enregistrée) → argent reçu', async () => {
      slug = (await http.get('/v1/shop').set(A()).expect(200)).body.slug;
      const thiouraye = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Thiouraye parfumé', price: 12000, trackStock: false, published: true })
          .expect(201)
      ).body.id;
      order = '01938000-0000-7000-8000-00000000de01';
      await http
        .post(`/v1/public/shops/${slug}/orders`)
        .send({
          id: order,
          customerName: 'Rokhaya Mbaye',
          customerPhone: '77 222 33 44',
          mode: 'delivery',
          address: 'Sacré-Cœur 3, villa 12',
          items: [{ productId: thiouraye, quantity: 1 }],
        })
        .expect(201);
      // Pas encore confirmée : pas à livrer
      let board = (await http.get('/v1/deliveries').set(A()).expect(200)).body;
      expect(board.toAssign.find((o: { orderId: string }) => o.orderId === order)).toBeUndefined();
      await http.post(`/v1/shop/orders/${order}/status`).set(A()).send({ status: 'confirmed' }).expect(200);
      board = (await http.get('/v1/deliveries').set(A()).expect(200)).body;
      expect(board.toAssign).toEqual(
        expect.arrayContaining([expect.objectContaining({ orderId: order, total: 13000, deliveryFee: 1000 })]),
      );

      const d = await http.post('/v1/deliveries').set(A()).send({ orderId: order, courierId: moto }).expect(201);
      delivery = d.body.id;
      expect(d.body).toMatchObject({
        status: 'assigned',
        customerName: 'Rokhaya Mbaye',
        address: 'Sacré-Cœur 3, villa 12',
        amountToCollect: 13000,
        fee: 1000,
        courierName: 'Ibou Faye',
      });
      await http.post('/v1/deliveries').set(A()).send({ orderId: order }).expect(409);

      await http.patch(`/v1/deliveries/${delivery}`).set(A()).send({ status: 'picked' }).expect(200);
      expect((await http.get(`/v1/shop/orders/${order}`).set(A()).expect(200)).body.status).toBe('delivering');
      await http.patch(`/v1/deliveries/${delivery}`).set(A()).send({ status: 'assigned' }).expect(409);

      const done = await http.patch(`/v1/deliveries/${delivery}`).set(A()).send({ status: 'delivered' }).expect(200);
      expect(done.body).toMatchObject({ status: 'delivered', settled: false });
      const o = (await http.get(`/v1/shop/orders/${order}`).set(A()).expect(200)).body;
      expect(o.status).toBe('completed');
      expect(o.saleId).toBeTruthy();

      board = (await http.get('/v1/deliveries').set(A()).expect(200)).body;
      expect(board.withCouriers).toEqual([
        { courierId: moto, name: 'Ibou Faye', phone: '+221781112233', owed: 13000, deliveries: 1 },
      ]);
      const settled = await http.post(`/v1/couriers/${moto}/settle`).set(A()).expect(201);
      expect(settled.body).toEqual({ deliveries: 1, amount: 13000 });
      expect((await http.get('/v1/deliveries').set(A()).expect(200)).body.withCouriers).toEqual([]);
      const history = (await http.get('/v1/deliveries?view=done').set(A()).expect(200)).body.items;
      expect(history[0]).toMatchObject({ id: delivery, settled: true, orderNumber: expect.any(String) });
    });

    it('livraison notée à la main ; échec puis nouvel essai ; vendeur autorisé', async () => {
      await http.post('/v1/deliveries').set(A()).send({ customerName: 'Pape', address: '' }).expect(422);
      const m = await http
        .post('/v1/deliveries')
        .set(auth(modouToken, awaBiz))
        .send({
          customerName: 'Pape Ndiaye',
          customerPhone: '70 123 45 67',
          address: 'Grand Yoff',
          amountToCollect: 5000,
        })
        .expect(201);
      expect(m.body.status).toBe('pending');
      await http.patch(`/v1/deliveries/${m.body.id}`).set(A()).send({ status: 'picked' }).expect(409);
      await http.patch(`/v1/deliveries/${m.body.id}`).set(A()).send({ courierId: moto }).expect(200);
      const failed = await http
        .patch(`/v1/deliveries/${m.body.id}`)
        .set(A())
        .send({ status: 'failed', failureReason: 'Client absent' })
        .expect(200);
      expect(failed.body).toMatchObject({ status: 'failed', failureReason: 'Client absent' });
      const retry = await http.patch(`/v1/deliveries/${m.body.id}`).set(A()).send({ courierId: moto }).expect(200);
      expect(retry.body).toMatchObject({ status: 'assigned', failureReason: null });
      await http
        .get('/v1/deliveries')
        .set(auth(moussa.accessToken, moussaBiz))
        .expect(200)
        .expect((r) => expect(r.body.items).toEqual([]));
    });
  });

  describe('Facture fournisseur en photo', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const photo = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(400, 7)]);
    let supplier: string;
    let riz: string;
    const scan = () =>
      http
        .post('/v1/purchases/scan')
        .set(A())
        .attach('file', photo, { filename: 'facture.jpg', contentType: 'image/jpeg' });
    const onHand = async (productId: string) =>
      Number(
        (
          (await http.get('/v1/inventory/stock').set(A()).expect(200)).body.items as {
            productId: string;
            onHand: number;
          }[]
        ).find((i) => i.productId === productId)?.onHand ?? 0,
      );

    beforeAll(async () => {
      supplier = (
        await http.post('/v1/contacts').set(A()).send({ type: 'supplier', name: 'Sénégal Distribution' }).expect(201)
      ).body.id;
      riz = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Riz brisé parfumé 25 kg', price: 14500, cost: 12000 })
          .expect(201)
      ).body.id;
    });

    it('lit la facture et propose fournisseur, produits et prix', async () => {
      const res = await scan().expect(200);
      expect(res.body).toMatchObject({
        readable: true,
        supplier: { id: supplier, name: 'Sénégal Distribution' },
        number: 'FA-2026-1187',
        date: '2026-11-17',
        total: 182000,
        linesTotal: 182000,
      });
      expect(res.body.lines).toHaveLength(3);
      expect(res.body.lines[0]).toMatchObject({
        label: 'RIZ BRISE PARFUME 25KG',
        quantity: 10,
        unitCost: 12500,
        productId: riz,
        confidence: 'high',
      });
      // « Huile 1 L » existe, mais pas en 5 L : pas de rapprochement hasardeux
      expect(res.body.lines[1].productId).toBeNull();
    });

    it('l’achat créé depuis la facture fait entrer le stock et retient les libellés', async () => {
      const huile5 = (
        await http.post('/v1/catalog/products').set(A()).send({ name: 'Huile Dinor 5 L', price: 7500 }).expect(201)
      ).body.id;
      const before = await onHand(riz);
      const order = await http
        .post('/v1/purchases')
        .set(A())
        .send({
          supplierId: supplier,
          receive: true,
          orderDate: '2026-11-17',
          note: 'Facture FA-2026-1187',
          lines: [
            { productId: riz, quantity: 10, unitCost: 12500, scanLabel: 'RIZ BRISE PARFUME 25KG' },
            { productId: huile5, quantity: 6, unitCost: 6500, scanLabel: 'Huile Dinor 5L' },
          ],
        })
        .expect(201);
      expect(order.body).toMatchObject({ status: 'received', total: 164000 });
      expect(await onHand(riz)).toBe(before + 10);

      const again = await scan().expect(200);
      expect(again.body.lines[1]).toMatchObject({ productId: huile5, confidence: 'memory' });
    });

    it('réservé à qui peut modifier le stock ; une photo est exigée', async () => {
      await http
        .post('/v1/purchases/scan')
        .set(A())
        .attach('file', Buffer.from('%PDF-1.7 pas une photo'), { filename: 'x.pdf', contentType: 'application/pdf' })
        .expect(422);
    });
  });

  describe('Points de vente', () => {
    const A = () => auth(awa.accessToken, awaBiz);
    const At = (loc: string) => ({ ...A(), 'X-Location-Id': loc });
    let main: string;
    let medina: string;
    let product: string;
    const onHand = async (headers: Record<string, string>) =>
      (
        (await http.get('/v1/inventory/stock').set(headers).expect(200)).body.items as {
          productId: string;
          onHand: number;
          byLocation: Record<string, number>;
        }[]
      ).find((i) => i.productId === product)!;
    // La sortie de stock d'une vente passe par les événements : on attend qu'elle soit appliquée
    const stockAt = async (loc: string, expected: number) => {
      await relay.relayOnce();
      return waitFor(
        async () => (await onHand(At(loc))).onHand,
        (v) => v === expected,
      );
    };

    beforeAll(async () => {
      product = (
        await http
          .post('/v1/catalog/products')
          .set(A())
          .send({ name: 'Thé Ataya vert', price: 1000, cost: 600 })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: product, type: 'purchase', quantity: 10, unitCost: 600 })
        .expect(201);
    });

    it('un point de vente principal existe ; on en ouvre un deuxième', async () => {
      const list = await http.get('/v1/locations').set(A()).expect(200);
      expect(list.body.current).toMatchObject({ id: null, locked: false });
      main = list.body.data.find((l: { isDefault: boolean }) => l.isDefault).id;
      expect(list.body.current.writeTo).toBe(main);

      const created = await http
        .post('/v1/locations')
        .set(A())
        .send({ name: 'Boutique Médina', address: 'Rue 11 x 6, Médina' })
        .expect(201);
      medina = created.body.id;
      expect(created.body).toMatchObject({ name: 'Boutique Médina', isDefault: false });
      await http.post('/v1/locations').set(A()).send({ name: 'boutique médina' }).expect(409);
    });

    it('transfert de marchandise : sortie d’un côté, entrée de l’autre, sans dépasser le stock', async () => {
      const tr = await http
        .post('/v1/inventory/transfers')
        .set(A())
        .send({ fromId: main, toId: medina, lines: [{ productId: product, quantity: 4 }] })
        .expect(201);
      expect(tr.body).toMatchObject({ from: { id: main }, to: { name: 'Boutique Médina' } });
      expect(tr.body.number).toMatch(/^TR-\d{4}-0001$/);

      expect((await onHand(At(medina))).onHand).toBe(4);
      expect((await onHand(At(main))).onHand).toBe(6);
      const all = await onHand(A());
      expect(all.onHand).toBe(10);
      expect(all.byLocation).toEqual({ [main]: 6, [medina]: 4 });

      const tooMuch = await http
        .post('/v1/inventory/transfers')
        .set(A())
        .send({ fromId: medina, toId: main, lines: [{ productId: product, quantity: 5 }] })
        .expect(422);
      expect(tooMuch.body.error.code).toBe('INSUFFICIENT_STOCK');
    });

    it('une vente au point de vente choisi sort de son stock et compte dans ses chiffres', async () => {
      const sale = await http
        .post('/v1/sales')
        .set(At(medina))
        .send({ items: [{ productId: product, quantity: 1 }], payments: [{ method: 'cash', amount: 1000 }] })
        .expect(201);
      expect(await stockAt(medina, 3)).toBe(3);
      expect((await onHand(At(main))).onHand).toBe(6);

      const list = await http.get('/v1/sales').set(At(medina)).expect(200);
      expect(list.body.data.map((s: { id: string }) => s.id)).toEqual([sale.body.id]);

      const mine = await http.get('/v1/sales/summary').set(At(medina)).expect(200);
      expect(mine.body).toMatchObject({ salesCount: 1, revenue: 1000, locationId: medina });
      const everything = await http.get('/v1/sales/summary').set(A()).expect(200);
      expect(everything.body.locationId).toBeNull();
      expect(everything.body.salesCount).toBeGreaterThan(1);
      expect(everything.body.byLocation).toEqual(
        expect.arrayContaining([expect.objectContaining({ locationId: medina, salesCount: 1, revenue: 1000 })]),
      );
    });

    it('un vendeur rattaché vend toujours dans son point de vente', async () => {
      await http
        .post('/v1/members')
        .set(A())
        .send({ phone: '+221770009191', fullName: 'Fatou Médina', roleKey: 'cashier', locationId: medina })
        .expect(201);
      const fatou = (await login('+221770009191')).accessToken;
      const me = await http.get('/v1/business').set(auth(fatou, awaBiz)).expect(200);
      expect(me.body.me.location).toEqual({ id: medina, writeTo: medina, locked: true });

      // Même s'il demande le principal, sa vente reste à la Médina
      await http
        .post('/v1/sales')
        .set({ ...auth(fatou, awaBiz), 'X-Location-Id': main })
        .send({ items: [{ productId: product, quantity: 1 }], payments: [{ method: 'cash', amount: 1000 }] })
        .expect(201);
      expect(await stockAt(medina, 2)).toBe(2);

      const members = await http.get('/v1/members').set(A()).expect(200);
      expect(members.body.find((m: { fullName: string }) => m.fullName === 'Fatou Médina').locationId).toBe(medina);
    });

    it('dépenses et crédits clients comptés dans leur point de vente', async () => {
      const sum = async (h: Record<string, string>) => (await http.get('/v1/sales/summary').set(h).expect(200)).body;
      const [m0, d0, all0] = [await sum(At(main)), await sum(At(medina)), await sum(A())];
      const client = (await http.post('/v1/contacts').set(A()).send({ name: 'Coumba Médina' }).expect(201)).body.id;

      // Vente à crédit à la Médina, puis remboursement d'une partie au principal
      await http
        .post('/v1/sales')
        .set(At(medina))
        .send({ items: [{ productId: product, quantity: 2 }], payments: [], customerId: client })
        .expect(201);
      await http
        .post(`/v1/sales/customers/${client}/repayments`)
        .set(At(main))
        .send({ amount: 500, method: 'cash' })
        .expect(201);
      // Dépense de la Médina
      await http.post('/v1/sales/expenses').set(At(medina)).send({ category: 'transport', amount: 700 }).expect(201);

      const [m1, d1, all1] = [await sum(At(main)), await sum(At(medina)), await sum(A())];
      expect(d1.receivables - d0.receivables).toBe(1500); // 2 000 F dus, 500 F déjà rendus
      expect(m1.receivables).toBe(m0.receivables);
      expect(all1.receivables - all0.receivables).toBe(1500);
      expect(d1.expenses - d0.expenses).toBe(700);
      expect(m1.expenses).toBe(m0.expenses);
      expect(all1.expenses - all0.expenses).toBe(700);

      const debtorsHere = (await http.get('/v1/sales/debtors').set(At(medina)).expect(200)).body;
      expect(debtorsHere).toEqual(
        expect.arrayContaining([expect.objectContaining({ customerId: client, balance: 1500 })]),
      );
      const debtorsMain = (await http.get('/v1/sales/debtors').set(At(main)).expect(200)).body;
      expect(debtorsMain.map((x: { customerId: string }) => x.customerId)).not.toContain(client);
      const exp = (await http.get('/v1/sales/expenses').set(At(main)).expect(200)).body;
      expect(exp.some((e: { amount: number; category: string }) => e.amount === 700)).toBe(false);
      // Solde réglé : plus rien à encaisser nulle part
      await http
        .post(`/v1/sales/customers/${client}/repayments`)
        .set(At(medina))
        .send({ amount: 1500, method: 'wave' })
        .expect(201);
      expect((await sum(At(medina))).receivables).toBe(d0.receivables);
    });

    it('fermer un point de vente : pas le principal, et pas avec du stock dedans', async () => {
      await http.post(`/v1/locations/${main}/archive`).set(A()).expect(422);
      const full = await http.post(`/v1/locations/${medina}/archive`).set(A()).expect(409);
      expect(full.body.error.code).toBe('LOCATION_NOT_EMPTY');

      await http
        .post('/v1/inventory/transfers')
        .set(A())
        .send({ fromId: medina, toId: main, lines: [{ productId: product, quantity: 2 }] })
        .expect(201);
      await http.post(`/v1/locations/${medina}/archive`).set(A()).expect(200);

      const list = await http.get('/v1/locations').set(A()).expect(200);
      expect(list.body.data.map((l: { id: string }) => l.id)).not.toContain(medina);
      const members = await http.get('/v1/members').set(A()).expect(200);
      expect(members.body.find((m: { fullName: string }) => m.fullName === 'Fatou Médina').locationId).toBeNull();
      // Une ancienne sélection sur le téléphone retombe sur « tous les points de vente »
      expect((await http.get('/v1/sales/summary').set(At(medina)).expect(200)).body.locationId).toBeNull();
    });
  });

  describe('Notifications push', () => {
    it('appareils abonnés, bons destinataires, jetons périmés oubliés, configuration web', async () => {
      const push = app.get(PushService);
      const notifs = app.get(NotificationsService);
      const sent: { token: string; title: string; link?: string | null; webBase?: string | null }[] = [];
      push.useSender({
        send: async (token, msg) => {
          if (token.startsWith('perime')) return 'unregistered';
          sent.push({ token, ...msg });
          return 'sent';
        },
      });
      try {
        // Configuration publique de la version web et service worker à la racine
        expect((await http.get('/v1/push/config').expect(200)).body).toEqual({
          enabled: true,
          web: {
            apiKey: 'AIzaTest',
            appId: '1:4242:web:abc',
            projectId: 'sama-test',
            messagingSenderId: '4242',
            vapidKey: 'BTestVapid',
          },
        });
        const sw = await http.get('/firebase-messaging-sw.js').expect(200);
        expect(sw.headers['content-type']).toContain('javascript');
        expect(sw.text).toContain('"projectId":"sama-test"');

        const owner = await login('+221770040001');
        const biz = (
          await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Push Boutique' }).expect(201)
        ).body.business.id;
        const cashier = await login('+221770040002');
        await http
          .post('/v1/members')
          .set(auth(owner.accessToken, biz))
          .send({ phone: '+221770040002', roleKey: 'cashier' })
          .expect(201);
        const tok = (p: string) => `${p}-${'x'.repeat(30)}`;
        await http
          .post('/v1/me/push-tokens')
          .set(auth(owner.accessToken))
          .send({ token: tok('tel-patron'), platform: 'android' })
          .expect(200);
        await http
          .post('/v1/me/push-tokens')
          .set(auth(owner.accessToken))
          .send({ token: tok('perime'), platform: 'web' })
          .expect(200);
        await http
          .post('/v1/me/push-tokens')
          .set(auth(cashier.accessToken))
          .send({ token: tok('tel-caissier'), platform: 'android' })
          .expect(200);
        await http
          .post('/v1/me/push-tokens')
          .set(auth(owner.accessToken))
          .send({ token: 'court', platform: 'android' })
          .expect(422);
        await http
          .post('/v1/me/push-tokens')
          .send({ token: tok('anonyme'), platform: 'android' })
          .expect(401);

        // Commande en ligne (vente) : patron et caissier ; astuce « logo » : jamais sur le téléphone
        await dbs.withTenant(biz, async (tx) => {
          await notifs.push(tx, biz, {
            kind: 'shop_order',
            title: 'Nouvelle commande',
            link: '/shop/orders/1',
            audience: 'sales:read',
          });
          await notifs.push(tx, biz, { kind: 'logo', title: 'Ajoutez votre logo', audience: 'business:update' });
          // Pro : patron seulement ; action du patron lui-même : pas pour lui
          await notifs.push(tx, biz, { kind: 'pro_active', title: 'Pro activé', audience: 'business:update' });
          await notifs.push(tx, biz, {
            kind: 'sale_voided',
            title: 'Vente annulée',
            audience: 'sales:read',
            actorId: owner.user.id,
          });
        });
        expect(await push.dispatch()).toBe(4);
        const got = (t: string) => sent.filter((x) => x.token === tok(t)).map((x) => x.title);
        expect(got('tel-patron').sort()).toEqual(['Nouvelle commande', 'Pro activé']);
        expect(got('tel-caissier').sort()).toEqual(['Nouvelle commande', 'Vente annulée']);
        expect(sent.find((x) => x.title === 'Nouvelle commande')).toMatchObject({
          link: '/shop/orders/1',
          webBase: 'https://sama.test',
        });
        // Jeton périmé effacé ; file vide
        const { sql } = await import('drizzle-orm');
        expect(
          (await dbs.db.execute(sql`SELECT 1 FROM core.push_tokens WHERE token = ${tok('perime')}`)).rows,
        ).toHaveLength(0);
        expect(await push.dispatch()).toBe(0);

        // Désabonner ce téléphone (déconnexion)
        await http
          .delete('/v1/me/push-tokens')
          .set(auth(cashier.accessToken))
          .send({ token: tok('tel-caissier') })
          .expect(200);
        await dbs.withTenant(biz, (tx) =>
          notifs.push(tx, biz, { kind: 'stock_low', title: 'Stock bas', audience: 'inventory:read' }),
        );
        sent.length = 0;
        await push.dispatch();
        expect(sent.map((x) => x.token)).toEqual([tok('tel-patron')]);

        // Rappels du jour sans ouvrir l'app (crédits, factures, fin de Pro…) : une seule fois
        expect(await push.dailyReminders()).toBeGreaterThan(0);
        const before = (await dbs.db.execute(sql`SELECT count(*)::int AS n FROM core.push_queue`)).rows[0];
        await push.dailyReminders();
        expect((await dbs.db.execute(sql`SELECT count(*)::int AS n FROM core.push_queue`)).rows[0]).toEqual(before);
      } finally {
        push.useSender(undefined as unknown as null);
      }
    });
  });

  describe('Supprimer une boutique ou son compte', () => {
    it('boutique : propriétaire seul, nom retapé, restaurable 30 jours, puis effacée', async () => {
      const { sql } = await import('drizzle-orm');
      const closure = app.get(ClosureService);
      const owner = await login('+221770030001');
      const biz = (
        await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Rokhaya Bazin' }).expect(201)
      ).body.business.id;
      const O = () => auth(owner.accessToken, biz);
      await http.post('/v1/catalog/products').set(O()).send({ name: 'Bazin riche', price: 25000 }).expect(201);
      const manager = await login('+221770030002');
      await http.post('/v1/members').set(O()).send({ phone: '+221770030002', roleKey: 'manager' }).expect(201);
      const M = () => auth(manager.accessToken, biz);

      // Le gérant ne peut pas ; un nom mal tapé est refusé
      await http.delete('/v1/business').set(M()).send({ confirmName: 'Rokhaya Bazin' }).expect(403);
      await http.delete('/v1/business').set(O()).send({ confirmName: 'Rokhaya' }).expect(422);
      const del = (await http.delete('/v1/business').set(O()).send({ confirmName: '  rokhaya  bazin ' }).expect(200))
        .body;
      expect(Math.round((Date.parse(del.purgeAt) - Date.now()) / 86_400_000)).toBe(30);

      // Disparue pour tout le monde
      await http.get('/v1/catalog/products').set(O()).expect(403);
      await http.get('/v1/catalog/products').set(M()).expect(403);
      expect((await http.get('/v1/me').set(auth(owner.accessToken)).expect(200)).body.businesses).toEqual([]);
      const list = (await http.get('/v1/businesses/deleted').set(auth(owner.accessToken)).expect(200)).body;
      expect(list).toEqual([expect.objectContaining({ id: biz, name: 'Rokhaya Bazin', daysLeft: 30 })]);
      expect((await http.get('/v1/businesses/deleted').set(auth(manager.accessToken)).expect(200)).body).toEqual([]);
      await http.post(`/v1/businesses/${biz}/restore`).set(auth(manager.accessToken)).expect(404);

      // Restaurée avec ses données
      await http.post(`/v1/businesses/${biz}/restore`).set(auth(owner.accessToken)).expect(200);
      const products = (await http.get('/v1/catalog/products').set(M()).expect(200)).body;
      expect(JSON.stringify(products)).toContain('Bazin riche');

      // Supprimée à nouveau ; 31 jours plus tard : effacée pour de bon
      await http.delete('/v1/business').set(O()).send({ confirmName: 'Rokhaya Bazin' }).expect(200);
      await dbs.db.execute(sql`UPDATE core.businesses SET deleted_at = now() - interval '31 days' WHERE id = ${biz}`);
      expect((await http.get('/v1/businesses/deleted').set(auth(owner.accessToken)).expect(200)).body).toEqual([]);
      const purged = await closure.purgeExpired();
      expect(purged.businesses).toBeGreaterThanOrEqual(1);
      expect((await dbs.db.execute(sql`SELECT 1 FROM core.businesses WHERE id = ${biz}`)).rows).toHaveLength(0);
      expect((await dbs.db.execute(sql`SELECT 1 FROM core.memberships WHERE business_id = ${biz}`)).rows).toHaveLength(
        0,
      );
      await http.post(`/v1/businesses/${biz}/restore`).set(auth(owner.accessToken)).expect(404);
    });

    it('compte : SUPPRIMER pour confirmer, sessions fermées, annulé en se reconnectant, sinon anonymisé', async () => {
      const { sql } = await import('drizzle-orm');
      const closure = app.get(ClosureService);
      const phone = '+221770030010';
      let u = await login(phone);
      await http.patch('/v1/me').set(auth(u.accessToken)).send({ fullName: 'Ndèye Fall' }).expect(200);
      const biz = (await http.post('/v1/businesses').set(auth(u.accessToken)).send({ name: 'Ndèye Mode' }).expect(201))
        .body.business.id;

      await http.delete('/v1/me').set(auth(u.accessToken)).send({ confirm: 'oui' }).expect(422);
      const del = (await http.delete('/v1/me').set(auth(u.accessToken)).send({ confirm: 'supprimer' }).expect(200))
        .body;
      expect(del).toMatchObject({ deleted: true, businesses: 1 });
      await http.post('/v1/auth/refresh').send({ refreshToken: u.refreshToken }).expect(401);
      await http.get('/v1/business').set(auth(u.accessToken, biz)).expect(403);

      // Reconnexion dans les 30 jours : compte et boutique reviennent
      await dbs.db.execute(
        sql`UPDATE core.otp_codes SET created_at = now() - interval '2 minutes' WHERE phone = ${phone}`,
      );
      await http.post('/v1/auth/otp/request').send({ phone }).expect(200);
      const back = (
        await http
          .post('/v1/auth/otp/verify')
          .send({ phone, code: otp.sent.get(phone) })
          .expect(200)
      ).body;
      expect(back).toMatchObject({ restored: true, isNewUser: false });
      u = back;
      expect((await http.get('/v1/me').set(auth(u.accessToken)).expect(200)).body.businesses).toEqual([
        expect.objectContaining({ id: biz, name: 'Ndèye Mode' }),
      ]);

      // Supprimé pour de bon après 30 jours : numéro libéré, nouveau compte vide
      await http.delete('/v1/me').set(auth(u.accessToken)).send({ confirm: 'SUPPRIMER' }).expect(200);
      await dbs.db.execute(sql`UPDATE core.users SET deleted_at = now() - interval '31 days' WHERE phone = ${phone}`);
      await dbs.db.execute(sql`UPDATE core.businesses SET deleted_at = now() - interval '31 days' WHERE id = ${biz}`);
      const purged = await closure.purgeExpired();
      expect(purged.users).toBe(1);
      const anon = (
        await dbs.db.execute(sql`SELECT phone, full_name, status FROM core.users WHERE id = ${back.user.id}`)
      ).rows[0];
      expect(anon).toMatchObject({ phone: `deleted:${back.user.id}`, full_name: null, status: 'deleted' });
      await dbs.db.execute(
        sql`UPDATE core.otp_codes SET created_at = now() - interval '2 minutes' WHERE phone = ${phone}`,
      );
      const fresh = await login(phone);
      expect(fresh.isNewUser).toBe(true);
      expect(fresh.user.id).not.toBe(back.user.id);
      expect((await http.get('/v1/me').set(auth(fresh.accessToken)).expect(200)).body.businesses).toEqual([]);
    });
  });

  describe('Comptes de paiement mobile (QR à la caisse)', () => {
    it('le patron enregistre ses numéros et liens, vides retirés, liens vérifiés', async () => {
      const owner = await login('+221770060001');
      const biz = (
        await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Diallo Tissus' }).expect(201)
      ).body.business.id;
      const O = () => auth(owner.accessToken, biz);
      await http
        .patch('/v1/business')
        .set(O())
        .send({ payAccounts: { wave: { link: 'http://pay.wave.com/m/x' } } })
        .expect(422);
      await http
        .patch('/v1/business')
        .set(O())
        .send({ payAccounts: { paypal: { number: '771234567' } } })
        .expect(422);
      await http
        .patch('/v1/business')
        .set(O())
        .send({
          payAccounts: {
            wave: { number: '77 123 45 67', link: 'https://pay.wave.com/m/M_sn_abc/c/sn/' },
            orange_money: { number: '', link: null },
          },
        })
        .expect(200);
      const b = (await http.get('/v1/business').set(O()).expect(200)).body.business;
      expect(b.settings.payAccounts).toEqual({
        wave: { number: '771234567', link: 'https://pay.wave.com/m/M_sn_abc/c/sn/' },
      });
      // Les autres réglages ne bougent pas
      await http.patch('/v1/business').set(O()).send({ focus: 'products' }).expect(200);
      const again = (await http.get('/v1/business').set(O()).expect(200)).body.business;
      expect(again.settings.payAccounts.wave.number).toBe('771234567');
      expect(again.settings.focus).toBe('products');
    });
  });

  describe('Variantes de produit (taille, couleur)', () => {
    it('modèle à variantes : combinaisons, stock, vente, boutique en ligne et garde-fous', async () => {
      // Nouvelle boutique du même commerçant : pas de connexion de plus (limite d'envoi de codes)
      const owner = awa;
      const biz = (
        await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Ndiaye Mode' }).expect(201)
      ).body.business.id;
      const O = () => auth(owner.accessToken, biz);
      const tshirt = (
        await http
          .post('/v1/catalog/products')
          .set(O())
          .send({ name: 'T-shirt col V', price: 5000, cost: 2500 })
          .expect(201)
      ).body.id;

      // Toutes les combinaisons, au prix du modèle
      const v1 = (
        await http
          .put(`/v1/catalog/products/${tshirt}/variants`)
          .set(O())
          .send({
            axes: [
              { name: 'Couleur', values: ['Noir', 'Blanc'] },
              { name: 'Taille', values: ['M', 'L'] },
            ],
          })
          .expect(200)
      ).body;
      expect(v1.product.variantAxes).toHaveLength(2);
      expect(v1.variants.map((v: { name: string }) => v.name).sort()).toEqual([
        'T-shirt col V · Blanc · L',
        'T-shirt col V · Blanc · M',
        'T-shirt col V · Noir · L',
        'T-shirt col V · Noir · M',
      ]);
      expect(
        v1.variants.every(
          (v: { price: number; cost: number; parentId: string }) =>
            v.price === 5000 && v.cost === 2500 && v.parentId === tshirt,
        ),
      ).toBe(true);
      const id = (name: string) => v1.variants.find((v: { name: string }) => v.name.endsWith(name)).id as string;
      const noirM = id('Noir · M');
      const blancL = id('Blanc · L');

      // Photo du modèle : les variantes sans photo la montrent dans le stock
      const png = Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        'base64',
      );
      const photo = (
        await http
          .post(`/v1/catalog/products/${tshirt}/images`)
          .set(O())
          .attach('file', png, { filename: 'p.png', contentType: 'image/png' })
          .expect(200)
      ).body.imageFileIds[0];
      const stockItems = (await http.get('/v1/inventory/stock').set(O()).expect(200)).body.items as {
        productId: string;
        imageFileId: string | null;
      }[];
      expect(stockItems.find((i) => i.productId === noirM)?.imageFileId).toBe(photo);

      // Prix et code-barres par variante ; les autres gardent les leurs
      const v2 = (
        await http
          .put(`/v1/catalog/products/${tshirt}/variants`)
          .set(O())
          .send({
            axes: [
              { name: 'Couleur', values: ['Noir', 'Blanc'] },
              { name: 'Taille', values: ['M', 'L', 'XL'] },
            ],
            variants: [
              { options: { Couleur: 'Noir', Taille: 'M' }, barcode: '600111' },
              { options: { couleur: 'blanc', taille: 'l' } },
              { options: { Couleur: 'Noir', Taille: 'XL' }, price: 6000 },
            ],
          })
          .expect(200)
      ).body;
      expect(v2.variants).toHaveLength(3); // Noir L et Blanc M retirés
      expect(v2.variants.find((v: { id: string }) => v.id === noirM)).toMatchObject({ barcode: '600111', price: 5000 });
      expect(v2.variants.find((v: { id: string }) => v.id === blancL)).toBeTruthy();
      expect(v2.variants.find((v: { name: string }) => v.name.endsWith('Noir · XL'))).toMatchObject({ price: 6000 });
      const scanned = (await http.get('/v1/catalog/products/by-code/600111').set(O()).expect(200)).body;
      expect(scanned.id).toBe(noirM);
      const bad = await http
        .put(`/v1/catalog/products/${tshirt}/variants`)
        .set(O())
        .send({ axes: [{ name: 'Taille', values: ['M'] }], variants: [{ options: { Couleur: 'Noir' } }] })
        .expect(422);
      expect(bad.body.error.message).toContain('Taille');
      await http
        .put(`/v1/catalog/products/${noirM}/variants`)
        .set(O())
        .send({ axes: [{ name: 'Taille', values: ['M'] }] })
        .expect(422);

      // Le modèle ne se vend pas, ne se stocke pas : la variante, oui
      const sellParent = await http
        .post('/v1/sales')
        .set(O())
        .send({
          id: '01930000-0000-7000-8000-0000000ae001',
          items: [{ productId: tshirt, quantity: 1 }],
          payments: [{ method: 'cash', amount: 5000 }],
        })
        .expect(422);
      expect(sellParent.body.error).toMatchObject({ code: 'VARIANT_REQUIRED' });
      await http
        .post('/v1/inventory/movements')
        .set(O())
        .send({ productId: tshirt, type: 'purchase', quantity: 3 })
        .expect(422);
      await http
        .post('/v1/inventory/movements')
        .set(O())
        .send({ productId: noirM, type: 'purchase', quantity: 4 })
        .expect(201);
      const sold = await http
        .post('/v1/sales')
        .set(O())
        .send({
          id: '01930000-0000-7000-8000-0000000ae002',
          items: [{ productId: noirM, quantity: 1 }],
          payments: [{ method: 'cash', amount: 5000 }],
        })
        .expect(201);
      expect(sold.body.items[0]).toMatchObject({ name: 'T-shirt col V · Noir · M', unitPrice: 5000 });
      // Le stock baisse quand l'événement de la vente est traité
      await relay.relayOnce();
      await waitFor(
        async () =>
          (
            (await http.get('/v1/inventory/stock').set(O()).expect(200)).body.items as {
              productId: string;
              onHand: number;
            }[]
          ).find((x) => x.productId === noirM)?.onHand,
        (q) => q === 3,
      );
      const stock = (await http.get('/v1/inventory/stock').set(O()).expect(200)).body.items as {
        productId: string;
        onHand: number;
      }[];
      expect(stock.find((x) => x.productId === tshirt)).toBeUndefined();
      expect(stock.find((x) => x.productId === noirM)?.onHand).toBe(3);

      // Le nom et le prix du modèle suivent sur les variantes restées à son prix
      await http
        .patch(`/v1/catalog/products/${tshirt}`)
        .set(O())
        .send({ name: 'Tee-shirt col V', price: 5500 })
        .expect(200);
      const all = (await http.get('/v1/catalog/products?limit=100').set(O()).expect(200)).body.data as {
        id: string;
        name: string;
        price: number;
        parentId: string | null;
      }[];
      expect(all.find((p) => p.id === noirM)).toMatchObject({ name: 'Tee-shirt col V · Noir · M', price: 5500 });
      expect(all.find((p) => p.name.endsWith('Noir · XL'))?.price).toBe(6000);

      // Boutique en ligne : le modèle publié emmène ses variantes, rangées dessous
      await http.put('/v1/shop/settings').set(O()).send({ enabled: true }).expect(200);
      const pub = await http
        .post('/v1/shop/publish')
        .set(O())
        .send({ productIds: [tshirt], published: true })
        .expect(200);
      expect(pub.body.updated).toBe(1);
      const slug = (await http.get('/v1/shop').set(O()).expect(200)).body.slug;
      const shop = (await http.get(`/v1/public/shops/${slug}`).expect(200)).body;
      expect(shop.products).toHaveLength(1);
      expect(shop.products[0]).toMatchObject({ id: tshirt, price: 5500, priceFrom: true, available: true });
      expect(shop.products[0].variants).toHaveLength(3);
      expect(shop.products[0].variants.find((v: { id: string }) => v.id === noirM)).toMatchObject({
        options: { Couleur: 'Noir', Taille: 'M' },
        available: true,
        maxQuantity: 3,
      });
      expect(shop.products[0].variants.find((v: { id: string }) => v.id === blancL).available).toBe(false);
      const base = { customerName: 'Awa Ba', customerPhone: '77 444 55 66', mode: 'pickup' };
      const parentOrder = await http
        .post(`/v1/public/shops/${slug}/orders`)
        .send({ ...base, id: '01938000-0000-7000-8000-0000000ae101', items: [{ productId: tshirt, quantity: 1 }] })
        .expect(422);
      expect(parentOrder.body.error.code).toBe('VARIANT_REQUIRED');
      await http
        .post(`/v1/public/shops/${slug}/orders`)
        .send({ ...base, id: '01938000-0000-7000-8000-0000000ae102', items: [{ productId: noirM, quantity: 2 }] })
        .expect(201);

      // Le modèle supprimé emporte ses variantes ; un produit déjà en stock refuse les variantes
      const casquette = (
        await http.post('/v1/catalog/products').set(O()).send({ name: 'Casquette', price: 3000 }).expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(O())
        .send({ productId: casquette, type: 'purchase', quantity: 2 })
        .expect(201);
      const stocked = await http
        .put(`/v1/catalog/products/${casquette}/variants`)
        .set(O())
        .send({ axes: [{ name: 'Couleur', values: ['Rouge'] }] })
        .expect(422);
      expect(stocked.body.error.message).toContain('remettez-le à zéro');
      await http.delete(`/v1/catalog/products/${tshirt}`).set(O()).expect(204);
      await http.get(`/v1/catalog/products/${noirM}`).set(O()).expect(404);
    });
  });

  describe('Quincaillerie : unités, conditionnement, catégories du métier', () => {
    it('vente au mètre, carton de 24, catégories prêtes', async () => {
      const biz = (
        await http
          .post('/v1/businesses')
          .set(auth(awa.accessToken))
          .send({ name: 'Quincaillerie Fall', category: 'quincaillerie' })
          .expect(201)
      ).body.business.id;
      const Q = () => auth(awa.accessToken, biz);
      await relay.relayOnce();
      const cats = await waitFor(
        async () => (await http.get('/v1/catalog/categories').set(Q()).expect(200)).body as { name: string }[],
        (c) => c.length >= 5,
      );
      expect(cats.map((c) => c.name)).toEqual(expect.arrayContaining(['Plomberie', 'Électricité', 'Outillage']));

      const bad = await http
        .post('/v1/catalog/products')
        .set(Q())
        .send({ name: 'Vis 6 mm', price: 25, packName: 'Boîte' })
        .expect(422);
      expect(bad.body.error.message).toContain('Conditionnement');
      const vis = (
        await http
          .post('/v1/catalog/products')
          .set(Q())
          .send({ name: 'Vis 6 mm', price: 25, packName: 'Boîte', packSize: 100 })
          .expect(201)
      ).body;
      expect(vis).toMatchObject({ packName: 'Boîte', packSize: 100 });
      await http.patch(`/v1/catalog/products/${vis.id}`).set(Q()).send({ packName: null, packSize: null }).expect(200);

      const cable = (
        await http
          .post('/v1/catalog/products')
          .set(Q())
          .send({ name: 'Câble 2,5 mm²', price: 600, unit: 'mètre' })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(Q())
        .send({ productId: cable, type: 'purchase', quantity: 100 })
        .expect(201);
      const sale = await http
        .post('/v1/sales')
        .set(Q())
        .send({
          id: '01930000-0000-7000-8000-0000000af001',
          items: [{ productId: cable, quantity: 2.5 }],
          payments: [{ method: 'cash', amount: 1500 }],
        })
        .expect(201);
      expect(sale.body).toMatchObject({ total: 1500 });
      expect(sale.body.items[0].quantity).toBe(2.5);
    });
  });

  describe('Métiers : restaurant, alimentation, téléphonie', () => {
    it('suppléments ajoutés au prix, péremption au stock, IMEI et garantie à la vente', async () => {
      const biz = (
        await http.post('/v1/businesses').set(auth(awa.accessToken)).send({ name: 'Multi Métiers' }).expect(201)
      ).body.business.id;
      const M = () => auth(awa.accessToken, biz);

      // Restaurant : le thiéboudienne avec œuf et piment
      const plat = (
        await http
          .post('/v1/catalog/products')
          .set(M())
          .send({
            name: 'Thiéboudienne',
            price: 2500,
            trackStock: false,
            extras: [
              { name: 'Œuf', price: 200 },
              { name: 'Piment', price: 0 },
            ],
          })
          .expect(201)
      ).body.id;
      const meal = await http
        .post('/v1/sales')
        .set(M())
        .send({
          id: '01930000-0000-7000-8000-0000000b0001',
          items: [{ productId: plat, quantity: 2, extras: ['œuf', 'Piment'] }],
          payments: [{ method: 'cash', amount: 5400 }],
        })
        .expect(201);
      expect(meal.body.items[0]).toMatchObject({ name: 'Thiéboudienne + Œuf, Piment', unitPrice: 2700, total: 5400 });
      const unknown = await http
        .post('/v1/sales')
        .set(M())
        .send({
          id: '01930000-0000-7000-8000-0000000b0002',
          items: [{ productId: plat, quantity: 1, extras: ['Fromage'] }],
          payments: [],
        })
        .expect(422);
      expect(unknown.body.error.message).toContain('Fromage');

      // Alimentation : la date de péremption remonte dans le stock
      const yaourt = (
        await http
          .post('/v1/catalog/products')
          .set(M())
          .send({ name: 'Yaourt', price: 300, expiresOn: '2026-12-05' })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(M())
        .send({ productId: yaourt, type: 'purchase', quantity: 10 })
        .expect(201);
      const stock = (await http.get('/v1/inventory/stock').set(M()).expect(200)).body.items as {
        productId: string;
        expiresOn: string;
      }[];
      expect(stock.find((x) => x.productId === yaourt)?.expiresOn).toBe('2026-12-05');

      // Téléphonie : un IMEI par appareil, garantie de 12 mois, retrouvée par l'IMEI
      const tel = (
        await http
          .post('/v1/catalog/products')
          .set(M())
          .send({ name: 'Tecno Spark 20', price: 85000, trackSerial: true, warrantyMonths: 12 })
          .expect(201)
      ).body.id;
      await http
        .post('/v1/inventory/movements')
        .set(M())
        .send({ productId: tel, type: 'purchase', quantity: 5 })
        .expect(201);
      const noImei = await http
        .post('/v1/sales')
        .set(M())
        .send({
          id: '01930000-0000-7000-8000-0000000b0003',
          items: [{ productId: tel, quantity: 2, serials: ['356789012345678'] }],
          payments: [],
        })
        .expect(422);
      expect(noImei.body.error.message).toContain('IMEI');
      const phone = await http
        .post('/v1/sales')
        .set(M())
        .send({
          id: '01930000-0000-7000-8000-0000000b0004',
          items: [{ productId: tel, quantity: 2, serials: ['356789012345678', '356789012345679'] }],
          payments: [{ method: 'cash', amount: 170000 }],
          soldAt: '2026-11-20T10:00:00Z',
        })
        .expect(201);
      expect(phone.body.items[0]).toMatchObject({
        serials: ['356789012345678', '356789012345679'],
        warrantyUntil: '2027-11-20',
      });
      const found = (await http.get('/v1/sales/by-serial/356789012345679').set(M()).expect(200)).body;
      expect(found).toMatchObject({
        number: phone.body.number,
        product: 'Tecno Spark 20',
        warrantyUntil: '2027-11-20',
        underWarranty: true,
      });
      await http.get('/v1/sales/by-serial/000').set(M()).expect(404);
    });
  });

  describe('Compte de démonstration (validation Play Store)', () => {
    it('le numéro de démonstration reçoit le code fixe, sans SMS', async () => {
      const before = otp.sent.size;
      await http.post('/v1/auth/otp/request').send({ phone: '70 000 07 77' }).expect(200);
      expect(otp.sent.has('+221700000777')).toBe(false); // aucun SMS
      expect(otp.sent.size).toBe(before);
      await http.post('/v1/auth/otp/verify').send({ phone: '+221700000777', code: '111111' }).expect(400);
      const ok = await http.post('/v1/auth/otp/verify').send({ phone: '+221700000777', code: '246810' }).expect(200);
      expect(ok.body.accessToken).toBeTruthy();
    });
  });

  describe('Pages légales et suppression du compte depuis le web', () => {
    it('CGU, confidentialité, page de suppression ; suppression par code sans créer de compte', async () => {
      const cgu = await http.get('/cgu').expect(200);
      expect(cgu.headers['content-type']).toContain('text/html');
      expect(cgu.text).toContain('Conditions d’utilisation');
      expect(cgu.text).toContain('5&nbsp;000&nbsp;F&nbsp;CFA par mois');
      expect(cgu.text).toContain('1&nbsp;500&nbsp;F&nbsp;CFA par semaine');
      expect(cgu.text).toContain('jusqu’à 50 produits');
      const privacy = await http.get('/confidentialite').expect(200);
      for (const w of ['loi n° 2008-12', 'loi n° 2013-450', 'loi n° 29-2019', 'Twilio', 'Chariow']) {
        expect(privacy.text).toContain(w);
      }
      expect((await http.get('/suppression-compte').expect(200)).text).toContain('/v1/public/account-deletion');

      // Un numéro sans compte : rien n'est créé
      await http.post('/v1/auth/otp/request').send({ phone: '+221770070009' }).expect(200);
      const ghost = await http
        .post('/v1/public/account-deletion')
        .send({ phone: '+221770070009', code: otp.sent.get('+221770070009'), confirm: 'SUPPRIMER' })
        .expect(404);
      expect(ghost.body.error.code).toBe('NOT_FOUND');
      const { sql } = await import('drizzle-orm');
      const users = await dbs.db.execute(sql`SELECT 1 FROM core.users WHERE phone = '+221770070009'`);
      expect(users.rows).toHaveLength(0);

      // Un vrai compte avec sa boutique
      const owner = await login('+221770070001');
      const biz = (
        await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Quincaillerie Web' }).expect(201)
      ).body.business.id;
      // Nouveau code (le renvoi est limité à un par minute : on vieillit le précédent)
      await dbs.db.execute(
        sql`UPDATE core.otp_codes SET created_at = now() - interval '2 minutes' WHERE phone = '+221770070001'`,
      );
      await http.post('/v1/auth/otp/request').send({ phone: '+221770070001' }).expect(200);
      const code = otp.sent.get('+221770070001')!;
      await http
        .post('/v1/public/account-deletion')
        .send({ phone: '+221770070001', code: code === '000000' ? '111111' : '000000', confirm: 'SUPPRIMER' })
        .expect(400);
      await http.post('/v1/public/account-deletion').send({ phone: '+221770070001', code, confirm: 'oui' }).expect(422);
      const done = (
        await http
          .post('/v1/public/account-deletion')
          .send({ phone: '+221770070001', code, confirm: 'SUPPRIMER' })
          .expect(200)
      ).body;
      expect(done).toEqual(expect.objectContaining({ deleted: true, businesses: 1 }));
      // Session coupée, boutique fermée
      await http.post('/v1/auth/refresh').send({ refreshToken: owner.refreshToken }).expect(401);
      const gone = await dbs.db.execute(sql`SELECT deleted_at FROM core.businesses WHERE id = ${biz}`);
      expect((gone.rows[0] as { deleted_at: unknown }).deleted_at).not.toBeNull();
    });
  });

  describe('Back office Sama360', () => {
    it('tableau de bord, commerçants, gestes de l’équipe, réservé aux admins', async () => {
      const A = () => auth(adminToken!);
      const owner = await login('+221770050001');
      const biz = (
        await http.post('/v1/businesses').set(auth(owner.accessToken)).send({ name: 'Atelier Xaritou' }).expect(201)
      ).body.business.id;
      const O = () => auth(owner.accessToken, biz);
      const p = (await http.post('/v1/catalog/products').set(O()).send({ name: 'Boubou', price: 15000 }).expect(201))
        .body;
      await http
        .post('/v1/sales')
        .set(O())
        .send({ items: [{ productId: p.id, quantity: 2 }], payments: [{ method: 'cash', amount: 30000 }] })
        .expect(201);

      // Suggestion envoyée depuis le profil ; l'entreprise d'un autre n'est pas gardée
      await http.post('/v1/feedback').set(auth(owner.accessToken)).send({ kind: 'idea', message: 'a' }).expect(422);
      await http
        .post('/v1/feedback')
        .set(auth(owner.accessToken))
        .send({ kind: 'idea', message: 'Ajoutez le wolof svp', businessId: biz, appVersion: '1.0.0' })
        .expect(201);
      await http
        .post('/v1/feedback')
        .set(auth(owner.accessToken))
        .send({ kind: 'problem', message: 'Le reçu ne part pas', businessId: '00000000-0000-4000-8000-000000000000' })
        .expect(201);
      await http.get('/v1/admin/feedback').set(auth(owner.accessToken)).expect(403);

      // Un commerçant n'y a pas accès
      for (const path of ['overview', 'businesses', `businesses/${biz}`, 'payments', 'feedback']) {
        await http.get(`/v1/admin/${path}`).set(auth(owner.accessToken)).expect(403);
      }

      const ov = (await http.get('/v1/admin/overview?days=30').set(A()).expect(200)).body;
      expect(ov.businesses.total).toBeGreaterThanOrEqual(5);
      expect(ov.businesses.new).toBeGreaterThanOrEqual(1);
      expect(ov.signupsByDay).toHaveLength(30);
      expect(ov.revenueByDay).toHaveLength(30);
      expect(ov.revenue.allTime).toBeGreaterThan(0); // le paiement Pro validé plus haut
      expect(ov.merchantsGmv30).toBeGreaterThanOrEqual(30000);
      expect(ov.countries[0]).toEqual(expect.objectContaining({ code: 'SN', name: 'Sénégal' }));
      expect(ov.plans.trial + ov.plans.active + ov.plans.expired + ov.plans.free).toBe(ov.businesses.total);
      expect(ov.newFeedback).toBeGreaterThanOrEqual(2);
      const fb = (await http.get('/v1/admin/feedback?status=new').set(A()).expect(200)).body;
      const idea = fb.items.find((f: { message: string }) => f.message === 'Ajoutez le wolof svp');
      expect(idea).toMatchObject({
        kind: 'idea',
        businessName: 'Atelier Xaritou',
        userPhone: '+221770050001',
        appVersion: '1.0.0',
      });
      expect(fb.items.find((f: { kind: string }) => f.kind === 'problem')).toMatchObject({ businessId: null });
      await http.patch(`/v1/admin/feedback/${idea.id}`).set(A()).send({ status: 'done' }).expect(200);
      const after = (await http.get('/v1/admin/feedback?status=done').set(A()).expect(200)).body;
      expect(after.items.map((f: { id: string }) => f.id)).toContain(idea.id);
      expect(after.counts.done).toBeGreaterThanOrEqual(1);
      // Semaine par semaine : 8 semaines, la dernière contient les boutiques de ce test (dont une qui a vendu)
      expect(ov.weeks).toHaveLength(8);
      const thisWeek = ov.weeks[7];
      expect(new Date(thisWeek.week).getUTCDay()).toBe(1); // lundi
      expect(thisWeek.signups).toBeGreaterThanOrEqual(1);
      expect(thisWeek.sold).toBeGreaterThanOrEqual(1);
      expect(thisWeek.sold).toBeLessThanOrEqual(thisWeek.signups);
      expect(thisWeek.paid).toBeLessThanOrEqual(thisWeek.signups);
      for (const w of ov.weeks)
        expect(w).toEqual(expect.objectContaining({ stopped: expect.any(Number), trialsLost: expect.any(Number) }));

      const found = (await http.get('/v1/admin/businesses?q=xaritou').set(A()).expect(200)).body;
      expect(found.total).toBe(1);
      expect(found.items[0]).toEqual(
        expect.objectContaining({
          id: biz,
          status: 'active',
          owner: expect.objectContaining({ phone: '+221770050001' }),
          plan: expect.objectContaining({ state: 'trial' }),
          stats: expect.objectContaining({ sales30: 1, revenue30: 30000, products: 1 }),
        }),
      );
      const byPhone = (await http.get('/v1/admin/businesses?q=770050001').set(A()).expect(200)).body;
      expect(byPhone.items.map((b: { id: string }) => b.id)).toEqual([biz]);
      const trials = (await http.get('/v1/admin/businesses?plan=trial&sort=revenue').set(A()).expect(200)).body;
      expect(trials.items.every((b: { plan: { state: string } }) => b.plan.state === 'trial')).toBe(true);
      await http.get('/v1/admin/businesses?plan=gold').set(A()).expect(422);

      // Mois offert : notifié, tracé
      const before = (await http.get(`/v1/admin/businesses/${biz}`).set(A()).expect(200)).body;
      expect(before.members).toEqual([expect.objectContaining({ phone: '+221770050001', roleKey: 'owner' })]);
      expect(before.locations.length).toBeGreaterThanOrEqual(1);
      await http.post(`/v1/admin/businesses/${biz}/gift`).set(A()).send({ days: 0 }).expect(422);
      const gift = (
        await http
          .post(`/v1/admin/businesses/${biz}/gift`)
          .set(A())
          .send({ days: 15, reason: 'Panne réseau' })
          .expect(200)
      ).body;
      expect(Date.parse(gift.endsAt)).toBeGreaterThan(Date.parse(before.plan.endsAt));
      const notes = (await http.get('/v1/notifications').set(O()).expect(200)).body;
      expect(JSON.stringify(notes)).toContain('15 jours de Pro offerts');

      // Suspension : la boutique est bloquée avec un message clair, la boutique en ligne aussi
      await http.post(`/v1/admin/businesses/${biz}/suspend`).set(A()).send({ reason: '' }).expect(422);
      await http.post(`/v1/admin/businesses/${biz}/suspend`).set(A()).send({ reason: 'Fraude signalée' }).expect(200);
      await http.post(`/v1/admin/businesses/${biz}/suspend`).set(A()).send({ reason: 'Encore' }).expect(409);
      const blocked = await http.get('/v1/catalog/products').set(O()).expect(403);
      expect(blocked.body.error?.code ?? blocked.body.code).toBe('BUSINESS_SUSPENDED');
      const sus = (await http.get('/v1/admin/businesses?status=suspended').set(A()).expect(200)).body;
      expect(sus.items.map((b: { id: string }) => b.id)).toContain(biz);
      await http.post(`/v1/admin/businesses/${biz}/unsuspend`).set(A()).expect(200);
      await http.get('/v1/catalog/products').set(O()).expect(200);

      const detail = (await http.get(`/v1/admin/businesses/${biz}`).set(A()).expect(200)).body;
      expect(detail.actions.map((a: { action: string }) => a.action)).toEqual(['unsuspend', 'suspend', 'gift']);
      expect(detail.status).toBe('active');

      // Paiements : la demande validée plus haut y figure
      const pays = (await http.get('/v1/admin/payments?status=paid').set(A()).expect(200)).body;
      expect(pays.items.length).toBeGreaterThanOrEqual(1);
      expect(pays.items.every((x: { status: string }) => x.status === 'paid')).toBe(true);

      // Boutique supprimée : rétablie par l'équipe à la demande du commerçant
      await http.delete('/v1/business').set(O()).send({ confirmName: 'Atelier Xaritou' }).expect(200);
      expect((await http.get('/v1/admin/businesses?q=xaritou').set(A()).expect(200)).body.total).toBe(0);
      const gone = (await http.get('/v1/admin/businesses?status=deleted&q=xaritou').set(A()).expect(200)).body;
      expect(gone.items[0].status).toBe('deleted');
      await http.post(`/v1/admin/businesses/${biz}/gift`).set(A()).send({ days: 5 }).expect(409);
      await http.post(`/v1/admin/businesses/${biz}/restore`).set(A()).expect(200);
      await http.get('/v1/catalog/products').set(O()).expect(200);
    });
  });

  describe('Sessions', () => {
    it('déconnecte tous les appareils', async () => {
      // Session du caissier (les codes de connexion sont limités par minute : on réutilise sa session)
      const res = await http.post('/v1/me/logout-all').set(auth(cashierToken)).expect(200);
      expect(res.body.revoked).toBeGreaterThanOrEqual(1);
      await http.post('/v1/auth/refresh').send({ refreshToken: cashierRefresh }).expect(401);
    });

    it('fait tourner le jeton de rafraîchissement et détecte sa réutilisation', async () => {
      const r1 = await http.post('/v1/auth/refresh').send({ refreshToken: awa.refreshToken }).expect(200);
      expect(r1.body.refreshToken).not.toBe(awa.refreshToken);
      await http.get('/v1/me').set(auth(r1.body.accessToken)).expect(200);

      // Réutilisation de l'ancien jeton → toutes les sessions sont coupées
      await http.post('/v1/auth/refresh').send({ refreshToken: awa.refreshToken }).expect(401);
      await http.post('/v1/auth/refresh').send({ refreshToken: r1.body.refreshToken }).expect(401);
    });

    it('déconnexion', async () => {
      await http.post('/v1/auth/logout').send({ refreshToken: moussa.refreshToken }).expect(204);
      await http.post('/v1/auth/refresh').send({ refreshToken: moussa.refreshToken }).expect(401);
    });
  });
});
