import { Controller, Get, Param, ParseUUIDPipe, Res } from '@nestjs/common';
import type { Response } from 'express';
import { Public } from '../../shared/auth/decorators';
import { AppError } from '../../shared/http/app-error';
import { FilesService } from './files.service';

@Controller('v1/files')
export class FilesController {
  constructor(private readonly filesService: FilesService) {}

  /**
   * Sert un fichier par son identifiant. Public : les photos de produits s'affichent
   * aussi dans la boutique en ligne. Les identifiants (UUID v7) ne sont pas devinables.
   * Un fichier ne change jamais (une nouvelle photo = un nouvel identifiant) : cache long.
   */
  @Public()
  @Get(':id')
  async get(@Param('id', ParseUUIDPipe) id: string, @Res() res: Response) {
    const file = await this.filesService.open(id);
    if (!file) throw AppError.notFound('Fichier');
    res.setHeader('Content-Type', file.mime);
    res.setHeader('Content-Length', String(file.size));
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');
    file.stream.on('error', () => res.destroy());
    file.stream.pipe(res);
  }
}
