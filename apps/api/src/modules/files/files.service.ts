import { Injectable, Logger } from '@nestjs/common';
import { eq } from 'drizzle-orm';
import { DbService, Tx } from '../../shared/db/db.service';
import { files } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { detectImage } from './image';
import { FileStorage } from './storage';

@Injectable()
export class FilesService {
  private readonly logger = new Logger(FilesService.name);

  constructor(
    private readonly dbs: DbService,
    private readonly storage: FileStorage,
  ) {}

  /**
   * Enregistre une image (JPEG, PNG, WebP) : octets dans le stockage, métadonnées en base.
   * À appeler dans la transaction métier ; si elle échoue, le fichier orphelin est supprimé.
   */
  async saveImage(tx: Tx, input: { businessId: string; kind: string; data: Buffer; createdBy: string }) {
    const type = detectImage(input.data);
    if (!type) throw new AppError('VALIDATION_FAILED', 'Format non accepté : utilisez une photo JPEG, PNG ou WebP', 422);
    const id = newId();
    const storageKey = `${input.businessId}/${input.kind}/${id}.${type.ext}`;
    await this.storage.put(storageKey, input.data, type.mime);
    try {
      await tx.insert(files).values({
        id,
        businessId: input.businessId,
        kind: input.kind,
        storageKey,
        mime: type.mime,
        size: input.data.length,
        createdBy: input.createdBy,
      });
    } catch (err) {
      await this.storage.delete(storageKey).catch(() => undefined);
      throw err;
    }
    return { id, storageKey, mime: type.mime };
  }

  /** Supprime un fichier (métadonnées dans la transaction, octets ensuite, sans bloquer). */
  async remove(tx: Tx, fileId: string): Promise<void> {
    const [f] = await tx.delete(files).where(eq(files.id, fileId)).returning({ key: files.storageKey });
    if (f) {
      setImmediate(() =>
        this.storage.delete(f.key).catch((e) => this.logger.warn(`Suppression ${f.key} : ${(e as Error).message}`)),
      );
    }
  }

  /** Lecture publique par identifiant (photos de produits). */
  async open(fileId: string) {
    const [f] = await this.dbs.db.select().from(files).where(eq(files.id, fileId)).limit(1);
    if (!f) return null;
    const stream = await this.storage.get(f.storageKey);
    return stream ? { stream, mime: f.mime, size: f.size } : null;
  }
}
