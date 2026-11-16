import { Module } from '@nestjs/common';
import { NotificationsController } from './notifications.controller';
import { NotificationEventHandlers } from './notifications.events';
import { NotificationsService } from './notifications.service';

@Module({
  controllers: [NotificationsController],
  providers: [NotificationsService, NotificationEventHandlers],
  exports: [NotificationsService],
})
export class NotificationsModule {}
