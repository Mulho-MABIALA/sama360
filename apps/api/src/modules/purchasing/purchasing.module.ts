import { Module } from '@nestjs/common';
import { AssistantModule } from '../assistant/assistant.module';
import { InventoryModule } from '../inventory/inventory.module';
import { InvoiceScanService } from './invoice-scan.service';
import { PurchasingController } from './purchasing.controller';
import { PurchasingService } from './purchasing.service';

@Module({
  imports: [InventoryModule, AssistantModule],
  controllers: [PurchasingController],
  providers: [PurchasingService, InvoiceScanService],
})
export class PurchasingModule {}
