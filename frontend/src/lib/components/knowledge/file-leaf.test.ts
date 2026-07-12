import { describe, expect, it } from 'vitest';
import { fileLeafKind, fileLeafLabel } from './file-leaf';

describe('fileLeafKind', () => {
  it('maps image extensions to "image"', () => {
    expect(fileLeafKind('.png')).toBe('image');
    expect(fileLeafKind('.jpg')).toBe('image');
    expect(fileLeafKind('.jpeg')).toBe('image');
    expect(fileLeafKind('.gif')).toBe('image');
    expect(fileLeafKind('.webp')).toBe('image');
    expect(fileLeafKind('.svg')).toBe('image');
  });

  it('maps .pdf to "pdf"', () => {
    expect(fileLeafKind('.pdf')).toBe('pdf');
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

describe('fileLeafLabel', () => {
  it('renders the ext as an uppercase label without the dot', () => {
    expect(fileLeafLabel('.pdf')).toBe('PDF');
    expect(fileLeafLabel('.png')).toBe('PNG');
  });

  it('falls back to "FILE" for a missing/blank ext', () => {
    expect(fileLeafLabel(undefined)).toBe('FILE');
    expect(fileLeafLabel('')).toBe('FILE');
    expect(fileLeafLabel('.')).toBe('FILE');
  });
});
