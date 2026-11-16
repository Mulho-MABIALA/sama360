import { HttpStatus, Inject, Injectable } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { and, desc, eq, gt, isNull } from 'drizzle-orm';
import { env } from '../../shared/config/env';
import { DbService, Tx } from '../../shared/db/db.service';
import { memberships, otpCodes, refreshTokens, users } from '../../shared/db/schema';
import { AppError } from '../../shared/http/app-error';
import { newId } from '../../shared/ids';
import { normalizePhone } from '../../shared/phone';
import { generateOtp, generateRefreshToken, hmac, safeEqualHex } from './crypto';
import { OTP_SENDER, OtpSender } from './otp-sender';

const RESEND_DELAY_MS = 60_000;

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: string;
}

@Injectable()
export class AuthService {
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

  /** Envoie un code à 6 chiffres. Un seul envoi par minute et par numéro. */
  async requestOtp(rawPhone: string): Promise<{ phone: string; expiresIn: number }> {
    const phone = this.requirePhone(rawPhone);
    const e = env();
    const db = this.dbs.db;

    const [last] = await db
      .select({ createdAt: otpCodes.createdAt })
      .from(otpCodes)
      .where(eq(otpCodes.phone, phone))
      .orderBy(desc(otpCodes.createdAt))
      .limit(1);
    if (last && Date.now() - last.createdAt.getTime() < RESEND_DELAY_MS) {
      throw new AppError('OTP_TOO_SOON', 'Patientez une minute avant de redemander un code', 429);
    }

    const code = generateOtp();
    await db.insert(otpCodes).values({
      id: newId(),
      phone,
      codeHash: hmac(e.OTP_SECRET, `${phone}:${code}`),
      expiresAt: new Date(Date.now() + e.OTP_TTL_SECONDS * 1000),
    });
    await this.sender.send(phone, code);
    return { phone, expiresIn: e.OTP_TTL_SECONDS };
  }

  /** Vérifie le code ; crée le compte au premier passage ; active les invitations en attente. */
  async verifyOtp(rawPhone: string, code: string, deviceId?: string) {
    const phone = this.requirePhone(rawPhone);
    const e = env();

    const result = await this.dbs.transaction(async (tx) => {
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
      if (!safeEqualHex(otp.codeHash, hmac(e.OTP_SECRET, `${phone}:${code}`))) {
        // La tentative est comptée puis la transaction est validée ; l'erreur est levée après.
        await tx.update(otpCodes).set({ attempts: otp.attempts + 1 }).where(eq(otpCodes.id, otp.id));
        return { ok: false as const, remainingAttempts: Math.max(0, e.OTP_MAX_ATTEMPTS - otp.attempts - 1) };
      }
      await tx.update(otpCodes).set({ consumedAt: new Date() }).where(eq(otpCodes.id, otp.id));

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
          user: { id: user.id, phone: user.phone, fullName: user.fullName },
        },
      };
    });

    if (!result.ok) {
      throw new AppError('OTP_INVALID', 'Code incorrect', 400, { remainingAttempts: result.remainingAttempts });
    }
    return result.session;
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
