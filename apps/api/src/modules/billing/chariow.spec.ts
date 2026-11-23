import { createHmac } from 'node:crypto';
import { createCheckout, readPulse, splitName, verifyPulseSignature } from './chariow';

describe('Chariow', () => {
  it('vérifie la signature du Pulse sur le corps brut', () => {
    const raw = Buffer.from('{"event":"successful.sale","url":"https:\\/\\/x"}');
    const sig = 'sha256=' + createHmac('sha256', 'whsec_x').update(raw).digest('hex');
    expect(verifyPulseSignature(raw, sig, 'whsec_x')).toBe(true);
    expect(verifyPulseSignature(raw, sig.replace('sha256=', ''), 'whsec_x')).toBe(true);
    expect(verifyPulseSignature(raw, sig, 'whsec_autre')).toBe(false);
    expect(verifyPulseSignature(Buffer.from('{"event":"x"}'), sig, 'whsec_x')).toBe(false);
    expect(verifyPulseSignature(raw, 'sha256=abc', 'whsec_x')).toBe(false);
    expect(verifyPulseSignature(raw, undefined, 'whsec_x')).toBe(false);
  });

  it('lit une vente dans un Pulse', () => {
    expect(
      readPulse({
        event: 'successful.sale',
        sale: {
          id: 'sal_1',
          custom_metadata: { payment_id: 'p' },
          payment: { amount: { value: 5000, currency: 'XOF' } },
        },
        product: { id: 'prd_1' },
      }),
    ).toEqual({
      event: 'successful.sale',
      saleId: 'sal_1',
      productId: 'prd_1',
      metadata: { payment_id: 'p' },
      amount: 5000,
      currency: 'XOF',
    });
    expect(readPulse(null)).toMatchObject({ event: '', saleId: null, metadata: {} });
  });

  it('coupe le nom en prénom et nom', () => {
    expect(splitName('Ibrahim Trésor Mabiala', 'Boutique')).toEqual({ first: 'Ibrahim', last: 'Trésor Mabiala' });
    expect(splitName('Awa', 'Boutique')).toEqual({ first: 'Awa', last: 'Awa' });
    expect(splitName(null, 'Ma Boutique')).toEqual({ first: 'Ma Boutique', last: 'Ma Boutique' });
  });

  it('crée un paiement et signale les erreurs', async () => {
    const ok = jest.fn(
      async () =>
        new Response(
          JSON.stringify({
            data: { step: 'payment', purchase: { id: 'sal_9' }, payment: { checkout_url: 'https://p' } },
          }),
        ),
    );
    const input = {
      productId: 'prd_1',
      email: 'a@b.sn',
      firstName: 'A',
      lastName: 'B',
      phone: { number: '770000000', countryCode: 'SN' },
      metadata: { payment_id: 'x' },
    };
    await expect(createCheckout('https://api.test/v1/', 'sk', input, ok as unknown as typeof fetch)).resolves.toEqual({
      step: 'payment',
      checkoutUrl: 'https://p',
      saleId: 'sal_9',
      message: null,
    });
    const bad = jest.fn(async () => new Response(JSON.stringify({ message: 'Invalid phone' }), { status: 400 }));
    await expect(
      createCheckout('https://api.test/v1', 'sk', input, bad as unknown as typeof fetch),
    ).rejects.toMatchObject({
      message: 'Invalid phone',
      status: 400,
    });
  });
});
