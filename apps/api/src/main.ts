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

async function bootstrap() {
  const e = env();
  if (e.MIGRATE_ON_START) {
    // Un seul service (l'API) applique les migrations, avant d'accepter des requêtes.
    const { migrate } = await import('./shared/db/migrate');
    await migrate(e.DATABASE_URL_DIRECT ?? e.DATABASE_URL, (m) => Logger.log(m, 'Migrations'));
  }
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: false,
  });
  // Derrière Render, Caddy… : l'IP réelle du client (limite de requêtes par personne, pas par proxy)
  if (e.TRUST_PROXY > 0) app.set('trust proxy', e.TRUST_PROXY);
  app.enableCors({ origin: true, credentials: true });
  app.enableShutdownHooks();
  await app.listen(e.PORT, '0.0.0.0');
  if (e.RUN_WORKER) {
    // Petit hébergement : le worker vit dans le même process (sinon : node dist/worker.js à part)
    app.get(OutboxRelayService).start();
    app.get(EventWorkerService).start();
    Logger.log('Worker intégré démarré (RUN_WORKER=true)', 'Bootstrap');
  }
  Logger.log(`API Sama360 prête sur le port ${e.PORT} (${e.NODE_ENV})`, 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error(err);
  process.exit(1);
});
