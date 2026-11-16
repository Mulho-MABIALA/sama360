import { Module } from '@nestjs/common';
import { FilesModule } from '../files/files.module';
import { BusinessesService } from './businesses.service';
import { CoreController } from './core.controller';
import { MembersService } from './members.service';

@Module({
  imports: [FilesModule],
  controllers: [CoreController],
  providers: [BusinessesService, MembersService],
  exports: [BusinessesService, MembersService],
})
export class CoreModule {}
