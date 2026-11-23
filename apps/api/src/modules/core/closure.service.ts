import { Injectable, Logger, OnApplicationShutdown } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { TenantContext } from '../../shared/auth/auth.types';
import { DbService } from '../../shared/db/db.service';
import { AppError } from '../../shared/http/app-error';
import { FilesService } from '../files/files.service';

type Row = Record<string, unknown>;

/** Jours pour changer d'avis après une suppression (boutique ou compte). */
export const GRACE_DAYS = 30;
const DAY = 86_400_000;

/** Mot à taper pour supprimer son compte. */
export const ACCOUNT_CONFIRM_WORD = 'SUPPRIMER';

const purgeAt = (deletedAt: Date | string) => new Date(new Date(deletedAt).getTime() + GRACE_DAYS * DAY);

/** Comparaison souple du nom tapé pour confirmer (casse, accents, espaces). */
export function sameName(a: string, b: string): boolean {
  const n = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
  return n(a) !== '' && n(a) === n(b);
}

/**
 * Suppression d'une boutique ou d'un compte : douce d'abord (30 jours pour revenir en arrière),
 * puis effacement définitif par [purgeExpired].
 */
@Injectable()
export class ClosureService implements OnApplicationShutdown {
  private readonly log = new Logger('Suppression');
  private timer?: NodeJS.Timeout;

  constructor(
    private readonly dbs: DbService,
    private readonly files: FilesService,
  ) {}

  // ─────────────────────────────── boutique

  /** Le propriétaire supprime sa boutique : invisible tout de suite pour toute l'équipe et en ligne. */
  async deleteBusiness(t: TenantContext, userId: string, confirmName: string, now = new Date()) {
    if (t.roleKey !== 'owner') throw AppError.forbidden('Seul le propriétaire peut supprimer la boutique');
    return this.dbs.transaction(async (tx) => {
      const b = (
        await tx.execute(sql`
          SELECT name, owner_id FROM core.businesses WHERE id = ${t.businessId} AND deleted_at IS NULL FOR UPDATE`)
      ).rows[0] as Row | undefined;
      if (!b || b.owner_id !== userId) throw AppError.forbidden('Seul le propriétaire peut supprimer la boutique');
      if (!sameName(confirmName, b.name as string)) {
        throw new AppError('VALIDATION_FAILED', 'Le nom tapé ne correspond pas au nom de la boutique', 422);
      }
      await tx.execute(sql`
        UPDATE core.businesses
           SET deleted_at = ${now}, deleted_by = ${userId}, deleted_with_account = false, updated_at = ${now}
         WHERE id = ${t.businessId}`);
      this.log.log(`Boutique ${t.businessId} supprimée par ${userId} (effacement le ${purgeAt(now).toISOString()})`);
      return { deleted: true, purgeAt: purgeAt(now).toISOString() };
    });
  }

  /** Boutiques supprimées par cet utilisateur et encore restaurables. */
  async deletedBusinesses(userId: string, now = new Date()) {
    const rows = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT id, name, deleted_at FROM core.businesses
           WHERE owner_id = ${userId} AND deleted_at IS NOT NULL AND NOT deleted_with_account
             AND deleted_at > ${new Date(now.getTime() - GRACE_DAYS * DAY)}
           ORDER BY deleted_at DESC`),
      )
    ).rows as Row[];
    return rows.map((r) => {
      const end = purgeAt(r.deleted_at as string);
      return {
        id: r.id as string,
        name: r.name as string,
        deletedAt: new Date(r.deleted_at as string).toISOString(),
        purgeAt: end.toISOString(),
        daysLeft: Math.max(1, Math.ceil((end.getTime() - now.getTime()) / DAY)),
      };
    });
  }

  async restoreBusiness(userId: string, businessId: string, now = new Date()) {
    const r = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          UPDATE core.businesses
             SET deleted_at = NULL, deleted_by = NULL, deleted_with_account = false, updated_at = ${now}
           WHERE id = ${businessId} AND owner_id = ${userId} AND deleted_at IS NOT NULL
             AND deleted_at > ${new Date(now.getTime() - GRACE_DAYS * DAY)}
           RETURNING id, name`),
      )
    ).rows[0] as Row | undefined;
    if (!r) throw AppError.notFound('Boutique à restaurer');
    this.log.log(`Boutique ${businessId} restaurée par ${userId}`);
    return { id: r.id as string, name: r.name as string };
  }

  // ─────────────────────────────── compte

  /**
   * L'utilisateur supprime son compte : ses boutiques sont supprimées avec lui, il quitte les équipes
   * des autres, toutes ses sessions sont fermées. Se reconnecter dans les 30 jours annule tout.
   */
  async deleteAccount(userId: string, confirm: string, now = new Date()) {
    if (confirm.trim().toUpperCase() !== ACCOUNT_CONFIRM_WORD) {
      throw new AppError('VALIDATION_FAILED', `Tapez ${ACCOUNT_CONFIRM_WORD} pour confirmer`, 422);
    }
    return this.dbs.transaction(async (tx) => {
      const owned = (
        await tx.execute(sql`
          UPDATE core.businesses
             SET deleted_at = ${now}, deleted_by = ${userId}, deleted_with_account = true, updated_at = ${now}
           WHERE owner_id = ${userId} AND deleted_at IS NULL
           RETURNING id`)
      ).rows.length;
      await tx.execute(sql`
        UPDATE core.memberships m SET status = 'removed'
          FROM core.businesses b
         WHERE m.business_id = b.id AND m.user_id = ${userId} AND b.owner_id <> ${userId}
           AND m.status IN ('active', 'invited')`);
      await tx.execute(sql`UPDATE core.users SET deleted_at = ${now}, updated_at = ${now} WHERE id = ${userId}`);
      await tx.execute(sql`
        UPDATE core.refresh_tokens SET revoked_at = ${now} WHERE user_id = ${userId} AND revoked_at IS NULL`);
      // Plus de notifications sur ses téléphones
      await tx.execute(sql`DELETE FROM core.push_tokens WHERE user_id = ${userId}`);
      this.log.log(`Compte ${userId} supprimé (${owned} boutique(s)) ; effacement le ${purgeAt(now).toISOString()}`);
      return { deleted: true, businesses: owned, purgeAt: purgeAt(now).toISOString() };
    });
  }

  // ─────────────────────────────── effacement définitif

  /** Efface ce qui a dépassé les 30 jours. Appelé au démarrage puis toutes les 6 heures (worker). */
  async purgeExpired(now = new Date()) {
    const limit = new Date(now.getTime() - GRACE_DAYS * DAY);
    let businesses = 0;
    let users = 0;
    let objects = 0;

    const due = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`SELECT id FROM core.businesses WHERE deleted_at IS NOT NULL AND deleted_at <= ${limit}`),
      )
    ).rows as Row[];
    for (const { id } of due) {
      const businessId = id as string;
      try {
        // Les octets des fichiers (logos, photos, documents) d'abord listés, puis effacés après la base
        const keys = (
          await this.dbs.withTenant(businessId, (tx) =>
            tx.execute(sql`SELECT storage_key FROM core.files WHERE business_id = ${businessId}`),
          )
        ).rows.map((r) => (r as Row).storage_key as string);
        await this.dbs.transaction(async (tx) => {
          await tx.execute(sql`UPDATE core.businesses SET referred_by = NULL WHERE referred_by = ${businessId}`);
          await tx.execute(sql`DELETE FROM core.businesses WHERE id = ${businessId} AND deleted_at <= ${limit}`);
        });
        objects += await this.files.deleteObjects(keys);
        businesses++;
      } catch (e) {
        this.log.error(`Effacement de la boutique ${businessId} impossible : ${(e as Error).message}`);
      }
    }

    // Comptes : rendus anonymes (leurs ventes passées restent dans les boutiques des autres)
    const gone = (
      await this.dbs.transaction((tx) =>
        tx.execute(sql`
          SELECT u.id, f.storage_key FROM core.users u LEFT JOIN core.files f ON f.id = u.avatar_file_id
           WHERE u.deleted_at IS NOT NULL AND u.deleted_at <= ${limit} AND u.status <> 'deleted'`),
      )
    ).rows as Row[];
    for (const u of gone) {
      const userId = u.id as string;
      try {
        await this.dbs.transaction(async (tx) => {
          await tx.execute(sql`DELETE FROM core.memberships WHERE user_id = ${userId}`);
          await tx.execute(sql`DELETE FROM core.refresh_tokens WHERE user_id = ${userId}`);
          await tx.execute(sql`
            UPDATE core.users
               SET phone = ${`deleted:${userId}`}, full_name = NULL, email = NULL, pin_hash = NULL,
                   avatar_file_id = NULL, status = 'deleted', updated_at = ${now}
             WHERE id = ${userId}`);
          await tx.execute(sql`DELETE FROM core.files WHERE created_by = ${userId} AND business_id IS NULL`);
        });
        if (u.storage_key) objects += await this.files.deleteObjects([u.storage_key as string]);
        users++;
      } catch (e) {
        this.log.error(`Effacement du compte ${userId} impossible : ${(e as Error).message}`);
      }
    }
    if (businesses || users) {
      this.log.log(`Effacement définitif : ${businesses} boutique(s), ${users} compte(s), ${objects} fichier(s)`);
    }
    return { businesses, users, objects };
  }

  /** Worker : un premier passage peu après le démarrage, puis toutes les 6 heures. */
  startPurge() {
    const run = () => this.purgeExpired().catch((e) => this.log.error(`Effacement : ${(e as Error).message}`));
    setTimeout(run, 30_000).unref();
    this.timer = setInterval(run, 6 * 3600_000);
    this.timer.unref();
  }

  onApplicationShutdown() {
    if (this.timer) clearInterval(this.timer);
  }
}
