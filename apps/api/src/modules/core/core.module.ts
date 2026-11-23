import { Module } from '@nestjs/common';
import { FilesModule } from '../files/files.module';
import { BusinessesService } from './businesses.service';
import { ClosureController } from './closure.controller';
import { ClosureService } from './closure.service';
import { CoreController } from './core.controller';
import { MembersService } from './members.service';

@Module({
  imports: [FilesModule],
  controllers: [CoreController, ClosureController],
  providers: [BusinessesService, MembersService, ClosureService],
  exports: [BusinessesService, MembersService, ClosureService],
})
export class CoreModule {}
