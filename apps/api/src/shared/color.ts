/** Couleurs de marque : « #0A7E4F », lisibles avec du texte blanc. */

const HEX = /^#?([0-9a-f]{6})$/i;

export function normalizeHex(input: string): string | null {
  const m = HEX.exec(input.trim());
  return m ? `#${m[1].toUpperCase()}` : null;
}

function channels(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function luminance(hex: string): number {
  const [r, g, b] = channels(hex).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** Contraste WCAG (1 à 21). */
export function contrast(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

/** Assombrit (même teinte) jusqu'à un contraste de 4,5:1 avec le blanc : boutons et texte lisibles. */
export function readableOnWhite(hex: string): string {
  let [r, g, b] = channels(hex);
  let out = hex.toUpperCase();
  for (let i = 0; i < 40 && contrast(out, '#FFFFFF') < 4.5; i++) {
    [r, g, b] = [r, g, b].map((v) => Math.round(v * 0.94)) as [number, number, number];
    out = `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, '0').toUpperCase()}`;
  }
  return out;
}
