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
  | 'SMS_FAILED'
  | 'PHONE_INVALID'
  | 'BUSINESS_REQUIRED'
  | 'NOT_A_MEMBER'
  | 'INSUFFICIENT_PERMISSION'
  | 'MODULE_NOT_ENABLED'
  | 'NOT_FOUND'
  | 'CONFLICT'
  | 'FORBIDDEN'
  | 'RATE_LIMITED'
  | 'PAYLOAD_TOO_LARGE'
  | 'CREDIT_REQUIRES_CUSTOMER'
  | 'CASH_CLOSED'
  | 'ASSISTANT_DISABLED'
  | 'ASSISTANT_LIMIT'
  | 'ASSISTANT_UNAVAILABLE'
  | 'OVERPAYMENT'
  | 'REPAYMENT_EXCEEDS_BALANCE'
  | 'SALE_ALREADY_VOIDED'
  | 'PRODUCT_NOT_TRACKED'
  | 'DOCUMENT_LOCKED'
  | 'INVOICE_HAS_PAYMENTS'
  | 'PAYMENT_EXCEEDS_DUE'
  | 'CREDIT_LIMIT_EXCEEDED'
  | 'CUSTOMER_HAS_BALANCE'
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
