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
process.env.STORAGE_DIR = require('node:path').join(require('node:os').tmpdir(), `sama-e2e-${process.pid}`);

import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { sql } from 'drizzle-orm';
import { Client } from 'pg';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { ConsoleOtpSender } from '../src/modules/auth/otp-sender';
import { DbService } from '../src/shared/db/db.service';
import { contacts } from '../src/shared/db/schema';
import { migrate } from '../src/shared/db/migrate';
import { EventWorkerService } from '../src/shared/events/event-worker.service';
import { OutboxRelayService } from '../src/shared/events/outbox-relay.service';

async function resetDatabase(url: string) {
  const c = new Client({ connectionString: url });
  await c.connect();
  await c.query(`
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
  let moussa: { accessToken: string; refreshToken: string };
  let awaBiz: string;
  let cashierToken: string;
  let moussaBiz: string;

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
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
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
    it('refuse un numéro invalide', async () => {
      const res = await http.post('/v1/auth/otp/request').send({ phone: '12345678' }).expect(422);
      expect(res.body.error.code).toBe('PHONE_INVALID');
    });

    it('envoie un code, refuse un mauvais code puis connecte avec le bon', async () => {
      const r1 = await http.post('/v1/auth/otp/request').send({ phone: '77 123 45 67' }).expect(200);
      expect(r1.body).toEqual({ phone: AWA, expiresIn: 300 });

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
      expect(res.body.modules).toEqual(expect.arrayContaining(['sales', 'inventory', 'invoicing', 'shop']));
      expect(res.body.subscription.plan).toBe('free');
    });

    it('exige X-Business-Id et renvoie mes droits', async () => {
      const no = await http.get('/v1/business').set(auth(awa.accessToken)).expect(400);
      expect(no.body.error.code).toBe('BUSINESS_REQUIRED');

      const res = await http.get('/v1/business').set(auth(awa.accessToken, awaBiz)).expect(200);
      expect(res.body.business.name).toBe('Awa Beauté');
      expect(res.body.me).toEqual({ role: 'owner', permissions: ['*'] });
      expect(res.body.modules).toHaveLength(6);
    });

    it('business.created passe par l’outbox et crée les catégories par défaut (une seule fois)', async () => {
      const published = await relay.relayOnce();
      expect(published).toBeGreaterThanOrEqual(1);

      const cats = await waitFor(
        async () => (await http.get('/v1/catalog/categories').set(auth(awa.accessToken, awaBiz))).body as { name: string }[],
        (list) => list.length >= 2,
      );
      expect(cats.map((c) => c.name)).toEqual(['Général', 'Nouveautés']);

      // Re-livraison du même job : l'abonné ne s'exécute pas deux fois
      const [evt] = (
        await dbs.db.execute(sql`SELECT id FROM core.outbox_events WHERE type = 'business.created' AND business_id = ${awaBiz}`)
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
          tx.insert(contacts).values({ id: '01930000-0000-7000-8000-0000000000aa', businessId: awaBiz, name: 'Intrus' }),
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
      expect(forbidden.body.error).toMatchObject({ code: 'INSUFFICIENT_PERMISSION', details: { permission: 'catalog:write' } });
      await http.post('/v1/contacts').set(auth(moussa.accessToken, awaBiz)).send({ name: 'Client comptoir' }).expect(201);

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
      await http.patch(`/v1/members/${owner.id}`).set(auth(awa.accessToken, awaBiz)).send({ roleKey: 'manager' }).expect(403);

      await http.patch(`/v1/members/${cashier.id}`).set(auth(awa.accessToken, awaBiz)).send({ status: 'suspended' }).expect(200);
      const blocked = await http.get('/v1/catalog/products').set(auth(moussa.accessToken, awaBiz)).expect(403);
      expect(blocked.body.error.code).toBe('NOT_A_MEMBER');
    });
  });

  describe('Ventes et stock', () => {
    const CAISSIER = '+221770000099';
    let cashier: { accessToken: string };
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
      await http.post('/v1/inventory/movements').set(A()).send({ productId: karite, type: 'purchase', quantity: 20 }).expect(201);
      const bad = await http
        .post('/v1/inventory/movements')
        .set(A())
        .send({ productId: huile, type: 'purchase', quantity: -3 })
        .expect(422);
      expect(bad.body.error.code).toBe('VALIDATION_FAILED');

      aminata = (await http.post('/v1/contacts').set(A()).send({ name: 'Aminata Ba', phone: '76 555 12 34' }).expect(201)).body.id;

      await http.post('/v1/members').set(A()).send({ phone: CAISSIER, roleKey: 'cashier' }).expect(201);
      cashier = await login(CAISSIER);
      cashierToken = cashier.accessToken;
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
        .send({ customerId: aminata, items: [{ productId: huile, quantity: 5 }], payments: [{ method: 'wave', amount: 5000 }] })
        .expect(201);
      creditSaleId = res.body.id;
      expect(res.body).toMatchObject({ number: `VEN-${year}-0002`, total: 20000, paid: 5000, due: 15000 });
      expect(await balanceOf(aminata)).toBe(15000); // carnet écrit dans la même transaction

      // Le stock est mis à jour par l'abonné inventory (10 − 1 − 5 = 4 ; 20 − 2 = 18)
      await settle(() => stockOf(huile), (q) => q === 4);
      expect(await stockOf(karite)).toBe(18);

      const low = await http.get('/v1/inventory/stock?lowOnly=true').set(A()).expect(200);
      expect(low.body.items.map((i: { name: string }) => i.name)).toEqual(['Huile de coco 500 ml']);
      const alerts = (
        await dbs.db.execute(sql`SELECT payload FROM core.outbox_events WHERE type = 'stock.low' AND aggregate_id = ${huile}`)
      ).rows as { payload: { onHand: number; threshold: number } }[];
      expect(alerts).toHaveLength(1);
      expect(alerts[0].payload).toMatchObject({ onHand: 4, threshold: 5 });

      // Le cache de solde de l'annuaire suit, via contacts
      const contact = await waitFor(
        async () => (await http.get(`/v1/contacts/${aminata}`).set(A())).body,
        (c) => c.balance === 15000,
      );
      expect(contact.balance).toBe(15000);
    });

    it('un abonné ne décrémente jamais deux fois la même vente', async () => {
      const [evt] = (
        await dbs.db.execute(sql`SELECT id FROM core.outbox_events WHERE type = 'sale.completed' AND aggregate_id = ${creditSaleId}`)
      ).rows as { id: string }[];
      expect(await worker.process({ data: { eventId: evt.id, handler: 'InventoryEventHandlers.decrementOnSale' } })).toBe(false);
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
      expect(debtors.body).toEqual([expect.objectContaining({ customerId: aminata, name: 'Aminata Ba', balance: 10000 })]);
      await settle(async () => (await http.get(`/v1/contacts/${aminata}`).set(A())).body.balance, (b) => b === 10000);
    });

    it('calcule le résumé du jour : CA, bénéfice, encaissements, crédit', async () => {
      await http.post('/v1/sales/expenses').set(A()).send({ category: 'transport', amount: 2000, method: 'cash' }).expect(201);
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

    it('annule une vente : stock remis et dette annulée', async () => {
      const res = await http
        .post(`/v1/sales/${creditSaleId}/void`)
        .set(A())
        .send({ reason: 'Client a rendu la marchandise' })
        .expect(200);
      expect(res.body).toMatchObject({ status: 'voided', voidReason: 'Client a rendu la marchandise' });

      await settle(() => stockOf(huile), (q) => q === 9);
      // 10 000 dus − 15 000 annulés : la boutique doit 5 000 à la cliente (déjà payés)
      expect(await balanceOf(aminata)).toBe(-5000);

      const twice = await http.post(`/v1/sales/${creditSaleId}/void`).set(A()).send({ reason: 'encore' }).expect(409);
      expect(twice.body.error.code).toBe('SALE_ALREADY_VOIDED');

      const summary = (await http.get('/v1/sales/summary').set(A()).expect(200)).body;
      expect(summary).toMatchObject({ salesCount: 2, revenue: 11700 }); // 11 600 + 100 (vente annulée exclue)
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
      expect(stock.body.items.find((i: { productId: string }) => i.productId === productId).imageFileId).toBe(firstFile);
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
  });

  describe('Sessions', () => {
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
