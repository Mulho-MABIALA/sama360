import { COUNTRY_CODES, MOBILE_MONEY } from '../../shared/countries';
import { FOCUSES } from './onboarding';
import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { z } from 'zod';
import { BIZ_SERVICES } from '../../shared/services';
import { AuthUser, TenantContext } from '../../shared/auth/auth.types';
import { CurrentTenant, CurrentUser, RequirePermission, RequirePro } from '../../shared/auth/decorators';
import { env } from '../../shared/config/env';
import { AppError } from '../../shared/http/app-error';
import { parse } from '../../shared/http/zod';
import { normalizeHex } from '../../shared/color';
import { normalizePhone } from '../../shared/phone';
import { BusinessesService } from './businesses.service';
import { MembersService } from './members.service';

/** Champ facultatif : une saisie vide vaut « rien ». */
const emptyAsNull = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? null : v), schema.nullish());

const text = (max: number) => z.string().trim().min(1).max(max);

const CreateBusiness = z.object({
  name: text(120),
  focus: z.enum(FOCUSES).nullish(),
  category: text(60).nullish(),
  phone: text(25).nullish(),
  city: text(80).nullish(),
  address: text(500).nullish(),
  ninea: text(30).nullish(),
  // Pays : indicatif des numéros, monnaie (XOF / XAF), paiements mobiles
  country: z.enum(COUNTRY_CODES).optional(),
  // Code de parrainage d'un autre commerçant (facultatif)
  referralCode: z.string().trim().max(12).optional(),
});
const UpdateBusiness = CreateBusiness.omit({ referralCode: true })
  .partial()
  .extend({
    // Activité : produits, services ou les deux (adapte l'accueil et les premiers pas)
    focus: z.enum(FOCUSES).optional(),
    // Le patron a masqué la carte « Premiers pas »
    onboardingDismissed: z.boolean().optional(),
    // Services montrés sur l'accueil (selon le métier) ; null = revenir à ceux du métier
    services: z.array(z.enum(BIZ_SERVICES)).max(BIZ_SERVICES.length).nullish(),
    // Couleur de la boutique (« #0A7E4F ») ; null pour revenir au vert Sama360
    brandColor: z
      .string()
      .regex(/^#?[0-9a-fA-F]{6}$/, 'couleur attendue au format #RRGGBB')
      .transform((v) => normalizeHex(v)!)
      .nullish(),
    // Obliger à ouvrir la caisse avant de vendre
    requireOpenCash: z.boolean().optional(),
    // Comptes de paiement mobile du commerçant, montrés au client à la caisse (numéro, lien de paiement)
    payAccounts: z
      .record(
        z.enum(MOBILE_MONEY),
        z.object({
          number: emptyAsNull(
            z
              .string()
              .trim()
              .regex(/^\+?[\d ]{6,20}$/, 'numéro invalide'),
          ),
          link: emptyAsNull(
            z
              .string()
              .trim()
              .max(300)
              .url('lien invalide')
              .refine((v) => v.startsWith('https://'), 'le lien doit commencer par https://'),
          ),
        }),
      )
      .optional(),
  });

const InviteMember = z.object({
  phone: z.string().min(6).max(25),
  fullName: text(120).optional(),
  roleKey: z.enum(['manager', 'cashier', 'accountant']),
  /** Point de vente du membre (vendeur rattaché) ; absent = tous. */
  locationId: z.string().uuid().nullish(),
});
const UpdateMember = z
  .object({
    roleKey: z.enum(['manager', 'cashier', 'accountant']).optional(),
    status: z.enum(['active', 'suspended']).optional(),
    locationId: z.string().uuid().nullable().optional(),
  })
  .refine((v) => v.roleKey || v.status || v.locationId !== undefined, 'roleKey, status ou locationId requis');

@Controller('v1')
export class CoreController {
  constructor(
    private readonly businesses: BusinessesService,
    private readonly members: MembersService,
  ) {}

  /** Créer une entreprise : l'utilisateur en devient propriétaire. */
  @Post('businesses')
  create(@CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(CreateBusiness, body);
    return this.businesses.create(user.id, input);
  }

  /** Entreprise courante (X-Business-Id) avec modules, abonnement et mes droits. */
  @Get('business')
  @RequirePermission('business:read')
  async current(@CurrentTenant() tenant: TenantContext) {
    const data = await this.businesses.getCurrent(tenant.businessId);
    return {
      ...data,
      me: {
        role: tenant.roleKey,
        permissions: tenant.permissions,
        // Point de vente : celui auquel le membre est rattaché (locked), sinon le choix envoyé par l'app
        location: { id: tenant.locationFilter, writeTo: tenant.warehouseId, locked: tenant.locationLocked },
      },
    };
  }

  /** Logo de l'entreprise (JPEG, PNG ou WebP), affiché sur les factures et devis. */
  @Post('business/logo')
  @RequirePermission('business:update')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 20 * 1024 * 1024, files: 1 } }))
  setLogo(
    @CurrentTenant() tenant: TenantContext,
    @CurrentUser() user: AuthUser,
    @UploadedFile() file?: { buffer: Buffer; size: number },
  ) {
    if (!file?.buffer?.length) throw new AppError('VALIDATION_FAILED', 'Ajoutez une image (champ « file »)', 422);
    const maxMb = env().MAX_UPLOAD_MB;
    if (file.size > maxMb * 1024 * 1024) {
      throw new AppError('PAYLOAD_TOO_LARGE', `Image trop lourde (maximum ${maxMb} Mo)`, 413);
    }
    return this.businesses.setLogo(tenant.businessId, user.id, file.buffer);
  }

  @Delete('business/logo')
  @RequirePermission('business:update')
  removeLogo(@CurrentTenant() tenant: TenantContext) {
    return this.businesses.removeLogo(tenant.businessId);
  }

  /** Premiers pas : étapes faites ou à faire, d'après les vraies données de la boutique. */
  @Get('business/onboarding')
  @RequirePermission('business:read')
  onboarding(@CurrentTenant() tenant: TenantContext) {
    return this.businesses.onboarding(tenant.businessId);
  }

  @Patch('business')
  @RequirePermission('business:update')
  update(@CurrentTenant() tenant: TenantContext, @Body() body: unknown) {
    return this.businesses.update(tenant.businessId, parse(UpdateBusiness, body));
  }

  @Get('roles')
  roles() {
    return this.businesses.systemRoles();
  }

  @Get('members')
  @RequirePermission('members:read')
  listMembers(@CurrentTenant() tenant: TenantContext) {
    return this.members.list(tenant.businessId);
  }

  @Post('members')
  @RequirePro('team')
  @RequirePermission('members:invite')
  invite(@CurrentTenant() tenant: TenantContext, @CurrentUser() user: AuthUser, @Body() body: unknown) {
    const input = parse(InviteMember, body);
    const phone = normalizePhone(input.phone, tenant.country);
    if (!phone) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', 422);
    return this.members.invite(tenant.businessId, user.id, { ...input, phone });
  }

  @Patch('members/:id')
  @RequirePermission('members:manage')
  updateMember(
    @CurrentTenant() tenant: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() body: unknown,
  ) {
    return this.members.update(tenant.businessId, user.id, id, parse(UpdateMember, body));
  }

  @Delete('members/:id')
  @RequirePermission('members:manage')
  removeMember(
    @CurrentTenant() tenant: TenantContext,
    @CurrentUser() user: AuthUser,
    @Param('id', ParseUUIDPipe) id: string,
  ) {
    return this.members.remove(tenant.businessId, user.id, id);
  }
}
