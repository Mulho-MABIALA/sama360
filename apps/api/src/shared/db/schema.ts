/**
 * Schéma Drizzle — miroir typé des migrations SQL (apps/api/migrations).
 * Les migrations SQL font foi ; ce fichier sert aux requêtes typées.
 */
import {
  bigint,
  boolean,
  integer,
  jsonb,
  numeric,
  pgSchema,
  primaryKey,
  text,
  timestamp,
  uuid,
  varchar,
} from 'drizzle-orm/pg-core';

const ts = (name: string) => timestamp(name, { withTimezone: true, mode: 'date' });
const money = (name: string) => bigint(name, { mode: 'number' });

// ---------- core ----------
export const core = pgSchema('core');

export const users = core.table('users', {
  id: uuid('id').primaryKey(),
  phone: varchar('phone', { length: 20 }).notNull().unique(),
  fullName: varchar('full_name', { length: 120 }),
  email: varchar('email', { length: 160 }),
  pinHash: varchar('pin_hash', { length: 255 }),
  locale: varchar('locale', { length: 5 }).notNull().default('fr'),
  status: varchar('status', { length: 20 }).notNull().default('active'),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
});

export const otpCodes = core.table('otp_codes', {
  id: uuid('id').primaryKey(),
  phone: varchar('phone', { length: 20 }).notNull(),
  codeHash: varchar('code_hash', { length: 128 }).notNull(),
  attempts: integer('attempts').notNull().default(0),
  expiresAt: ts('expires_at').notNull(),
  consumedAt: ts('consumed_at'),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const refreshTokens = core.table('refresh_tokens', {
  id: uuid('id').primaryKey(),
  userId: uuid('user_id').notNull(),
  tokenHash: varchar('token_hash', { length: 128 }).notNull().unique(),
  deviceId: varchar('device_id', { length: 120 }),
  expiresAt: ts('expires_at').notNull(),
  revokedAt: ts('revoked_at'),
  replacedBy: uuid('replaced_by'),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const businesses = core.table('businesses', {
  id: uuid('id').primaryKey(),
  ownerId: uuid('owner_id').notNull(),
  name: varchar('name', { length: 120 }).notNull(),
  slug: varchar('slug', { length: 80 }).notNull().unique(),
  category: varchar('category', { length: 60 }),
  ninea: varchar('ninea', { length: 30 }),
  phone: varchar('phone', { length: 20 }),
  address: text('address'),
  city: varchar('city', { length: 80 }),
  country: varchar('country', { length: 2 }).notNull().default('SN'),
  currency: varchar('currency', { length: 3 }).notNull().default('XOF'),
  vatRate: numeric('vat_rate', { precision: 5, scale: 2 }).notNull().default('18.00'),
  logoFileId: uuid('logo_file_id'),
  settings: jsonb('settings').$type<Record<string, unknown>>().notNull().default({}),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
});

export const roles = core.table('roles', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id'),
  key: varchar('key', { length: 40 }).notNull(),
  name: varchar('name', { length: 80 }).notNull(),
  permissions: jsonb('permissions').$type<string[]>().notNull().default([]),
});

export const memberships = core.table('memberships', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull(),
  userId: uuid('user_id').notNull(),
  roleId: uuid('role_id').notNull(),
  status: varchar('status', { length: 20 }).notNull().default('active'),
  invitedBy: uuid('invited_by'),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const subscriptions = core.table('subscriptions', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull().unique(),
  plan: varchar('plan', { length: 20 }).notNull().default('free'),
  status: varchar('status', { length: 20 }).notNull().default('active'),
  billingCycle: varchar('billing_cycle', { length: 10 }).notNull().default('monthly'),
  currentPeriodEnd: ts('current_period_end'),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const moduleActivations = core.table(
  'module_activations',
  {
    businessId: uuid('business_id').notNull(),
    module: varchar('module', { length: 40 }).notNull(),
    enabled: boolean('enabled').notNull().default(true),
    settings: jsonb('settings').$type<Record<string, unknown>>().notNull().default({}),
    activatedAt: ts('activated_at').notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.businessId, t.module] })],
);

export const auditLogs = core.table('audit_logs', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id'),
  actorId: uuid('actor_id'),
  action: varchar('action', { length: 60 }).notNull(),
  entityType: varchar('entity_type', { length: 40 }),
  entityId: uuid('entity_id'),
  data: jsonb('data').$type<Record<string, unknown>>().notNull().default({}),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const outboxEvents = core.table('outbox_events', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull(),
  type: varchar('type', { length: 60 }).notNull(),
  version: integer('version').notNull().default(1),
  aggregateId: uuid('aggregate_id').notNull(),
  actorId: uuid('actor_id'),
  payload: jsonb('payload').notNull(),
  status: varchar('status', { length: 10 }).notNull().default('pending'),
  attempts: integer('attempts').notNull().default(0),
  lastError: text('last_error'),
  occurredAt: ts('occurred_at').notNull().defaultNow(),
  publishedAt: ts('published_at'),
});

export const processedEvents = core.table(
  'processed_events',
  {
    eventId: uuid('event_id').notNull(),
    handler: varchar('handler', { length: 120 }).notNull(),
    processedAt: ts('processed_at').notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.eventId, t.handler] })],
);

// ---------- contacts ----------
export const contactsSchema = pgSchema('contacts');

export const contacts = contactsSchema.table('contacts', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull(),
  type: varchar('type', { length: 10 }).$type<'customer' | 'supplier' | 'both'>().notNull().default('customer'),
  name: varchar('name', { length: 120 }).notNull(),
  phone: varchar('phone', { length: 20 }),
  email: varchar('email', { length: 160 }),
  address: text('address'),
  notes: text('notes'),
  balance: money('balance').notNull().default(0),
  version: integer('version').notNull().default(1),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
});

// ---------- catalog ----------
export const catalogSchema = pgSchema('catalog');

export const categories = catalogSchema.table('categories', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull(),
  name: varchar('name', { length: 80 }).notNull(),
  position: integer('position').notNull().default(0),
  createdAt: ts('created_at').notNull().defaultNow(),
});

export const products = catalogSchema.table('products', {
  id: uuid('id').primaryKey(),
  businessId: uuid('business_id').notNull(),
  categoryId: uuid('category_id'),
  type: varchar('type', { length: 10 }).$type<'product' | 'service'>().notNull().default('product'),
  name: varchar('name', { length: 160 }).notNull(),
  sku: varchar('sku', { length: 60 }),
  barcode: varchar('barcode', { length: 60 }),
  price: money('price').notNull(),
  cost: money('cost').notNull().default(0),
  unit: varchar('unit', { length: 20 }).notNull().default('pièce'),
  trackStock: boolean('track_stock').notNull().default(true),
  lowStockThreshold: integer('low_stock_threshold').notNull().default(5),
  published: boolean('published').notNull().default(false),
  imageFileIds: uuid('image_file_ids').array().notNull().default([]),
  version: integer('version').notNull().default(1),
  createdAt: ts('created_at').notNull().defaultNow(),
  updatedAt: ts('updated_at').notNull().defaultNow(),
  deletedAt: ts('deleted_at'),
});
