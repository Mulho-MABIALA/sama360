import { ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger } from '@nestjs/common';
import { ThrottlerException } from '@nestjs/throttler';
import type { Response } from 'express';
import { AppError } from './app-error';

/** Toutes les erreurs sortent au format { error: { code, message, details? } }. */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('HTTP');

  catch(exception: unknown, host: ArgumentsHost): void {
    const res = host.switchToHttp().getResponse<Response>();

    if (exception instanceof AppError) {
      res.status(exception.status).json({
        error: { code: exception.code, message: exception.message, details: exception.details },
      });
      return;
    }

    if (exception instanceof ThrottlerException) {
      res.status(HttpStatus.TOO_MANY_REQUESTS).json({
        error: { code: 'RATE_LIMITED', message: 'Trop de requêtes, réessayez dans un instant' },
      });
      return;
    }

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const code =
        ({ 401: 'UNAUTHENTICATED', 403: 'FORBIDDEN', 404: 'NOT_FOUND', 413: 'PAYLOAD_TOO_LARGE', 429: 'RATE_LIMITED' } as const)[
          status as 401
        ] ?? (status < 500 ? 'VALIDATION_FAILED' : 'INTERNAL');
      res.status(status).json({ error: { code, message: exception.message } });
      return;
    }

    // Violation d'unicité PostgreSQL
    if (typeof exception === 'object' && exception && (exception as { code?: string }).code === '23505') {
      res.status(HttpStatus.CONFLICT).json({ error: { code: 'CONFLICT', message: 'Cette valeur existe déjà' } });
      return;
    }

    this.logger.error(exception instanceof Error ? exception.stack : String(exception));
    res.status(HttpStatus.INTERNAL_SERVER_ERROR).json({
      error: { code: 'INTERNAL', message: 'Erreur interne' },
    });
  }
}
