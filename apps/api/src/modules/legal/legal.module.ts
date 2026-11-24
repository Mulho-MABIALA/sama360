import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { CoreModule } from '../core/core.module';
import { LegalController } from './legal.controller';

@Module({ imports: [AuthModule, CoreModule], controllers: [LegalController] })
export class LegalModule {}
