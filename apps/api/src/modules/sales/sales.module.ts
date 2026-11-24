import { Module } from '@nestjs/common';
import { InventoryModule } from '../inventory/inventory.module';
import { CashController } from './cash.controller';
import { CashService } from './cash.service';
import { CustomersController } from './customers.controller';
import { CustomersService } from './customers.service';
import { LoyaltyController } from './loyalty.controller';
import { LoyaltyService } from './loyalty.service';
import { RemindersController } from './reminders.controller';
import { RemindersService } from './reminders.service';
import { InsightsController } from './insights.controller';
import { ReportsController } from './reports.controller';
import { SalesController } from './sales.controller';
import { SalesService } from './sales.service';

@Module({
  imports: [InventoryModule],
  controllers: [
    SalesController,
    ReportsController,
    InsightsController,
    CustomersController,
    CashController,
    RemindersController,
    LoyaltyController,
  ],
  providers: [SalesService, CustomersService, CashService, RemindersService, LoyaltyService],
  exports: [SalesService],
})
export class SalesModule {}
