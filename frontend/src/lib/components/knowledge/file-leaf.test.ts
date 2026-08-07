import { describe, expect, it } from 'vitest';
import { fileLeafKind } from './file-leaf';

describe('fileLeafKind', () => {
  it('maps image extensions to "image"', () => {
    expect(fileLeafKind('.png')).toBe('image');
    expect(fileLeafKind('.jpg')).toBe('image');
    expect(fileLeafKind('.jpeg')).toBe('image');
    expect(fileLeafKind('.gif')).toBe('image');
    expect(fileLeafKind('.webp')).toBe('image');
  });

  // Final review, I1: `.svg` used to land here, so `FileView` mounted the
  // token-free `<img>` viewer for it — but `/files/raw` exempts only the
  // extensions above, so the request 404'd and the pane showed a broken
  // image glyph with no explanation. It belongs to the tokened text viewer,
  // which is also the only way it renders inertly (`text/plain` + nosniff).
  it('does NOT treat .svg as an image — it is served as inert text', () => {
    expect(fileLeafKind('.svg')).toBe('other');
  });

  it('maps .pdf to "pdf"', () => {
    expect(fileLeafKind('.pdf')).toBe('pdf');
  });

  it('maps .csv to "csv" — and no other separated-values ext', () => {
    expect(fileLeafKind('.csv')).toBe('csv');
    expect(fileLeafKind('.tsv')).toBe('other');
  });

  it('maps anything else (or a missing ext) to "other"', () => {
    expect(fileLeafKind('.docx')).toBe('other');
    expect(fileLeafKind('.zip')).toBe('other');
    expect(fileLeafKind('')).toBe('other');
    expect(fileLeafKind(undefined)).toBe('other');
  });

  it('is case-insensitive defensively, even though the backend already lowercases', () => {
    expect(fileLeafKind('.PDF')).toBe('pdf');
    expect(fileLeafKind('.PNG')).toBe('image');
  });
});
