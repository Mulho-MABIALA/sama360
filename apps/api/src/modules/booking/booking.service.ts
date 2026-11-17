import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';
import { AppointmentStatus, overlappingIds } from './booking';

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
  constructor(private readonly dbs: DbService) {}

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
