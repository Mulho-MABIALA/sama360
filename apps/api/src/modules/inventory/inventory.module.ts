import { Module } from '@nestjs/common';
import { InventoryController } from './inventory.controller';
import { InventoryEventHandlers } from './inventory.events';
import { InventoryService } from './inventory.service';

@Module({
  controllers: [InventoryController],
  providers: [InventoryService, InventoryEventHandlers],
  // Exporté pour que les ventes connaissent l'entrepôt par défaut (lecture seule).
  exports: [InventoryService],
})
export class InventoryModule {}
