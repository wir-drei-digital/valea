import { describe, it, expect } from 'vitest';
import { parseCsv, sniffDelimiter, csvGrid, wrapColumns } from './csv';

describe('parseCsv', () => {
  it('splits plain records and drops the trailing newline', () => {
    expect(parseCsv('a,b\n1,2\n')).toEqual([
      ['a', 'b'],
      ['1', '2']
    ]);
    expect(parseCsv('a,b\r\n1,2\r\n')).toEqual([
      ['a', 'b'],
      ['1', '2']
    ]);
  });

  it('keeps delimiters, newlines and doubled quotes inside a quoted field', () => {
    expect(parseCsv('"a,b","line\none","say ""hi"""')).toEqual([['a,b', 'line\none', 'say "hi"']]);
  });

  it('keeps empty fields, including a trailing one', () => {
    expect(parseCsv('a,,c\n,,\n')).toEqual([
      ['a', '', 'c'],
      ['', '', '']
    ]);
  });

  it('treats a quote inside an unquoted field as literal text', () => {
    expect(parseCsv('12" pipe,ok')).toEqual([['12" pipe', 'ok']]);
  });

  it('strips a UTF-8 BOM off the first header cell', () => {
    expect(parseCsv('﻿name,qty')).toEqual([['name', 'qty']]);
  });

  it('returns no records for an empty file', () => {
    expect(parseCsv('')).toEqual([]);
    // A lone newline is one empty record, not zero and not two.
    expect(parseCsv('\n')).toEqual([['']]);
  });
});

describe('sniffDelimiter', () => {
  it('picks the separator the first record actually uses', () => {
    expect(sniffDelimiter('a;b;c\n1;2;3')).toBe(';');
    expect(sniffDelimiter('a\tb\tc')).toBe('\t');
    expect(sniffDelimiter('a,b,c')).toBe(',');
  });

  it('ignores candidates inside quotes, and falls back to comma', () => {
    expect(sniffDelimiter('"a;b;c",d')).toBe(',');
    expect(sniffDelimiter('single-column')).toBe(',');
    expect(sniffDelimiter('')).toBe(',');
  });
});

describe('csvGrid', () => {
  it('takes the first record as the header and pads ragged rows', () => {
    expect(csvGrid('name,qty,note\na,1\nb,2,ok,extra')).toEqual({
      header: ['name', 'qty', 'note', ''],
      rows: [
        ['a', '1', '', ''],
        ['b', '2', 'ok', 'extra']
      ],
      columns: 4,
      delimiter: ','
    });
  });

  it('reports an empty file as an empty grid', () => {
    expect(csvGrid('')).toEqual({ header: [], rows: [], columns: 0, delimiter: ',' });
  });
});

describe('wrapColumns', () => {
  it('only lets a column wrap when something in it is genuinely long', () => {
    const grid = csvGrid(
      'id,issued,note\n2026-001,2026-01-14,"a note long enough that it has to wrap somewhere"\n'
    );
    expect(wrapColumns(grid)).toEqual([false, false, true]);
  });

  it('counts the header too, and reports nothing for an empty grid', () => {
    const grid = csvGrid('a-deliberately-long-header-cell,b\n1,2\n');
    expect(wrapColumns(grid)).toEqual([true, false]);
    expect(wrapColumns(csvGrid(''))).toEqual([]);
  });
});
