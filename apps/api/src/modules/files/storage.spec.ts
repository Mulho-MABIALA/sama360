import { Readable } from 'node:stream';
import { checkKey, S3Storage } from './storage';

describe('stockage S3', () => {
  it('refuse les clés dangereuses', () => {
    expect(checkKey('biz/2026/photo.jpg')).toBe('biz/2026/photo.jpg');
    for (const bad of ['../etc/passwd', '/abs', 'a b.jpg', 'x/../y']) expect(() => checkKey(bad)).toThrow();
  });

  it('écrit, lit et supprime dans le bon seau', async () => {
    const sent: Array<{ name: string; input: Record<string, unknown> }> = [];
    const client = {
      send: async (cmd: { constructor: { name: string }; input: Record<string, unknown> }) => {
        sent.push({ name: cmd.constructor.name, input: cmd.input });
        if (cmd.constructor.name === 'GetObjectCommand') {
          if (cmd.input.Key === 'absent.jpg') throw Object.assign(new Error('x'), { name: 'NoSuchKey' });
          return { Body: Readable.from(['ok']) };
        }
        return {};
      },
    };
    const s = new S3Storage(client as never, 'sama360-fichiers');
    await s.put('biz/a.jpg', Buffer.from('x'), 'image/jpeg');
    expect(await s.get('biz/a.jpg')).toBeInstanceOf(Readable);
    expect(await s.get('absent.jpg')).toBeNull();
    await s.delete('biz/a.jpg');
    expect(sent.map((c) => c.name)).toEqual([
      'PutObjectCommand',
      'GetObjectCommand',
      'GetObjectCommand',
      'DeleteObjectCommand',
    ]);
    expect(sent[0].input).toMatchObject({
      Bucket: 'sama360-fichiers',
      Key: 'biz/a.jpg',
      ContentType: 'image/jpeg',
    });
  });
});
