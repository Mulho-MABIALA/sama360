import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
  Res,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import { z } from 'zod';
import type { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequireModule, RequirePermission, RequirePro } from '../../shared/auth/decorators';
import { env } from '../../shared/config/env';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { DOCUMENT_CATEGORIES, downloadName } from './documents';
import { DocumentsService } from './documents.service';

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'date au format AAAA-MM-JJ');
const Fields = z.object({
  title: z.string().trim().min(2).max(120),
  category: z.enum(DOCUMENT_CATEGORIES),
  note: z.string().trim().max(1000).nullish(),
  expiresOn: day.nullish(),
});
// Envoi multipart : les champs arrivent en texte (« '' » = vide)
const blankToNull = (v: unknown) => (v === '' ? null : v);
const CreateFields = z.object({
  title: Fields.shape.title,
  category: Fields.shape.category,
  note: z.preprocess(blankToNull, Fields.shape.note),
  expiresOn: z.preprocess(blankToNull, Fields.shape.expiresOn),
});
const ListQuery = z.object({
  category: z.enum(DOCUMENT_CATEGORIES).optional(),
  search: z.string().trim().max(80).optional(),
});

/** Documents du commerce : registre, NINEA, factures fournisseurs, contrats, bons de livraison… */
@Controller('v1/documents')
@RequireModule('documents')
export class DocumentsController {
  constructor(private readonly documents: DocumentsService) {}

  @Get()
  @RequirePermission('documents:read')
  list(@CurrentTenant() t: TenantContext, @Query() query: unknown) {
    return this.documents.list(t.businessId, parse(ListQuery, query));
  }

  @Get(':id')
  @RequirePermission('documents:read')
  get(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    return this.documents.get(t.businessId, id);
  }

  /** Le fichier lui-même : seulement pour les membres autorisés, jamais mis en cache public. */
  @Get(':id/file')
  @RequirePermission('documents:read')
  async file(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Res() res: Response) {
    const f = await this.documents.file(t.businessId, id);
    res.setHeader('Content-Type', f.mime);
    res.setHeader('Content-Length', String(f.size));
    res.setHeader('Content-Disposition', `inline; filename="${downloadName(f.title, f.mime)}"`);
    res.setHeader('Cache-Control', 'private, no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    f.stream.on('error', () => res.destroy());
    f.stream.pipe(res);
  }

  /** Ajout (multipart) : champ « file » (photo ou PDF) + title, category, note, expiresOn. */
  @Post()
  @RequirePro('documents')
  @RequirePermission('documents:write')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 25 * 1024 * 1024, files: 1 } }))
  create(
    @CurrentTenant() t: TenantContext,
    @CurrentUser() user: AuthUser,
    @Body() body: unknown,
    @UploadedFile() file?: { buffer: Buffer; size: number },
  ) {
    const input = parse(CreateFields, body);
    if (!file?.buffer?.length)
      throw new AppError('VALIDATION_FAILED', 'Ajoutez une photo ou un PDF (champ « file »)', 422);
    const maxMb = env().MAX_UPLOAD_MB;
    if (file.size > maxMb * 1024 * 1024) {
      throw new AppError('PAYLOAD_TOO_LARGE', `Fichier trop lourd (maximum ${maxMb} Mo)`, 413);
    }
    return this.documents.create(t.businessId, user.id, input, file.buffer);
  }

  @Patch(':id')
  @RequirePro('documents')
  @RequirePermission('documents:write')
  update(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string, @Body() body: unknown) {
    return this.documents.update(t.businessId, id, parse(Fields.partial(), body));
  }

  @Delete(':id')
  @HttpCode(204)
  @RequirePermission('documents:write')
  async remove(@CurrentTenant() t: TenantContext, @Param('id', ParseUUIDPipe) id: string) {
    await this.documents.remove(t.businessId, id);
  }
}
