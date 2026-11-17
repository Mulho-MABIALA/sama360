import { Global, Module } from '@nestjs/common';
import { FilesController } from './files.controller';
import { FilesService } from './files.service';
import { env } from '../../shared/config/env';
import { FileStorage, LocalDiskStorage, S3Storage } from './storage';

@Global()
@Module({
  controllers: [FilesController],
  providers: [
    FilesService,
    {
      provide: FileStorage,
      useFactory: () => (env().STORAGE_DRIVER === 's3' ? new S3Storage() : new LocalDiskStorage()),
    },
  ],
  exports: [FilesService],
})
export class FilesModule {}
