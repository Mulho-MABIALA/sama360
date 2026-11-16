import { Module } from '@nestjs/common';
import { SalesModule } from '../sales/sales.module';
import { ShopController } from './shop.controller';
import { ShopService } from './shop.service';

@Module({
  imports: [SalesModule],
  controllers: [ShopController],
  providers: [ShopService],
})
export class ShopModule {}
