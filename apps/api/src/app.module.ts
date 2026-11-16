import { Controller, Get, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { sql } from 'drizzle-orm';
import { CatalogModule } from './modules/catalog/catalog.module';
import { ContactsModule } from './modules/contacts/contacts.module';
import { AuthModule } from './modules/auth/auth.module';
import { CoreModule } from './modules/core/core.module';
import { FilesModule } from './modules/files/files.module';
import { InventoryModule } from './modules/inventory/inventory.module';
import { SalesModule } from './modules/sales/sales.module';
import { InvoicingModule } from './modules/invoicing/invoicing.module';
import { PurchasingModule } from './modules/purchasing/purchasing.module';
import { NotificationsModule } from './modules/notifications/notifications.module';
import { Public } from './shared/auth/decorators';
import { JwtAuthGuard } from './shared/auth/jwt-auth.guard';
import { DbModule } from './shared/db/db.module';
import { DbService } from './shared/db/db.service';
import { EventsModule } from './shared/events/events.module';
import { AllExceptionsFilter } from './shared/http/all-exceptions.filter';
import { TenantGuard } from './shared/tenant/tenant.guard';

@Controller()
class HealthController {
  constructor(private readonly dbs: DbService) {}

  @Public()
  @Get('health')
  async health() {
    await this.dbs.db.execute(sql`select 1`);
    return { status: 'ok', db: 'ok' };
  }
}

@Module({
  imports: [
    ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 120 }]),
    DbModule,
    EventsModule,
    FilesModule,
    AuthModule,
    CoreModule,
    ContactsModule,
    CatalogModule,
    InventoryModule,
    SalesModule,
    InvoicingModule,
    PurchasingModule,
    NotificationsModule,
  ],
  controllers: [HealthController],
  providers: [
    // Ordre des gardes : limitation de débit → jeton → entreprise/permissions
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    { provide: APP_GUARD, useClass: TenantGuard },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
})
export class AppModule {}
