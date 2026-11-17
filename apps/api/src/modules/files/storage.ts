import { DeleteObjectCommand, GetObjectCommand, NoSuchKey, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { Injectable } from '@nestjs/common';
import { createReadStream, existsSync } from 'node:fs';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import type { Readable } from 'node:stream';
import { env } from '../../shared/config/env';

/**
 * Où vivent les octets des fichiers. Une implémentation par fournisseur :
 * disque local (développement, VPS avec volume) ou S3 compatible (Cloudflare R2, AWS S3…),
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

/** Clé autorisée : mêmes règles que sur disque (pas de « .. », caractères simples). */
export function checkKey(key: string): string {
  if (!/^[a-z0-9/_.-]+$/i.test(key) || key.includes('..') || key.startsWith('/')) {
    throw new Error('Clé de stockage invalide');
  }
  return key;
}

/**
 * Stockage S3 compatible. Indispensable chez un hébergeur dont le disque est effacé
 * à chaque déploiement (Render, Railway…). Les fichiers restent privés : l'API les sert.
 */
@Injectable()
export class S3Storage extends FileStorage {
  constructor(
    private readonly client: S3Client = S3Storage.clientFromEnv(),
    private readonly bucket: string = env().S3_BUCKET!,
  ) {
    super();
  }

  static clientFromEnv(): S3Client {
    const e = env();
    return new S3Client({
      region: e.S3_REGION,
      endpoint: e.S3_ENDPOINT,
      forcePathStyle: Boolean(e.S3_ENDPOINT),
      credentials: {
        accessKeyId: e.S3_ACCESS_KEY_ID!,
        secretAccessKey: e.S3_SECRET_ACCESS_KEY!,
      },
    });
  }

  async put(key: string, data: Buffer, mime: string): Promise<void> {
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.bucket,
        Key: checkKey(key),
        Body: data,
        ContentType: mime,
      }),
    );
  }

  async get(key: string): Promise<Readable | null> {
    try {
      const res = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: checkKey(key) }));
      return (res.Body as Readable | undefined) ?? null;
    } catch (err) {
      if (err instanceof NoSuchKey || (err as { name?: string }).name === 'NoSuchKey') return null;
      throw err;
    }
  }

  async delete(key: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: checkKey(key) }));
  }
}
