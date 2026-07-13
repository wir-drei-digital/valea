import { describe, it, expect } from 'vitest';
import { allowedImageFiles, isAllowedImage, resolveImageSrc, joinRelative } from './image-upload';

function makeFile(name: string, type: string): File {
  return new File(['x'], name, { type });
}

describe('joinRelative', () => {
  it('resolves a relative-from-page path lexically (workspace-relative page dir)', () => {
    expect(joinRelative('mounts/m/Clients', '../Assets/x.png')).toBe('mounts/m/Assets/x.png');
  });

  it('resolves a relative-from-page path lexically (absolute page dir, external mount)', () => {
    expect(joinRelative('/Users/daniel/External/Clients', '../Assets/x.png')).toBe(
      '/Users/daniel/External/Assets/x.png'
    );
  });

  it('handles a same-directory reference with no leading ../', () => {
    expect(joinRelative('mounts/m/Clients', 'Assets/x.png')).toBe('mounts/m/Clients/Assets/x.png');
  });

  it('handles multiple ../ segments', () => {
    expect(joinRelative('mounts/m/Clients/Nested', '../../Assets/x.png')).toBe('mounts/m/Assets/x.png');
  });

  it('drops "." segments', () => {
    expect(joinRelative('mounts/m/Clients', './Assets/x.png')).toBe('mounts/m/Clients/Assets/x.png');
  });

  it('treats an empty page dir (top-level page) as the workspace root', () => {
    expect(joinRelative('', 'Assets/x.png')).toBe('Assets/x.png');
  });
});

describe('resolveImageSrc', () => {
  it('maps a relative on-disk src to /files/raw with the resolved, encoded workspace path', () => {
    expect(resolveImageSrc('../Assets/x.png', 'mounts/m/Clients/Acme.md')).toBe(
      '/files/raw?path=mounts%2Fm%2FAssets%2Fx.png'
    );
  });

  it('maps an absolute on-disk src (external mount) to /files/raw unchanged apart from encoding', () => {
    expect(resolveImageSrc('/Users/daniel/External/Assets/x.png', '/Users/daniel/External/Clients/Acme.md')).toBe(
      '/files/raw?path=' + encodeURIComponent('/Users/daniel/External/Assets/x.png')
    );
  });

  it('leaves an http(s) src unchanged', () => {
    expect(resolveImageSrc('https://example.com/pic.png', 'mounts/m/Clients/Acme.md')).toBe(
      'https://example.com/pic.png'
    );
  });

  it('leaves a data: src unchanged', () => {
    const dataUri = 'data:image/png;base64,AAAA';
    expect(resolveImageSrc(dataUri, 'mounts/m/Clients/Acme.md')).toBe(dataUri);
  });

  it('leaves an http src (non-s) unchanged too', () => {
    expect(resolveImageSrc('http://example.com/pic.png', 'mounts/m/Clients/Acme.md')).toBe(
      'http://example.com/pic.png'
    );
  });

  it('resolves a top-level page (no parent folder) correctly', () => {
    expect(resolveImageSrc('Assets/x.png', 'Welcome.md')).toBe('/files/raw?path=Assets%2Fx.png');
  });
});

describe('isAllowedImage', () => {
  it.each([
    ['photo.png', 'image/png'],
    ['photo.jpg', 'image/jpeg'],
    ['photo.jpeg', 'image/jpeg'],
    ['photo.gif', 'image/gif'],
    ['photo.webp', 'image/webp']
  ])('allows %s with matching content type %s', (name, type) => {
    expect(isAllowedImage(makeFile(name, type))).toBe(true);
  });

  it('is case-insensitive on the extension', () => {
    expect(isAllowedImage(makeFile('PHOTO.PNG', 'image/png'))).toBe(true);
  });

  it('rejects SVG even with a plausible image content type', () => {
    expect(isAllowedImage(makeFile('vector.svg', 'image/svg+xml'))).toBe(false);
  });

  it('rejects a mismatched extension/content-type pair', () => {
    expect(isAllowedImage(makeFile('photo.png', 'text/plain'))).toBe(false);
  });

  it('rejects a non-image file entirely', () => {
    expect(isAllowedImage(makeFile('notes.md', 'text/markdown'))).toBe(false);
  });

  it('rejects a file with an unlisted extension', () => {
    expect(isAllowedImage(makeFile('photo.bmp', 'image/bmp'))).toBe(false);
  });
});

describe('allowedImageFiles', () => {
  it('keeps only the allowed images out of a mixed batch (png + svg + text)', () => {
    const png = makeFile('photo.png', 'image/png');
    const svg = makeFile('vector.svg', 'image/svg+xml');
    const text = makeFile('notes.md', 'text/markdown');
    expect(allowedImageFiles([svg, png, text])).toEqual([png]);
  });

  it('keeps every allowed image when the whole batch qualifies, preserving order', () => {
    const first = makeFile('a.png', 'image/png');
    const second = makeFile('b.jpg', 'image/jpeg');
    const third = makeFile('c.gif', 'image/gif');
    expect(allowedImageFiles([first, second, third])).toEqual([first, second, third]);
  });

  it('does not let a disallowed file earlier in the batch block an allowed one later', () => {
    const svg = makeFile('vector.svg', 'image/svg+xml');
    const png = makeFile('photo.png', 'image/png');
    expect(allowedImageFiles([svg, png])).toEqual([png]);
  });

  it('returns an empty array when nothing in the batch is allowed', () => {
    const svg = makeFile('vector.svg', 'image/svg+xml');
    const text = makeFile('notes.md', 'text/markdown');
    expect(allowedImageFiles([svg, text])).toEqual([]);
  });

  it('returns an empty array for an empty batch', () => {
    expect(allowedImageFiles([])).toEqual([]);
  });
});
