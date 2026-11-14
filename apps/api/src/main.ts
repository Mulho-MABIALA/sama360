import 'reflect-metadata';
import { loadDotenv } from './shared/config/load-dotenv';
loadDotenv();

import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { env } from './shared/config/env';

async function bootstrap() {
  const e = env();
  const app = await NestFactory.create(AppModule, { bufferLogs: false });
  app.enableCors({ origin: true, credentials: true });
  app.enableShutdownHooks();
  await app.listen(e.PORT);
  Logger.log(`API Sama360 prête sur http://localhost:${e.PORT}`, 'Bootstrap');
}

bootstrap().catch((err) => {
  console.error(err);
  process.exit(1);
});
