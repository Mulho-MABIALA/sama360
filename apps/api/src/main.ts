import 'reflect-metadata';
import { loadDotenv } from './shared/config/load-dotenv';
loadDotenv();

import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { ClosureService } from './modules/core/closure.service';
import { PushService } from './modules/notifications/push.service';
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
  serveWebApp(app, '/app', e.WEB_APP_DIR, '../../builds/web');
  // Back office de l'équipe Sama360 : application à part
  serveWebApp(app, '/admin', e.WEB_ADMIN_DIR, '../../builds/admin');
  await app.listen(e.PORT, '0.0.0.0');
  if (e.RUN_WORKER) {
    // Petit hébergement : le worker vit dans le même process (sinon : node dist/worker.js à part)
    app.get(OutboxRelayService).start();
    app.get(EventWorkerService).start();
    // Boutiques et comptes supprimés depuis plus de 30 jours : effacement définitif
    app.get(ClosureService).startPurge();
    // Notifications sur les téléphones (si Firebase est configuré)
    app.get(PushService).start();
    Logger.log('Worker intégré démarré (RUN_WORKER=true)', 'Bootstrap');
  }
  Logger.log(`API Sama360 prête sur le port ${e.PORT} (${e.NODE_ENV})`, 'Bootstrap');
}

/**
 * Applications web construites avec Flutter, servies seulement si le dossier existe :
 * /app (commerçants ; sur iPhone, Safari → « Sur l'écran d'accueil ») et /admin (équipe Sama360).
 */
function serveWebApp(app: NestExpressApplication, prefix: string, dir: string | undefined, fallback: string) {
  const root = dir ? resolve(dir) : resolve(process.cwd(), fallback);
  if (!existsSync(join(root, 'index.html'))) return;
  app.use(
    prefix,
    (req: { originalUrl: string }, res: { redirect: (c: number, u: string) => void }, next: () => void) =>
      req.originalUrl === prefix ? res.redirect(301, `${prefix}/`) : next(),
  );
  app.useStaticAssets(root, {
    prefix: `${prefix}/`,
    index: 'index.html',
    // index.html et le chargeur toujours frais, le reste en cache (noms changés à chaque version)
    setHeaders: (res, path) => {
      if (/(index\.html|flutter_bootstrap\.js|flutter_service_worker\.js|manifest\.json|version\.json)$/.test(path)) {
        res.setHeader('Cache-Control', 'no-cache');
      }
      // Le back office n'a rien à faire dans les moteurs de recherche
      if (prefix === '/admin') res.setHeader('X-Robots-Tag', 'noindex, nofollow');
    },
  });
  Logger.log(`Application web servie sur ${prefix} (${root})`, 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error(err);
  process.exit(1);
});
