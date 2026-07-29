import { describe, expect, it } from 'vitest';
import { rawFileHeaders, rawFileUrl } from './raw-url';
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

describe('rawFileHeaders', () => {
  it('carries the control token under the same header name the RPC fallback uses', () => {
    expect(rawFileHeaders()).toEqual({ 'x-valea-token': controlToken() });
  });

  it('sends exactly one header — nothing else leaks into a raw-file request', () => {
    expect(Object.keys(rawFileHeaders())).toEqual(['x-valea-token']);
  });
});
