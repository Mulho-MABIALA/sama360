/**
 * Normalise un numéro au format E.164.
 * Sans indicatif, le Sénégal (+221) est supposé : "77 123 45 67" → "+221771234567".
 * Renvoie null si le numéro n'est pas plausible.
 */
export function normalizePhone(input: string, defaultCountryCode = '221'): string | null {
  const trimmed = input.trim();
  let digits = trimmed.replace(/[^\d]/g, '');
  if (!digits) return null;

  if (trimmed.startsWith('+')) {
    // déjà international
  } else if (digits.startsWith('00')) {
    digits = digits.slice(2);
  } else if (digits.length === 9 && defaultCountryCode === '221') {
    // numéro sénégalais local : 9 chiffres commençant par 7 (mobile) ou 3 (fixe)
    if (!/^[37]/.test(digits)) return null;
    digits = defaultCountryCode + digits;
  } else if (!digits.startsWith(defaultCountryCode)) {
    // ni indicatif explicite, ni format local reconnu : ambigu, on refuse
    return null;
  }

  if (digits.length < 8 || digits.length > 15) return null;
  if (digits.startsWith('221') && !/^221[37]\d{8}$/.test(digits)) return null;
  return `+${digits}`;
}
