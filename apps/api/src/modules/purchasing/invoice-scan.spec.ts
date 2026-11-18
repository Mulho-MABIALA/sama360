import { cleanScan, matchLine, matchSupplier, normLabel, similarity } from './invoice-scan';

describe('lecture de facture', () => {
  it('normalise les libellés', () => {
    expect(normLabel('RIZ Brisé  25 Kg')).toBe('riz brise 25kg');
    expect(normLabel('Huile « Dinor » 1,5 L')).toBe('huile dinor 1.5l');
  });

  it('nettoie la réponse du modèle : montants en texte, quantité ou prix manquants', () => {
    const s = cleanScan({
      readable: true,
      supplier_name: 'Ets Ndiaye',
      invoice_date: '17/11/2026',
      total: '182.000',
      lines: [
        { label: 'Riz 25kg', quantity: 10, unit_price: '12 500', line_total: null },
        { label: 'Sucre', quantity: null, unit_price: 900, line_total: 18000 },
        { label: 'Lait', quantity: 3, unit_price: null, line_total: 4500 },
      ],
    });
    expect(s.readable).toBe(true);
    expect(s.date).toBeNull();
    expect(s.total).toBe(182000);
    expect(s.lines).toEqual([
      { label: 'Riz 25kg', quantity: 10, unitCost: 12500, total: 125000 },
      { label: 'Sucre', quantity: 20, unitCost: 900, total: 18000 },
      { label: 'Lait', quantity: 3, unitCost: 1500, total: 4500 },
    ]);
  });

  it('photo illisible ou réponse invalide : rien d’inventé', () => {
    expect(cleanScan({ readable: false, lines: [] }).readable).toBe(false);
    expect(cleanScan('n’importe quoi').lines).toEqual([]);
  });

  it('un conditionnement différent n’est pas le même produit', () => {
    expect(similarity('Huile Dinor 5L', 'Huile Dinor 5 L')).toBe(1);
    expect(similarity('Huile Dinor 5L', 'Huile Dinor 1L')).toBeLessThan(0.5);
  });

  it('rapproche les lignes : mémoire, code-barres, nom', () => {
    const catalog = [
      { id: 'riz', name: 'Riz brisé parfumé 25 kg', barcode: null, sku: null },
      { id: 'huile5', name: 'Huile Dinor 5L', barcode: '6001234567890', sku: null },
      { id: 'huile1', name: 'Huile Dinor 1L', barcode: null, sku: null },
      { id: 'sucre', name: 'Sucre en morceaux', barcode: null, sku: null },
    ];
    const memory = new Map([['sucre mx 1kg', 'sucre']]);
    expect(matchLine('RIZ BRISE PARFUME 25KG', catalog, memory)).toMatchObject({
      productId: 'riz',
      confidence: 'high',
    });
    expect(matchLine('Huile 6001234567890', catalog, memory)).toMatchObject({
      productId: 'huile5',
      confidence: 'high',
    });
    expect(matchLine('Sucre MX 1kg', catalog, memory)).toMatchObject({ productId: 'sucre', confidence: 'memory' });
    expect(matchLine('Savon Madar', catalog, memory)).toMatchObject({ productId: null, confidence: 'none' });
  });

  it('retrouve le fournisseur par téléphone ou par nom', () => {
    const suppliers = [
      { id: 'a', name: 'Sénégal Distribution', phone: '+221338201122' },
      { id: 'b', name: 'Ets Fall et Frères', phone: null },
    ];
    expect(matchSupplier({ name: 'Autre', phone: '33 820 11 22' }, suppliers)).toBe('a');
    expect(matchSupplier({ name: 'SENEGAL DISTRIBUTION SARL', phone: null }, suppliers)).toBe('a');
    expect(matchSupplier({ name: 'Fall & Frères', phone: null }, suppliers)).toBe('b');
    expect(matchSupplier({ name: 'Inconnu SA', phone: null }, suppliers)).toBeNull();
  });
});
