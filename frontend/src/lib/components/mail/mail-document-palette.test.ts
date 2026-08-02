import { describe, it, expect } from 'vitest';
import { MAIL_DOCUMENT_PALETTE } from './mail-document-palette';
import { contrastRatio } from '$lib/design/contrast';

describe('MAIL_DOCUMENT_PALETTE', () => {
  it('is a light sheet regardless of app theme', () => {
    expect(MAIL_DOCUMENT_PALETTE.background).toBe('#ffffff');
  });

  it('every ink on the sheet is readable', () => {
    for (const ink of [MAIL_DOCUMENT_PALETTE.ink, MAIL_DOCUMENT_PALETTE.link]) {
      expect(contrastRatio(ink, MAIL_DOCUMENT_PALETTE.background)).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('is all literal hex — the iframe cannot resolve var()', () => {
    for (const value of Object.values(MAIL_DOCUMENT_PALETTE)) {
      expect(value).toMatch(/^#[0-9a-f]{6}$/);
    }
  });
});
