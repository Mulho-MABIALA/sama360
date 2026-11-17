import { OrangeSmsSender, otpMessage, SmsDeliveryError, TwilioSmsSender } from './otp-sender';

type Call = { url: string; init: RequestInit };

/** Faux fetch : enregistre les appels et rejoue des réponses prévues. */
function fakeFetch(responses: Array<{ status: number; body?: unknown }>) {
  const calls: Call[] = [];
  const http = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const r = responses.shift() ?? { status: 500 };
    return new Response(r.body === undefined ? '' : JSON.stringify(r.body), {
      status: r.status,
    });
  }) as unknown as typeof fetch;
  return { http, calls };
}

describe('SMS de connexion', () => {
  it('message court, sans accent, un seul SMS', () => {
    const m = otpMessage('482913', 300);
    expect(m).toBe('Sama360 : votre code de connexion est 482913. Il expire dans 5 min. Ne le donnez a personne.');
    expect(m.length).toBeLessThanOrEqual(160);
    expect(/[^\x20-\x7e]/.test(m)).toBe(false);
  });

  describe('Orange', () => {
    const cfg = { clientId: 'id', clientSecret: 'secret', sender: '+2210000' };

    it('prend un jeton puis envoie au bon format', async () => {
      const { http, calls } = fakeFetch([
        { status: 200, body: { access_token: 'tok1', expires_in: 3600 } },
        { status: 201, body: {} },
      ]);
      await new OrangeSmsSender(cfg, 300, http).send('+221771234567', '123456');
      expect(calls[0].url).toBe('https://api.orange.com/oauth/v3/token');
      expect((calls[0].init.headers as Record<string, string>).Authorization).toBe(
        `Basic ${Buffer.from('id:secret').toString('base64')}`,
      );
      expect(calls[0].init.body).toBe('grant_type=client_credentials');
      expect(calls[1].url).toBe('https://api.orange.com/smsmessaging/v1/outbound/tel%3A%2B2210000/requests');
      expect((calls[1].init.headers as Record<string, string>).Authorization).toBe('Bearer tok1');
      const body = JSON.parse(calls[1].init.body as string);
      expect(body.outboundSMSMessageRequest).toMatchObject({
        address: 'tel:+221771234567',
        senderAddress: 'tel:+2210000',
        outboundSMSTextMessage: { message: expect.stringContaining('123456') },
      });
      expect(body.outboundSMSMessageRequest.senderName).toBeUndefined();
    });

    it('réutilise le jeton, et le renouvelle une fois s’il est refusé', async () => {
      const { http, calls } = fakeFetch([
        { status: 200, body: { access_token: 'tok1', expires_in: 3600 } },
        { status: 201 },
        { status: 401 },
        { status: 200, body: { access_token: 'tok2', expires_in: 3600 } },
        { status: 201 },
      ]);
      const sender = new OrangeSmsSender({ ...cfg, senderName: 'Sama360' }, 300, http);
      await sender.send('+221771234567', '111111');
      await sender.send('+221771234567', '222222');
      expect(calls.map((c) => c.url.includes('token'))).toEqual([true, false, false, true, false]);
      expect((calls[4].init.headers as Record<string, string>).Authorization).toBe('Bearer tok2');
      expect(JSON.parse(calls[4].init.body as string).outboundSMSMessageRequest.senderName).toBe('Sama360');
    });

    it('erreur claire si Orange refuse (crédit épuisé…)', async () => {
      const { http } = fakeFetch([
        { status: 200, body: { access_token: 'tok', expires_in: 3600 } },
        {
          status: 403,
          body: {
            requestError: { policyException: { text: 'Not enough credit' } },
          },
        },
      ]);
      await expect(new OrangeSmsSender(cfg, 300, http).send('+221771234567', '1')).rejects.toThrow(SmsDeliveryError);
    });
  });

  describe('Twilio', () => {
    it('envoie avec un expéditeur', async () => {
      const { http, calls } = fakeFetch([{ status: 201, body: { sid: 'SM1' } }]);
      await new TwilioSmsSender({ accountSid: 'AC1', authToken: 'tk', from: 'Sama360' }, 300, http).send(
        '+221771234567',
        '654321',
      );
      expect(calls[0].url).toBe('https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json');
      const form = new URLSearchParams(calls[0].init.body as string);
      expect(form.get('To')).toBe('+221771234567');
      expect(form.get('From')).toBe('Sama360');
      expect(form.get('Body')).toContain('654321');
    });

    it('ou avec un service de messagerie ; erreur si refus', async () => {
      const { http, calls } = fakeFetch([{ status: 201 }, { status: 400 }]);
      const s = new TwilioSmsSender({ accountSid: 'AC1', authToken: 'tk', messagingServiceSid: 'MG1' }, 300, http);
      await s.send('+221771234567', '1');
      expect(new URLSearchParams(calls[0].init.body as string).get('MessagingServiceSid')).toBe('MG1');
      await expect(s.send('+221771234567', '2')).rejects.toThrow('Twilio');
    });
  });
});
