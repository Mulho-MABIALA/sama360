import { sql } from 'drizzle-orm';
import type { Tx } from './db/db.service';

/** Pays où Sama360 est lancé : indicatif, numéros locaux, monnaie, paiements mobiles. */
export const COUNTRY_CODES = ['SN', 'CI', 'CG'] as const;
export type CountryCode = (typeof COUNTRY_CODES)[number];

export const MOBILE_MONEY = ['wave', 'orange_money', 'free_money', 'mtn_momo', 'moov_money', 'airtel_money'] as const;
export type MobileMoney = (typeof MOBILE_MONEY)[number];

export interface Country {
  code: CountryCode;
  name: string;
  dial: string; // indicatif sans « + »
  /** Numéro national complet (sans indicatif), mobile ou fixe. */
  local: RegExp;
  /** Découpage d'affichage du numéro national, ex. [2, 3, 2, 2] → « 77 123 45 67 ». */
  groups: number[];
  currency: 'XOF' | 'XAF';
  taxIdLabel: string;
  mobileMoney: MobileMoney[];
  /** Exemple de numéro local, pour les champs à remplir. */
  example: string;
}

export const COUNTRIES: Record<CountryCode, Country> = {
  // 9 chiffres : mobiles 7x, fixes 33
  SN: {
    code: 'SN',
    name: 'Sénégal',
    dial: '221',
    local: /^[37]\d{8}$/,
    groups: [2, 3, 2, 2],
    currency: 'XOF',
    taxIdLabel: 'NINEA',
    mobileMoney: ['wave', 'orange_money', 'free_money'],
    example: '77 123 45 67',
  },
  // 10 chiffres depuis 2021 : mobiles 01 (Moov), 05 (MTN), 07 (Orange) ; fixes 21, 25, 27
  CI: {
    code: 'CI',
    name: "Côte d'Ivoire",
    dial: '225',
    local: /^(0[157]|2[157])\d{8}$/,
    groups: [2, 2, 2, 2, 2],
    currency: 'XOF',
    taxIdLabel: 'N° CC',
    mobileMoney: ['wave', 'orange_money', 'mtn_momo', 'moov_money'],
    example: '07 07 12 34 56',
  },
  // 9 chiffres : mobiles 04, 05 (Airtel), 06 (MTN) ; fixes 22
  CG: {
    code: 'CG',
    name: 'Congo',
    dial: '242',
    local: /^(0[1456]|22)\d{7}$/,
    groups: [2, 3, 2, 2],
    currency: 'XAF',
    taxIdLabel: 'NIU',
    mobileMoney: ['mtn_momo', 'airtel_money'],
    example: '06 612 34 56',
  },
};

export const MOBILE_MONEY_LABELS: Record<MobileMoney, string> = {
  wave: 'Wave',
  orange_money: 'Orange Money',
  free_money: 'Free Money',
  mtn_momo: 'MTN MoMo',
  moov_money: 'Moov Money',
  airtel_money: 'Airtel Money',
};

/** « espèces, Wave, Orange Money » : comment payer à la livraison dans ce pays. */
export function payHint(c: Country): string {
  return ['espèces', ...c.mobileMoney.map((m) => MOBILE_MONEY_LABELS[m])].join(', ');
}

export function isCountry(v: unknown): v is CountryCode {
  return typeof v === 'string' && (COUNTRY_CODES as readonly string[]).includes(v);
}

export function countryOf(code: string | null | undefined): Country {
  return isCountry(code) ? COUNTRIES[code] : COUNTRIES.SN;
}

/** Pays d'un numéro E.164 (+221…, +225…, +242…), ou null s'il est d'ailleurs. */
export function countryOfPhone(e164: string): Country | null {
  const digits = e164.replace(/\D/g, '');
  return Object.values(COUNTRIES).find((c) => digits.startsWith(c.dial)) ?? null;
}

/** Pays d'une entreprise, lu dans la transaction en cours (SN par défaut). */
export async function tenantCountry(tx: Tx, businessId: string): Promise<CountryCode> {
  const r = (await tx.execute(sql`SELECT country FROM core.businesses WHERE id = ${businessId}`)).rows[0] as
    | { country?: string }
    | undefined;
  return countryOf(r?.country).code;
}
