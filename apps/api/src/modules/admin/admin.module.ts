import { Module } from '@nestjs/common';
import { BillingModule } from '../billing/billing.module';
import { CoreModule } from '../core/core.module';
import { AdminController } from './admin.controller';
import { AdminService } from './admin.service';
import { FeedbackController } from './feedback.controller';
import { FeedbackService } from './feedback.service';

@Module({
  imports: [BillingModule, CoreModule],
  controllers: [AdminController, FeedbackController],
  providers: [AdminService, FeedbackService],
})
export class AdminModule {}
