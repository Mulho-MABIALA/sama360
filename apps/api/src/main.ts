import 'reflect-metadata';
import { loadDotenv } from './shared/config/load-dotenv';
loadDotenv();

import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { EventWorkerService } from './shared/events/event-worker.service';
import { OutboxRelayService } from './shared/events/outbox-relay.service';
import { env } from './shared/config/env';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

async function bootstrap() {
  const e = env();
  if (e.MIGRATE_ON_START) {
    // Un seul service (l'API) applique les migrations, avant d'accepter des requêtes.
    const { migrate } = await import('./shared/db/migrate');
    await migrate(e.DATABASE_URL_DIRECT ?? e.DATABASE_URL, (m) => Logger.log(m, 'Migrations'));
  }
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: false,
    // Corps brut gardé pour vérifier la signature des webhooks (Chariow)
    rawBody: true,
  });
  // Derrière Render, Caddy… : l'IP réelle du client (limite de requêtes par personne, pas par proxy)
  if (e.TRUST_PROXY > 0) app.set('trust proxy', e.TRUST_PROXY);
  app.enableCors({ origin: true, credentials: true });
  app.enableShutdownHooks();
  serveWebApp(app, e.WEB_APP_DIR);
  await app.listen(e.PORT, '0.0.0.0');
  if (e.RUN_WORKER) {
    // Petit hébergement : le worker vit dans le même process (sinon : node dist/worker.js à part)
    app.get(OutboxRelayService).start();
    app.get(EventWorkerService).start();
    Logger.log('Worker intégré démarré (RUN_WORKER=true)', 'Bootstrap');
  }
  Logger.log(`API Sama360 prête sur le port ${e.PORT} (${e.NODE_ENV})`, 'Bootstrap');
}

/**
 * Version web de l'app sur /app (tests sur iPhone : Safari → « Sur l'écran d'accueil »).
 * Servie seulement si le dossier construit existe (builds/web à la racine du projet).
 */
function serveWebApp(app: NestExpressApplication, dir?: string) {
  const root = dir ? resolve(dir) : resolve(process.cwd(), '../../builds/web');
  if (!existsSync(join(root, 'index.html'))) return;
  app.use(
    '/app',
    (req: { originalUrl: string }, res: { redirect: (c: number, u: string) => void }, next: () => void) =>
      req.originalUrl === '/app' ? res.redirect(301, '/app/') : next(),
  );
  app.useStaticAssets(root, {
    prefix: '/app/',
    index: 'index.html',
    // index.html et le chargeur toujours frais, le reste en cache (noms changés à chaque version)
    setHeaders: (res, path) => {
      if (/(index\.html|flutter_bootstrap\.js|flutter_service_worker\.js|manifest\.json|version\.json)$/.test(path)) {
        res.setHeader('Cache-Control', 'no-cache');
      }
    },
  });
  Logger.log(`Version web de l'app servie sur /app (${root})`, 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error(err);
  process.exit(1);
});
