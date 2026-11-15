import { Injectable } from '@nestjs/common';
import { createReadStream, existsSync } from 'node:fs';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import type { Readable } from 'node:stream';
import { env } from '../../shared/config/env';

/**
 * Où vivent les octets des fichiers. Une implémentation par fournisseur :
 * disque local (développement, VPS) aujourd'hui ; S3 / Cloudflare R2 ensuite,
 * sans rien changer au reste du code.
 */
export abstract class FileStorage {
  abstract put(key: string, data: Buffer, mime: string): Promise<void>;
  abstract get(key: string): Promise<Readable | null>;
  abstract delete(key: string): Promise<void>;
}

@Injectable()
export class LocalDiskStorage extends FileStorage {
  private readonly root = resolve(env().STORAGE_DIR ?? join(__dirname, '../../../storage'));

  /** Empêche toute clé de sortir du dossier de stockage. */
  private path(key: string): string {
    if (!/^[a-z0-9/_.-]+$/i.test(key) || key.includes('..')) throw new Error('Clé de stockage invalide');
    const full = resolve(this.root, key);
    if (!full.startsWith(this.root + sep)) throw new Error('Clé de stockage invalide');
    return full;
  }

  async put(key: string, data: Buffer): Promise<void> {
    const full = this.path(key);
    await mkdir(dirname(full), { recursive: true });
    await writeFile(full, data);
  }

  async get(key: string): Promise<Readable | null> {
    const full = this.path(key);
    return existsSync(full) ? createReadStream(full) : null;
  }

  async delete(key: string): Promise<void> {
    await rm(this.path(key), { force: true });
  }
}
