import { Module } from '@nestjs/common';
import { ContactsController } from './contacts.controller';
import { ContactBalanceHandlers } from './contacts.events';

@Module({ controllers: [ContactsController], providers: [ContactBalanceHandlers] })
export class ContactsModule {}
