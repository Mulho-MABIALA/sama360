import { Module } from '@nestjs/common';
import { NotificationEventHandlers } from './notifications.events';

@Module({ providers: [NotificationEventHandlers] })
export class NotificationsModule {}
