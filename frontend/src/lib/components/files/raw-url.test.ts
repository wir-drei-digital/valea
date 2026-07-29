import { describe, expect, it } from 'vitest';
import { rawFileHeaders, rawFileOpenUrl, rawFileUrl } from './raw-url';
import { controlToken } from '$lib/socket';

describe('rawFileUrl', () => {
  it('encodes mount and path as single query params', () => {
    expect(rawFileUrl('notes', 'a b/c.pdf')).toBe('/files/raw?mount_key=notes&path=a%20b%2Fc.pdf');
  });

  it('encodes a mount key with URL-unsafe characters too', () => {
    expect(rawFileUrl('my icm', 'x.png')).toBe('/files/raw?mount_key=my%20icm&path=x.png');
  });

  it('encodes ampersands in the path so they cannot start a new query param', () => {
    expect(rawFileUrl('primary', 'Tone & Voice/logo.svg')).toBe(
      '/files/raw?mount_key=primary&path=Tone%20%26%20Voice%2Flogo.svg'
    );
  });

  it('never puts the control token in the URL — the credential rides a header', () => {
    expect(rawFileUrl('notes', 'a.pdf')).not.toContain(controlToken());
    expect(rawFileUrl('notes', 'a.pdf')).not.toContain('token');
  });
});

describe('rawFileOpenUrl', () => {
  it('is absolute against the given origin — a new tab or the OS browser has no base to resolve against', () => {
    expect(rawFileOpenUrl('mail-mara', 'views/attachments/m1/a.pdf', 'tkt', 'http://localhost:4817')).toBe(
      'http://localhost:4817/files/raw?mount_key=mail-mara&path=views%2Fattachments%2Fm1%2Fa.pdf&ticket=tkt'
    );
  });

  it('resolves against the dev origin just as happily — Vite proxies /files/raw onward', () => {
    expect(rawFileOpenUrl('mail-mara', 'views/attachments/m1/a.pdf', 'tkt', 'http://localhost:4273')).toBe(
      'http://localhost:4273/files/raw?mount_key=mail-mara&path=views%2Fattachments%2Fm1%2Fa.pdf&ticket=tkt'
    );
  });

  it('encodes the ticket as a whole param so its base64 padding cannot restructure the query', () => {
    const url = rawFileOpenUrl('mail-mara', 'a.pdf', 'SFMyNTY.g3Q=&path=/etc/passwd', 'http://x.test');
    expect(url).toContain('&ticket=SFMyNTY.g3Q%3D%26path%3D%2Fetc%2Fpasswd');
    expect(new URL(url).searchParams.get('path')).toBe('a.pdf');
  });

  it('keeps a filename with spaces and ampersands inside the path param', () => {
    const url = rawFileOpenUrl('mail-mara', 'views/attachments/m1/Q1 P&L.pdf', 'tkt', 'http://x.test');
    expect(new URL(url).searchParams.get('path')).toBe('views/attachments/m1/Q1 P&L.pdf');
    expect(new URL(url).searchParams.get('ticket')).toBe('tkt');
  });

  it('carries the ticket and never the control token — the header credential stays out of URLs', () => {
    const url = rawFileOpenUrl('mail-mara', 'a.pdf', 'tkt', 'http://x.test');
    expect(url).not.toContain(controlToken());
    expect(url).not.toContain('x-valea-token');
  });
});

describe('rawFileHeaders', () => {
  it('carries the control token under the same header name the RPC fallback uses', () => {
    expect(rawFileHeaders()).toEqual({ 'x-valea-token': controlToken() });
  });

  it('sends exactly one header — nothing else leaks into a raw-file request', () => {
    expect(Object.keys(rawFileHeaders())).toEqual(['x-valea-token']);
  });
});
