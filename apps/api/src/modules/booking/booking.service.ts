import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';
import { readableOnWhite } from '../../shared/color';
import { NotificationsService } from '../notifications/notifications.service';
import {
  AppointmentStatus,
  BookingSettings,
  bookableDays,
  DEFAULT_BOOKING,
  DEFAULT_SERVICE_MINUTES,
  freeSlots,
  hourLabel,
  overlappingIds,
} from './booking';

type Row = Record<string, unknown>;

export interface AppointmentInput {
  customerId?: string | null;
  customerName?: string | null;
  customerPhone?: string | null;
  serviceId?: string | null;
  serviceName?: string | null;
  price?: number | null;
  startsAt: string;
  durationMinutes: number;
  note?: string | null;
}

@Injectable()
export class BookingService {
  constructor(
    private readonly dbs: DbService,
    private readonly notifications: NotificationsService,
  ) {}

  // ------------------------------------------------------------ réglages

  private async settingsIn(tx: Tx): Promise<BookingSettings> {
    const r = (
      await tx.execute(sql`SELECT online_enabled, open_days, to_char(open_time, 'HH24:MI') AS open_time,
        to_char(close_time, 'HH24:MI') AS close_time, slot_minutes, capacity, min_notice_minutes, max_days_ahead
        FROM sales.booking_settings`)
    ).rows[0] as Row | undefined;
    if (!r) return DEFAULT_BOOKING;
    return {
      onlineEnabled: r.online_enabled === true,
      openDays: (r.open_days as number[]).map(Number),
      openTime: String(r.open_time),
      closeTime: String(r.close_time),
      slotMinutes: Number(r.slot_minutes) as 15 | 30 | 60,
      capacity: Number(r.capacity),
      minNoticeMinutes: Number(r.min_notice_minutes),
      maxDaysAhead: Number(r.max_days_ahead),
    };
  }

  settings(businessId: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const slug = (await tx.execute(sql`SELECT slug FROM core.businesses WHERE id = ${businessId}`)).rows[0] as Row;
      return { ...(await this.settingsIn(tx)), bookingPath: `/r/${String(slug?.slug ?? '')}` };
    });
  }

  saveSettings(businessId: string, s: BookingSettings) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const days = `{${[...new Set(s.openDays)].sort().join(',')}}`;
      await tx.execute(sql`
        INSERT INTO sales.booking_settings (business_id, online_enabled, open_days, open_time, close_time, slot_minutes,
          capacity, min_notice_minutes, max_days_ahead)
        VALUES (${businessId}, ${s.onlineEnabled}, ${days}::smallint[], ${s.openTime}::time, ${s.closeTime}::time,
          ${s.slotMinutes}, ${s.capacity}, ${s.minNoticeMinutes}, ${s.maxDaysAhead})
        ON CONFLICT (business_id) DO UPDATE SET online_enabled = excluded.online_enabled, open_days = excluded.open_days,
          open_time = excluded.open_time, close_time = excluded.close_time, slot_minutes = excluded.slot_minutes,
          capacity = excluded.capacity, min_notice_minutes = excluded.min_notice_minutes,
          max_days_ahead = excluded.max_days_ahead, updated_at = now()`);
      const slug = (await tx.execute(sql`SELECT slug FROM core.businesses WHERE id = ${businessId}`)).rows[0] as Row;
      return { ...(await this.settingsIn(tx)), bookingPath: `/r/${String(slug?.slug ?? '')}` };
    });
  }

  // ------------------------------------------------------------ public (page de réservation)

  /** Boutique dont la réservation en ligne est ouverte. Sinon 404 (rien ne fuit sur les autres). */
  private async openShop(slug: string) {
    const b = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT id, name, phone, address, city, logo_file_id, brand_color FROM core.businesses
          WHERE slug = ${slug.toLowerCase()} AND deleted_at IS NULL`),
      )
    ).rows[0] as Row | undefined;
    if (!b) throw AppError.notFound('Réservation');
    return b;
  }

  private async servicesIn(tx: Tx) {
    const rows = (
      await tx.execute(sql`SELECT id, name, price, coalesce(duration_minutes, ${DEFAULT_SERVICE_MINUTES}) AS duration
        FROM catalog.products WHERE type = 'service' AND deleted_at IS NULL ORDER BY lower(name)`)
    ).rows as Row[];
    return rows.map((r) => ({
      id: String(r.id),
      name: String(r.name),
      price: Number(r.price),
      duration: Number(r.duration),
    }));
  }

  publicInfo(slug: string) {
    return this.openShop(slug).then((b) =>
      this.dbs.withTenant(String(b.id), async (tx) => {
        const s = await this.settingsIn(tx);
        if (!s.onlineEnabled) throw AppError.notFound('Réservation');
        return {
          shop: {
            slug: slug.toLowerCase(),
            name: String(b.name),
            whatsapp: (b.phone as string) ?? null,
            address: [b.address, b.city].filter(Boolean).join(', ') || null,
            logoFileId: (b.logo_file_id as string) ?? null,
            brandColor: b.brand_color ? readableOnWhite(String(b.brand_color)) : null,
          },
          services: await this.servicesIn(tx),
          days: bookableDays(s),
        };
      }),
    );
  }

  private async busyIn(tx: Tx, day: string) {
    return (
      (
        await tx.execute(sql`SELECT starts_at, duration_minutes FROM sales.appointments
          WHERE status = 'booked' AND starts_at >= ${day}::date - 1 AND starts_at < ${day}::date + 1`)
      ).rows as Row[]
    ).map((r) => ({ startsAt: new Date(String(r.starts_at)), durationMinutes: Number(r.duration_minutes) }));
  }

  publicSlots(slug: string, serviceId: string, day: string) {
    return this.openShop(slug).then((b) =>
      this.dbs.withTenant(String(b.id), async (tx) => {
        const s = await this.settingsIn(tx);
        if (!s.onlineEnabled) throw AppError.notFound('Réservation');
        const service = (await this.servicesIn(tx)).find((x) => x.id === serviceId);
        if (!service) throw AppError.notFound('Prestation');
        return {
          day,
          slots: freeSlots({ day, settings: s, duration: service.duration, existing: await this.busyIn(tx, day) }),
        };
      }),
    );
  }

  /** Réservation par un client sur la page publique. Idempotente sur l'identifiant envoyé par la page. */
  publicBook(
    slug: string,
    input: {
      id: string;
      serviceId: string;
      day: string;
      time: string;
      name: string;
      phone: string;
      note?: string | null;
    },
  ) {
    return this.openShop(slug).then((b) =>
      this.dbs.withTenant(String(b.id), async (tx) => {
        const phone = normalizePhone(input.phone);
        if (!phone) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', 422);
        const again = (await tx.execute(sql`SELECT * FROM sales.appointments WHERE id = ${input.id}`)).rows[0] as
          Row | undefined;
        if (again) return { created: false, appointment: { ...this.dto(again), shopName: String(b.name) } };

        // Un seul enregistrement à la fois par boutique : deux clients ne prennent pas le dernier créneau
        await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${'booking:' + String(b.id)}))`);
        const s = await this.settingsIn(tx);
        if (!s.onlineEnabled) throw AppError.notFound('Réservation');
        const service = (await this.servicesIn(tx)).find((x) => x.id === input.serviceId);
        if (!service) throw AppError.notFound('Prestation');
        const free = freeSlots({
          day: input.day,
          settings: s,
          duration: service.duration,
          existing: await this.busyIn(tx, input.day),
        });
        if (!free.includes(input.time)) {
          throw new AppError('SLOT_TAKEN', 'Ce créneau vient d’être pris. Choisissez une autre heure.', 409);
        }
        const startsAt = new Date(`${input.day}T${input.time}:00Z`);
        // Client connu par son numéro : le rendez-vous est rattaché à sa fiche
        const known = (
          await tx.execute(
            sql`SELECT id, name FROM contacts.contacts WHERE phone = ${phone} AND deleted_at IS NULL LIMIT 1`,
          )
        ).rows[0] as Row | undefined;
        await tx.execute(sql`
          INSERT INTO sales.appointments (id, business_id, customer_id, customer_name, customer_phone, service_id,
            service_name, price, starts_at, duration_minutes, note, source)
          VALUES (${input.id}, ${String(b.id)}, ${(known?.id as string) ?? null}, ${input.name}, ${phone}, ${service.id},
            ${service.name}, ${service.price}, ${startsAt.toISOString()}, ${service.duration}, ${input.note ?? null}, 'online')`);
        const when = new Intl.DateTimeFormat('fr-FR', {
          weekday: 'long',
          day: 'numeric',
          month: 'long',
          timeZone: 'UTC',
        }).format(startsAt);
        await this.notifications.push(tx, String(b.id), {
          kind: 'appointment_online',
          title: 'Nouveau rendez-vous en ligne',
          body: `${input.name} · ${service.name} · ${when} à ${hourLabel(startsAt)}`,
          link: '/booking',
          audience: 'sales:read',
          dedupeKey: `appointment_online:${input.id}`,
        });
        const row = (await tx.execute(sql`SELECT * FROM sales.appointments WHERE id = ${input.id}`)).rows[0] as Row;
        return { created: true, appointment: { ...this.dto(row), shopName: String(b.name) } };
      }),
    );
  }

  private dto(r: Row) {
    return {
      id: String(r.id),
      customerId: (r.customer_id as string | null) ?? null,
      customerName: String(r.customer_name),
      customerPhone: (r.customer_phone as string | null) ?? null,
      serviceId: (r.service_id as string | null) ?? null,
      serviceName: String(r.service_name),
      price: Number(r.price),
      startsAt: new Date(String(r.starts_at)).toISOString(),
      durationMinutes: Number(r.duration_minutes),
      status: String(r.status) as AppointmentStatus,
      note: (r.note as string | null) ?? null,
      source: String(r.source ?? 'staff'),
    };
  }

  /** Rendez-vous entre deux dates (jours inclus), avec les chevauchements signalés. */
  list(businessId: string, from: string, to: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const rows = (
        await tx.execute(sql`SELECT * FROM sales.appointments
          WHERE starts_at >= ${from}::date AND starts_at < ${to}::date + 1
          ORDER BY starts_at, created_at`)
      ).rows as Row[];
      const items = rows.map((r) => this.dto(r));
      const overlaps = overlappingIds(items.map((a) => ({ ...a, startsAt: new Date(a.startsAt) })));
      const counts = (
        await tx.execute(sql`SELECT to_char(starts_at, 'YYYY-MM-DD') AS day, count(*)::int AS n FROM sales.appointments
          WHERE status = 'booked' AND starts_at >= ${from}::date - 7 AND starts_at < ${to}::date + 8
          GROUP BY 1`)
      ).rows as { day: string; n: number }[];
      return {
        items: items.map((a) => ({ ...a, overlaps: overlaps.has(a.id) })),
        // Rendez-vous à venir par jour (points sur la bande des jours)
        bookedByDay: Object.fromEntries(counts.map((c) => [c.day, Number(c.n)])),
      };
    });
  }

  /** Client : fiche existante (nom et téléphone repris) ou client de passage (nom obligatoire). */
  private async resolve(tx: Tx, input: Partial<AppointmentInput>) {
    const out: Record<string, unknown> = {};
    if (input.customerId !== undefined) {
      if (input.customerId) {
        const c = (
          await tx.execute(
            sql`SELECT name, phone FROM contacts.contacts WHERE id = ${input.customerId} AND deleted_at IS NULL`,
          )
        ).rows[0] as Row | undefined;
        if (!c) throw AppError.notFound('Client');
        out.customer_id = input.customerId;
        out.customer_name = c.name;
        out.customer_phone = c.phone ?? null;
      } else {
        out.customer_id = null;
      }
    }
    if (!out.customer_id && input.customerName !== undefined) out.customer_name = input.customerName;
    if (!out.customer_id && input.customerPhone !== undefined) {
      out.customer_phone = input.customerPhone ? normalizePhone(input.customerPhone) : null;
      if (input.customerPhone && !out.customer_phone) {
        throw new AppError('VALIDATION_FAILED', 'Numéro de téléphone invalide', 422);
      }
    }
    if (input.serviceId !== undefined) {
      if (input.serviceId) {
        const p = (
          await tx.execute(
            sql`SELECT name, price FROM catalog.products WHERE id = ${input.serviceId} AND deleted_at IS NULL`,
          )
        ).rows[0] as Row | undefined;
        if (!p) throw AppError.notFound('Prestation');
        out.service_id = input.serviceId;
        out.service_name = p.name;
        if (input.price == null) out.price = Number(p.price);
      } else {
        out.service_id = null;
      }
    }
    if (input.serviceName && !out.service_id) out.service_name = input.serviceName;
    if (input.price != null) out.price = input.price;
    return out;
  }

  create(businessId: string, userId: string, input: AppointmentInput) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const v = await this.resolve(tx, input);
      if (!v.customer_name) throw new AppError('VALIDATION_FAILED', 'Indiquez le nom du client', 422);
      if (!v.service_name) throw new AppError('VALIDATION_FAILED', 'Indiquez la prestation', 422);
      const id = newId();
      await tx.execute(sql`
        INSERT INTO sales.appointments (id, business_id, customer_id, customer_name, customer_phone, service_id,
          service_name, price, starts_at, duration_minutes, note, created_by)
        VALUES (${id}, ${businessId}, ${(v.customer_id as string) ?? null}, ${v.customer_name as string},
          ${(v.customer_phone as string) ?? null}, ${(v.service_id as string) ?? null}, ${v.service_name as string},
          ${(v.price as number) ?? 0}, ${input.startsAt}, ${input.durationMinutes}, ${input.note ?? null}, ${userId})`);
      return this.dto((await tx.execute(sql`SELECT * FROM sales.appointments WHERE id = ${id}`)).rows[0] as Row);
    });
  }

  update(businessId: string, id: string, input: Partial<AppointmentInput> & { status?: AppointmentStatus }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const cur = (await tx.execute(sql`SELECT id FROM sales.appointments WHERE id = ${id} FOR UPDATE`)).rows[0];
      if (!cur) throw AppError.notFound('Rendez-vous');
      const v = await this.resolve(tx, input);
      if (input.startsAt !== undefined) v.starts_at = input.startsAt;
      if (input.durationMinutes !== undefined) v.duration_minutes = input.durationMinutes;
      if (input.note !== undefined) v.note = input.note;
      if (input.status !== undefined) v.status = input.status;
      const sets = Object.entries(v).map(([k, val]) => sql`${sql.raw(k)} = ${val as string | number | null}`);
      if (sets.length > 0) {
        await tx.execute(
          sql`UPDATE sales.appointments SET ${sql.join(sets, sql`, `)}, updated_at = now() WHERE id = ${id}`,
        );
      }
      return this.dto((await tx.execute(sql`SELECT * FROM sales.appointments WHERE id = ${id}`)).rows[0] as Row);
    });
  }
}
