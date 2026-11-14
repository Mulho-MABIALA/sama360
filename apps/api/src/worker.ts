import 'reflect-metadata';
import { loadDotenv } from './shared/config/load-dotenv';
loadDotenv();

import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { EventWorkerService } from './shared/events/event-worker.service';
import { OutboxRelayService } from './shared/events/outbox-relay.service';

/**
 * Process séparé de l'API : relaie l'outbox vers Redis et exécute les abonnés.
 * Peut tourner en plusieurs exemplaires (FOR UPDATE SKIP LOCKED + jobs idempotents).
 */
async function bootstrap() {
  const app = await NestFactory.createApplicationContext(AppModule);
  app.enableShutdownHooks();
  app.get(OutboxRelayService).start();
  app.get(EventWorkerService).start();
  Logger.log('Worker Sama360 démarré', 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error(err);
  process.exit(1);
});
