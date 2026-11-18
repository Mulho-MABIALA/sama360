import { Module } from '@nestjs/common';
import { InventoryController } from './inventory.controller';
import { InventoryEventHandlers } from './inventory.events';
import { InventoryService } from './inventory.service';
import { LocationsController } from './locations.controller';
import { LocationsService } from './locations.service';

@Module({
  controllers: [InventoryController, LocationsController],
  providers: [InventoryService, InventoryEventHandlers, LocationsService],
  // Exporté pour que les ventes connaissent l'entrepôt par défaut (lecture seule).
  exports: [InventoryService],
})
export class InventoryModule {}
