import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { ReportsController } from './reports.controller';
import { SalesController } from './sales.controller';
import { SalesService } from './sales.service';

@Module({
  imports: [InventoryModule],
  controllers: [SalesController, ReportsController],
  providers: [SalesService],
})
export class SalesModule {}
