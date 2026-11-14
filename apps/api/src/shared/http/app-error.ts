import { HttpStatus } from '@nestjs/common';

/** Codes d'erreur stables, exposés aux clients (mobile, back-office). */
export type ErrorCode =
  | 'VALIDATION_FAILED'
  | 'UNAUTHENTICATED'
  | 'TOKEN_INVALID'
  | 'OTP_INVALID'
  | 'OTP_EXPIRED'
  | 'OTP_TOO_MANY_ATTEMPTS'
  | 'OTP_TOO_SOON'
  | 'PHONE_INVALID'
  | 'BUSINESS_REQUIRED'
  | 'NOT_A_MEMBER'
  | 'INSUFFICIENT_PERMISSION'
  | 'MODULE_NOT_ENABLED'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'FORBIDDEN'
  | 'RATE_LIMITED'
  | 'INTERNAL';

export class AppError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly status: HttpStatus = HttpStatus.BAD_REQUEST,
    readonly details?: unknown,
  ) {
    super(message);
  }

  static notFound(what = 'Ressource'): AppError {
    return new AppError('NOT_FOUND', `${what} introuvable`, HttpStatus.NOT_FOUND);
  }

  static forbidden(message = 'Action non autorisée'): AppError {
    return new AppError('FORBIDDEN', message, HttpStatus.FORBIDDEN);
  }

  static conflict(message: string): AppError {
    return new AppError('CONFLICT', message, HttpStatus.CONFLICT);
  }
}
