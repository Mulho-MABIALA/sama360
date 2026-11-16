import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { CustomersController } from './customers.controller';
import { CustomersService } from './customers.service';
import { ReportsController } from './reports.controller';
import { SalesController } from './sales.controller';
import { SalesService } from './sales.service';

@Module({
  imports: [InventoryModule],
  controllers: [SalesController, ReportsController, CustomersController],
  providers: [SalesService, CustomersService],
  exports: [SalesService],
})
export class SalesModule {}
