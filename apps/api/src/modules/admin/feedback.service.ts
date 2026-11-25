import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';

export type FeedbackKind = 'idea' | 'problem' | 'other';
export type FeedbackStatus = 'new' | 'read' | 'done';

type Row = Record<string, unknown>;

/** Suggestions envoyées depuis le profil ; l'équipe les lit et les traite dans le back office. */
@Injectable()
export class FeedbackService {
  constructor(private readonly dbs: DbService) {}

  async send(
    userId: string,
    input: { kind: FeedbackKind; message: string; businessId?: string | null; appVersion?: string | null },
  ) {
    return this.dbs.transaction(async (tx) => {
      // L'entreprise n'est gardée que si l'expéditeur en est membre
      let businessId: string | null = null;
      if (input.businessId) {
        const m = await tx.execute(sql`
          SELECT 1 FROM core.memberships
          WHERE business_id = ${input.businessId} AND user_id = ${userId} AND status = 'active'`);
        if (m.rows.length) businessId = input.businessId;
      }
      // Pas plus de 20 suggestions par jour et par personne
      const today = (
        await tx.execute(sql`
          SELECT count(*)::int AS n FROM core.feedback
          WHERE user_id = ${userId} AND created_at > now() - interval '1 day'`)
      ).rows[0] as { n: number };
      if (today.n >= 20)
        throw new AppError('RATE_LIMITED', 'Merci ! Vous avez déjà envoyé beaucoup de messages aujourd’hui', 429);
      const id = newId();
      await tx.execute(sql`
        INSERT INTO core.feedback (id, user_id, business_id, kind, message, app_version)
        VALUES (${id}, ${userId}, ${businessId}, ${input.kind}, ${input.message}, ${input.appVersion ?? null})`);
      return { id };
    });
  }

  async list(q: { status?: FeedbackStatus; page?: number; pageSize?: number }) {
    const page = q.page ?? 1;
    const size = q.pageSize ?? 30;
    const where = q.status ? sql`WHERE f.status = ${q.status}` : sql``;
    const [items, counts] = await this.dbs.transaction(async (tx) =>
      Promise.all([
        tx.execute(sql`
          SELECT f.id, f.kind, f.message, f.status, f.app_version AS "appVersion", f.created_at AS "createdAt",
                 u.full_name AS "userName", u.phone AS "userPhone",
                 b.id AS "businessId", b.name AS "businessName", b.category, b.country
          FROM core.feedback f
          JOIN core.users u ON u.id = f.user_id
          LEFT JOIN core.businesses b ON b.id = f.business_id
          ${where}
          ORDER BY f.created_at DESC
          LIMIT ${size} OFFSET ${(page - 1) * size}`),
        tx.execute(sql`SELECT status, count(*)::int AS n FROM core.feedback GROUP BY status`),
      ]),
    );
    const by = Object.fromEntries((counts.rows as Row[]).map((r) => [r.status as string, r.n as number]));
    return {
      items: items.rows,
      counts: { new: by.new ?? 0, read: by.read ?? 0, done: by.done ?? 0 },
      page,
      pageSize: size,
    };
  }

  async setStatus(id: string, status: FeedbackStatus) {
    const r = await this.dbs.transaction((tx) =>
      tx.execute(sql`UPDATE core.feedback SET status = ${status}, updated_at = now() WHERE id = ${id} RETURNING id`),
    );
    if (!r.rows.length) throw new AppError('NOT_FOUND', 'Suggestion introuvable', 404);
    return { id, status };
  }

  async newCount() {
    const r = await this.dbs.transaction((tx) =>
      tx.execute(sql`SELECT count(*)::int AS n FROM core.feedback WHERE status = 'new'`),
    );
    return (r.rows[0] as { n: number }).n;
  }
}
