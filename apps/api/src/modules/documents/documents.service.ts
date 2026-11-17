import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { FilesService } from '../files/files.service';
import { daysUntil, DocumentCategory, expiryStatus } from './documents';

type Row = Record<string, unknown>;

export interface DocumentInput {
  title: string;
  category: DocumentCategory;
  note?: string | null;
  expiresOn?: string | null;
}

@Injectable()
export class DocumentsService {
  constructor(
    private readonly dbs: DbService,
    private readonly files: FilesService,
  ) {}

  private toDto(r: Row) {
    const expiresOn = r.expires_on ? String(r.expires_on).slice(0, 10) : null;
    const days = daysUntil(expiresOn);
    return {
      id: String(r.id),
      title: String(r.title),
      category: String(r.category),
      note: (r.note as string | null) ?? null,
      expiresOn,
      expiresInDays: days,
      expiry: expiryStatus(days),
      mime: String(r.mime),
      size: Number(r.size),
      createdAt: new Date(String(r.created_at)).toISOString(),
      createdByName: (r.created_by_name as string | null) ?? null,
    };
  }

  private select = sql`
    SELECT d.id, d.title, d.category, d.note, to_char(d.expires_on, 'YYYY-MM-DD') AS expires_on, d.created_at,
           f.mime, f.size, u.full_name AS created_by_name
    FROM core.documents d
    JOIN core.files f ON f.id = d.file_id
    LEFT JOIN core.users u ON u.id = d.created_by`;

  list(businessId: string, q: { category?: string; search?: string }) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const rows = (
        await tx.execute(sql`${this.select}
          WHERE d.deleted_at IS NULL
            ${q.category ? sql`AND d.category = ${q.category}` : sql``}
            ${q.search ? sql`AND (d.title ILIKE ${'%' + q.search + '%'} OR d.note ILIKE ${'%' + q.search + '%'})` : sql``}
          ORDER BY d.created_at DESC, d.id DESC LIMIT 300`)
      ).rows as Row[];
      const counts = (
        await tx.execute(sql`SELECT category, count(*)::int AS n FROM core.documents
          WHERE deleted_at IS NULL GROUP BY category`)
      ).rows as { category: string; n: number }[];
      const items = rows.map((r) => this.toDto(r));
      const all = (
        await tx.execute(sql`SELECT to_char(expires_on, 'YYYY-MM-DD') AS e FROM core.documents
          WHERE deleted_at IS NULL AND expires_on IS NOT NULL`)
      ).rows as { e: string }[];
      return {
        items,
        counts: Object.fromEntries(counts.map((c) => [c.category, Number(c.n)])),
        total: counts.reduce((s, c) => s + Number(c.n), 0),
        // Échéances à surveiller (dépassées ou dans les 30 jours), toutes catégories
        attention: all.filter((x) => expiryStatus(daysUntil(x.e)) !== null).length,
      };
    });
  }

  private async findIn(tx: Tx, id: string) {
    const r = (await tx.execute(sql`${this.select} WHERE d.id = ${id} AND d.deleted_at IS NULL`)).rows[0] as
      Row | undefined;
    if (!r) throw AppError.notFound('Document');
    return r;
  }

  get(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => this.toDto(await this.findIn(tx, id)));
  }

  create(businessId: string, userId: string, input: DocumentInput, data: Buffer) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const file = await this.files.saveDocument(tx, { businessId, data, createdBy: userId });
      const id = newId();
      await tx.execute(sql`
        INSERT INTO core.documents (id, business_id, title, category, file_id, note, expires_on, created_by)
        VALUES (${id}, ${businessId}, ${input.title}, ${input.category}, ${file.id}, ${input.note ?? null},
                ${input.expiresOn ?? null}, ${userId})`);
      return this.toDto(await this.findIn(tx, id));
    });
  }

  update(businessId: string, id: string, input: Partial<DocumentInput>) {
    return this.dbs.withTenant(businessId, async (tx) => {
      await this.findIn(tx, id);
      await tx.execute(sql`
        UPDATE core.documents SET
          title = ${input.title === undefined ? sql`title` : input.title},
          category = ${input.category === undefined ? sql`category` : input.category},
          note = ${input.note === undefined ? sql`note` : input.note},
          expires_on = ${input.expiresOn === undefined ? sql`expires_on` : sql`${input.expiresOn}::date`},
          updated_at = now()
        WHERE id = ${id}`);
      return this.toDto(await this.findIn(tx, id));
    });
  }

  /** Suppression définitive : la fiche et le fichier (rien de sensible ne reste stocké). */
  remove(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const r = (
        await tx.execute(sql`DELETE FROM core.documents WHERE id = ${id} AND deleted_at IS NULL RETURNING file_id`)
      ).rows[0] as { file_id: string } | undefined;
      if (!r) throw AppError.notFound('Document');
      await this.files.remove(tx, r.file_id);
    });
  }

  /** Fichier du document, après contrôle de l'entreprise (RLS) et des droits (contrôleur). */
  file(businessId: string, id: string) {
    return this.dbs.withTenant(businessId, async (tx) => {
      const r = (
        await tx.execute(
          sql`SELECT d.title, d.file_id FROM core.documents d WHERE d.id = ${id} AND d.deleted_at IS NULL`,
        )
      ).rows[0] as { title: string; file_id: string } | undefined;
      if (!r) throw AppError.notFound('Document');
      const f = await this.files.openPrivate(tx, r.file_id);
      if (!f) throw AppError.notFound('Fichier');
      return { ...f, title: r.title };
    });
  }
}
