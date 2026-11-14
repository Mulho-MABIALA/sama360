import { HttpStatus } from '@nestjs/common';
import { z, ZodTypeAny } from 'zod';
import { AppError } from './app-error';

/** Valide une entrée avec un schéma zod ; lève VALIDATION_FAILED avec le détail des champs. */
export function parse<S extends ZodTypeAny>(schema: S, input: unknown): z.infer<S> {
  const result = schema.safeParse(input);
  if (!result.success) {
    throw new AppError(
      'VALIDATION_FAILED',
      'Données invalides',
      HttpStatus.UNPROCESSABLE_ENTITY,
      result.error.issues.map((i) => ({ field: i.path.join('.'), message: i.message })),
    );
  }
  return result.data;
}

/** Pagination par curseur : les ids UUID v7 sont triables dans le temps. */
export const PageQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(50),
  cursor: z.string().uuid().optional(),
});
