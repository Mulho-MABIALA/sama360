import { COUNTRIES, CountryCode, countryOfPhone } from './countries';

/**
 * Normalise un numéro au format E.164.
 * Sans indicatif, le pays de la boutique est supposé (Sénégal par défaut) :
 * "77 123 45 67" → "+221771234567" ; "07 07 12 34 56" (CI) → "+2250707123456".
 * Les numéros de nos pays (SN, CI, CG) sont vérifiés ; ceux d'ailleurs gardés tels quels.
 * Renvoie null si le numéro n'est pas plausible.
 */
export function normalizePhone(input: string, country: CountryCode = 'SN'): string | null {
  const trimmed = input.trim();
  let digits = trimmed.replace(/[^\d]/g, '');
  if (!digits) return null;
  const home = COUNTRIES[country];

  if (trimmed.startsWith('+')) {
    // déjà international
  } else if (digits.startsWith('00')) {
    digits = digits.slice(2);
  } else if (home.local.test(digits)) {
    digits = home.dial + digits;
  } else if (digits.startsWith(home.dial) && home.local.test(digits.slice(home.dial.length))) {
    // indicatif tapé sans « + »
  } else {
    // ni indicatif explicite, ni format local reconnu : ambigu, on refuse
    return null;
  }

  if (digits.length < 8 || digits.length > 15) return null;
  const known = countryOfPhone(digits);
  if (known && !known.local.test(digits.slice(known.dial.length))) return null;
  return `+${digits}`;
}
