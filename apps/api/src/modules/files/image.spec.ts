import { detectImage } from './image';

describe('detectImage', () => {
  it('reconnaît JPEG, PNG et WebP par leur signature', () => {
    expect(detectImage(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0]))?.mime).toBe('image/jpeg');
    expect(detectImage(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]))?.ext).toBe('png');
    expect(detectImage(Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBPVP8 ')]))?.ext).toBe(
      'webp',
    );
  });

  it('refuse tout le reste, même déguisé', () => {
    expect(detectImage(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>'))).toBeNull();
    expect(detectImage(Buffer.from('%PDF-1.7'))).toBeNull();
    expect(detectImage(Buffer.from('GIF89a'))).toBeNull();
    expect(detectImage(Buffer.alloc(0))).toBeNull();
  });
});
