import { Module } from '@nestjs/common';
import { CatalogController } from './catalog.controller';
import { CatalogEventHandlers } from './catalog.events';

@Module({
  controllers: [CatalogController],
  providers: [CatalogEventHandlers],
})
export class CatalogModule {}
