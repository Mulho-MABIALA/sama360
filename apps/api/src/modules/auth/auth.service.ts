import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { and, desc, eq, gt, isNull } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import { DbService, Tx } from '../../shared/db/db.service';
import { businesses, memberships, otpCodes, refreshTokens, users } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';
import { generateOtp, generateRefreshToken, hmac, safeEqualHex } from './crypto';
import { OTP_SENDER, OtpChannel, OtpSender } from './otp-sender';

const RESEND_DELAY_MS = 60_000;
/** Changer de moyen (WhatsApp → SMS…) : possible plus vite qu'un simple renvoi. */
const SWITCH_DELAY_MS = 15_000;

const CHANNEL_LABEL: Record<OtpChannel, string> = { sms: 'le SMS', whatsapp: 'le message WhatsApp', call: 'l’appel' };

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: string;
}

@Injectable()
export class AuthService {
  private readonly logger = new Logger('Auth');

  constructor(
    private readonly dbs: DbService,
    private readonly jwt: JwtService,
    @Inject(OTP_SENDER) private readonly sender: OtpSender,
  ) {}

  requirePhone(raw: string): string {
    const phone = normalizePhone(raw);
    if (!phone) throw new AppError('PHONE_INVALID', 'Numéro de téléphone invalide', HttpStatus.UNPROCESSABLE_ENTITY);
    return phone;
  }

  /** Moyens de recevoir le code proposés à l'écran de connexion, le premier par défaut. */
  otpChannels(): { channels: OtpChannel[]; default: OtpChannel } {
    const channels = [...this.sender.channels];
    return { channels, default: channels[0] };
  }

  /**
   * Envoie un code à 6 chiffres par le moyen choisi (WhatsApp, SMS, appel).
   * Un renvoi par minute ; changer de moyen est possible après 15 secondes.
   */
  async requestOtp(
    rawPhone: string,
    wanted?: OtpChannel,
  ): Promise<{ phone: string; expiresIn: number; channel: OtpChannel }> {
    const phone = this.requirePhone(rawPhone);
    const e = env();
    const db = this.dbs.db;
    const channel = wanted && this.sender.channels.includes(wanted) ? wanted : this.sender.channels[0];

    const [last] = await db
      .select({ createdAt: otpCodes.createdAt, channel: otpCodes.channel })
      .from(otpCodes)
      .where(eq(otpCodes.phone, phone))
      .orderBy(desc(otpCodes.createdAt))
      .limit(1);
    const wait = last && last.channel !== channel ? SWITCH_DELAY_MS : RESEND_DELAY_MS;
    if (last && Date.now() - last.createdAt.getTime() < wait) {
      throw new AppError(
        'OTP_TOO_SOON',
        wait === RESEND_DELAY_MS
          ? 'Patientez une minute avant de redemander un code'
          : 'Patientez quelques secondes avant de changer de moyen',
        429,
      );
    }

    const code = generateOtp();
    const otpId = newId();
    await db.insert(otpCodes).values({
      id: otpId,
      phone,
      codeHash: hmac(e.OTP_SECRET, `${phone}:${code}`),
      channel,
      expiresAt: new Date(Date.now() + e.OTP_TTL_SECONDS * 1000),
    });
    try {
      await this.sender.send(phone, code, channel);
    } catch (err) {
      // Le code n'est pas parti : on l'efface pour pouvoir redemander tout de suite.
      await db.delete(otpCodes).where(eq(otpCodes.id, otpId));
      this.logger.error(
        `Envoi du code (${channel}) impossible vers ${phone.slice(0, -4)}**** : ${(err as Error).message}`,
      );
      const what = CHANNEL_LABEL[channel];
      throw new AppError(
        'SMS_FAILED',
        `${what.charAt(0).toUpperCase()}${what.slice(1)} n’a pas pu partir. Vérifiez le numéro, ou choisissez un autre moyen.`,
        503,
      );
    }
    return { phone, expiresIn: e.OTP_TTL_SECONDS, channel };
  }

  /** Vérifie le code ; crée le compte au premier passage ; active les invitations en attente. */
  async verifyOtp(rawPhone: string, code: string, deviceId?: string) {
    const phone = this.requirePhone(rawPhone);
    const e = env();

    const result = await this.dbs.transaction(async (tx) => {
      const check = await this.consumeCode(tx, phone, code);
      if (!check.ok) return check;

      let [user] = await tx.select().from(users).where(eq(users.phone, phone)).limit(1);
      if (!user) {
        [user] = await tx.insert(users).values({ id: newId(), phone }).returning();
      } else if (user.status === 'invited') {
        [user] = await tx
          .update(users)
          .set({ status: 'active', updatedAt: new Date() })
          .where(eq(users.id, user.id))
          .returning();
      } else if (user.status === 'suspended') {
        throw AppError.forbidden('Compte suspendu');
      }
      // Compte supprimé il y a moins de 30 jours : se reconnecter annule la suppression
      let restored = false;
      if (user.deletedAt) {
        const now = new Date();
        [user] = await tx
          .update(users)
          .set({ deletedAt: null, updatedAt: now })
          .where(eq(users.id, user.id))
          .returning();
        await tx
          .update(businesses)
          .set({ deletedAt: null, deletedBy: null, deletedWithAccount: false, updatedAt: now })
          .where(and(eq(businesses.ownerId, user.id), eq(businesses.deletedWithAccount, true)));
        restored = true;
        this.logger.log(`Compte ${user.id} restauré à la reconnexion`);
      }

      await tx
        .update(memberships)
        .set({ status: 'active' })
        .where(and(eq(memberships.userId, user.id), eq(memberships.status, 'invited')));

      const tokens = await this.issueTokens(tx, user.id, deviceId);
      return {
        ok: true as const,
        session: {
          ...tokens,
          isNewUser: !user.fullName,
          ...(restored ? { restored: true } : {}),
          user: { id: user.id, phone: user.phone, fullName: user.fullName },
        },
      };
    });

    if (!result.ok) {
      throw new AppError('OTP_INVALID', 'Code incorrect', 400, { remainingAttempts: result.remainingAttempts });
    }
    return result.session;
  }

  /**
   * Vérifie le dernier code envoyé à ce numéro et le consomme. Un mauvais code compte une tentative
   * (la transaction est validée, l'appelant lève l'erreur ensuite).
   */
  private async consumeCode(tx: Tx, phone: string, code: string) {
    const e = env();
    const [otp] = await tx
      .select()
      .from(otpCodes)
      .where(and(eq(otpCodes.phone, phone), isNull(otpCodes.consumedAt)))
      .orderBy(desc(otpCodes.createdAt))
      .limit(1)
      .for('update');

    if (!otp || otp.expiresAt.getTime() < Date.now()) {
      throw new AppError('OTP_EXPIRED', 'Code expiré, demandez-en un nouveau', 400);
    }
    if (otp.attempts >= e.OTP_MAX_ATTEMPTS) {
      throw new AppError('OTP_TOO_MANY_ATTEMPTS', 'Trop de tentatives, demandez un nouveau code', 429);
    }
    // Code vérifié chez le fournisseur (Twilio Verify) ou comparé à celui tiré par le serveur
    const valid = this.sender.check
      ? await this.sender.check(phone, code)
      : safeEqualHex(otp.codeHash, hmac(e.OTP_SECRET, `${phone}:${code}`));
    if (!valid) {
      await tx
        .update(otpCodes)
        .set({ attempts: otp.attempts + 1 })
        .where(eq(otpCodes.id, otp.id));
      return { ok: false as const, remainingAttempts: Math.max(0, e.OTP_MAX_ATTEMPTS - otp.attempts - 1) };
    }
    await tx.update(otpCodes).set({ consumedAt: new Date() }).where(eq(otpCodes.id, otp.id));
    return { ok: true as const };
  }

  /**
   * Page web « Supprimer mon compte » (exigée par Google Play) : le code reçu prouve que la personne
   * détient le numéro. Ne crée pas de compte et ne restaure pas un compte déjà supprimé.
   */
  async verifyForDeletion(rawPhone: string, code: string): Promise<string> {
    const phone = this.requirePhone(rawPhone);
    const result = await this.dbs.transaction(async (tx) => {
      const check = await this.consumeCode(tx, phone, code);
      if (!check.ok) return check;
      const [user] = await tx.select().from(users).where(eq(users.phone, phone)).limit(1);
      return { ok: true as const, userId: user && !user.deletedAt ? user.id : null };
    });
    if (!result.ok) {
      throw new AppError('OTP_INVALID', 'Code incorrect', 400, { remainingAttempts: result.remainingAttempts });
    }
    if (!result.userId) throw AppError.notFound('Compte Sama360 pour ce numéro');
    return result.userId;
  }

  /** Rotation : l'ancien jeton est révoqué. Réutiliser un jeton révoqué révoque toute la session. */
  async refresh(refreshToken: string): Promise<TokenPair> {
    const hash = hmac(env().JWT_REFRESH_SECRET, refreshToken);
    const result = await this.dbs.transaction(async (tx) => {
      const [row] = await tx
        .select()
        .from(refreshTokens)
        .where(eq(refreshTokens.tokenHash, hash))
        .limit(1)
        .for('update');
      if (!row || row.expiresAt.getTime() < Date.now()) return { ok: false as const };
      if (row.revokedAt) {
        // Jeton déjà utilisé : possible vol. On coupe toutes les sessions de l'utilisateur.
        await tx
          .update(refreshTokens)
          .set({ revokedAt: new Date() })
          .where(and(eq(refreshTokens.userId, row.userId), isNull(refreshTokens.revokedAt)));
        return { ok: false as const };
      }
      return { ok: true as const, pair: await this.issueTokens(tx, row.userId, row.deviceId ?? undefined, row.id) };
    });
    if (!result.ok) throw new AppError('TOKEN_INVALID', 'Session invalide ou expirée, reconnectez-vous', 401);
    return result.pair;
  }

  async logout(refreshToken: string): Promise<void> {
    const hash = hmac(env().JWT_REFRESH_SECRET, refreshToken);
    await this.dbs.db
      .update(refreshTokens)
      .set({ revokedAt: new Date() })
      .where(and(eq(refreshTokens.tokenHash, hash), isNull(refreshTokens.revokedAt)));
  }

  /** Déconnecte tous les appareils de l'utilisateur (sessions révoquées). Renvoie le nombre de sessions fermées. */
  async logoutAll(userId: string): Promise<number> {
    const rows = await this.dbs.db
      .update(refreshTokens)
      .set({ revokedAt: new Date() })
      .where(and(eq(refreshTokens.userId, userId), isNull(refreshTokens.revokedAt)))
      .returning({ id: refreshTokens.id });
    return rows.length;
  }

  private async issueTokens(tx: Tx, userId: string, deviceId?: string, replacing?: string): Promise<TokenPair> {
    const e = env();
    const accessToken = await this.jwt.signAsync(
      { sub: userId, typ: 'access' },
      // JWT_ACCESS_TTL est une durée « ms » (ex. 15m), validée au démarrage
      { secret: e.JWT_ACCESS_SECRET, expiresIn: e.JWT_ACCESS_TTL as unknown as number },
    );
    const refreshToken = generateRefreshToken();
    const id = newId();
    await tx.insert(refreshTokens).values({
      id,
      userId,
      tokenHash: hmac(e.JWT_REFRESH_SECRET, refreshToken),
      deviceId: deviceId ?? null,
      expiresAt: new Date(Date.now() + e.REFRESH_TTL_DAYS * 24 * 3600 * 1000),
    });
    if (replacing) {
      await tx
        .update(refreshTokens)
        .set({ revokedAt: new Date(), replacedBy: id })
        .where(and(eq(refreshTokens.id, replacing), gt(refreshTokens.expiresAt, new Date())));
    }
    return { accessToken, refreshToken, expiresIn: e.JWT_ACCESS_TTL };
  }
}
