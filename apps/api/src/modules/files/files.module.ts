import { Global, Module } from '@nestjs/common';
import { FilesController } from './files.controller';
import { FilesService } from './files.service';
import { FileStorage, LocalDiskStorage } from './storage';

@Global()
@Module({
  controllers: [FilesController],
  providers: [FilesService, { provide: FileStorage, useClass: LocalDiskStorage }],
  exports: [FilesService],
})
export class FilesModule {}
