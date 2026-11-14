import { Module } from '@nestjs/common';
import { BusinessesService } from './businesses.service';
import { CoreController } from './core.controller';
import { MembersService } from './members.service';

@Module({
  controllers: [CoreController],
  providers: [BusinessesService, MembersService],
  exports: [BusinessesService, MembersService],
})
export class CoreModule {}
