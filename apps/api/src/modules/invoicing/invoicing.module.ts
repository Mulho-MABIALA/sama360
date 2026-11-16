import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { InvoicingController } from './invoicing.controller';
import { InvoicingService } from './invoicing.service';

@Module({
  imports: [InventoryModule],
  controllers: [InvoicingController],
  providers: [InvoicingService],
})
export class InvoicingModule {}
