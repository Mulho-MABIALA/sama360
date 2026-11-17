import { daysUntil, downloadName, expiryStatus } from './documents';

describe('documents', () => {
  const today = new Date('2026-11-17T10:00:00Z');

  it('jours avant l’échéance', () => {
    expect(daysUntil(null, today)).toBeNull();
    expect(daysUntil('2026-11-17', today)).toBe(0);
    expect(daysUntil('2026-12-17', today)).toBe(30);
    expect(daysUntil('2026-11-10', today)).toBe(-7);
  });

  it('statut : expiré, bientôt (30 jours), ou rien', () => {
    expect(expiryStatus(-1)).toBe('expired');
    expect(expiryStatus(0)).toBe('soon');
    expect(expiryStatus(30)).toBe('soon');
    expect(expiryStatus(31)).toBeNull();
    expect(expiryStatus(null)).toBeNull();
  });

  it('nom de fichier sûr pour le téléchargement', () => {
    expect(downloadName('Bail boutique Sandaga', 'application/pdf')).toBe('Bail boutique Sandaga.pdf');
    expect(downloadName('Reçu « EDM » n°12', 'image/jpeg')).toBe('Recu EDM n12.jpg');
    expect(downloadName('"; rm -rf /', 'image/png')).toBe('rm -rf.png');
    expect(downloadName('***', 'image/webp')).toBe('document.webp');
  });
});
