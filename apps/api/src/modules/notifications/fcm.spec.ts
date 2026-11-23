import { generateKeyPairSync, createVerify } from 'node:crypto';
import { FcmClient, parseServiceAccount } from './fcm';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const sa = { project_id: 'sama-test', client_email: 'push@sama-test.iam', private_key: pem };

describe('Firebase Cloud Messaging', () => {
  it('lit la clé en JSON ou en base64, retours à la ligne échappés compris', () => {
    const escaped = JSON.stringify({ ...sa, private_key: pem.replace(/\n/g, '\\n') });
    expect(parseServiceAccount(escaped).private_key).toBe(pem);
    expect(parseServiceAccount(Buffer.from(JSON.stringify(sa)).toString('base64')).project_id).toBe('sama-test');
    expect(() => parseServiceAccount('{"project_id":"x"}')).toThrow('incomplète');
  });

  it('jeton OAuth signé (RS256), gardé en mémoire, puis envoi au bon appareil', async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const http = jest.fn(async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      if (url.includes('oauth2')) {
        return new Response(JSON.stringify({ access_token: 'ya29.test', expires_in: 3600 }));
      }
      if ((init.body as string).includes('mort')) {
        return new Response(
          JSON.stringify({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }),
          {
            status: 404,
          },
        );
      }
      return new Response('{}');
    });
    const fcm = new FcmClient(sa, http as unknown as typeof fetch);
    expect(
      await fcm.send('tel-1', {
        title: 'Nouvelle commande',
        body: '3 articles',
        link: '/shop/orders/9',
        webBase: 'https://sama.test/',
      }),
    ).toBe('sent');
    expect(await fcm.send('mort', { title: 'x', body: '' })).toBe('unregistered');
    // Un seul jeton OAuth pour deux envois
    expect(calls.filter((c) => c.url.includes('oauth2'))).toHaveLength(1);
    const jwt = new URLSearchParams(calls[0].init.body as URLSearchParams).get('assertion')!;
    const [h, c, sig] = jwt.split('.');
    const v = createVerify('RSA-SHA256');
    v.update(`${h}.${c}`);
    expect(v.verify(publicKey, Buffer.from(sig, 'base64url'))).toBe(true);
    expect(JSON.parse(Buffer.from(c, 'base64url').toString())).toMatchObject({
      iss: 'push@sama-test.iam',
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
    });
    const send = calls[1];
    expect(send.url).toBe('https://fcm.googleapis.com/v1/projects/sama-test/messages:send');
    expect((send.init.headers as Record<string, string>).Authorization).toBe('Bearer ya29.test');
    expect(JSON.parse(send.init.body as string).message).toMatchObject({
      token: 'tel-1',
      notification: { title: 'Nouvelle commande', body: '3 articles' },
      data: { link: '/shop/orders/9' },
      webpush: { fcm_options: { link: 'https://sama.test/app/#/shop/orders/9' } },
    });
  });
});
