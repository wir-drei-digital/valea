import { describe, expect, it } from 'vitest';
import { icmToNav, encodePath, type IcmNode } from './nav';

const tree: IcmNode[] = [
  {
    name: 'Tone & Voice',
    path: 'Tone & Voice',
    type: 'folder',
    pageCount: 2,
    children: [
      { name: 'Email Tone Guide', path: 'Tone & Voice/Email Tone Guide.md', type: 'page', uri: 'icm://Tone & Voice/Email Tone Guide.md' }
    ]
  }
];

describe('icmToNav', () => {
  it('maps folders with counts and encoded hrefs', () => {
    const nav = icmToNav(tree);
    expect(nav[0].label).toBe('Tone & Voice');
    expect(nav[0].count).toBe(2);
    expect(nav[0].children?.[0].href).toBe('/knowledge/Tone%20%26%20Voice/Email%20Tone%20Guide.md');
  });
});

describe('encodePath', () => {
  it('encodes segments but keeps separators', () => {
    expect(encodePath('A B/C&D.md')).toBe('A%20B/C%26D.md');
  });
});
