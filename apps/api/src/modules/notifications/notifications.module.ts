import { Module } from '@nestjs/common';
import { NotificationsController } from './notifications.controller';
import { NotificationEventHandlers } from './notifications.events';
import { NotificationsService } from './notifications.service';
import { PushController } from './push.controller';
import { PushService } from './push.service';

@Module({
  controllers: [NotificationsController, PushController],
  providers: [NotificationsService, NotificationEventHandlers, PushService],
  exports: [NotificationsService, PushService],
})
export class NotificationsModule {}
