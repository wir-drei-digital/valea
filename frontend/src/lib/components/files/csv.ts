/**
 * Pure CSV parsing for `CsvView` — same "logic in a .ts, component renders
 * it" convention as `file-leaf.ts`, so the awkward cases (quoted commas,
 * embedded newlines, ragged rows) are covered by unit tests instead of a
 * render harness.
 *
 * RFC 4180 shape, plus the two deviations real files actually carry: a UTF-8
 * BOM from Excel, and a delimiter that isn't always a comma (a
 * semicolon-separated export must not render as one giant column). Anything
 * this parser gets wrong is one click away from the raw text, which is the
 * point of the viewer's Raw toggle.
 */

export type CsvGrid = {
  /** First record — rendered as the table head. `[]` for an empty file. */
  header: string[];
  /** Every remaining record, each padded to `columns`. */
  rows: string[][];
  /** Widest record in the file; every row above is padded to it. */
  columns: number;
  /** The separator that was detected, for the viewer's summary line. */
  delimiter: string;
};

const DELIMITERS = [',', ';', '\t', '|'];

/**
 * The separator of `text`'s FIRST record — whichever candidate appears most
 * often outside quotes. Comma wins ties and empty files, so a single-column
 * file (no separator at all) still parses as one comma-separated column.
 */
export function sniffDelimiter(text: string): string {
  const counts = new Map<string, number>(DELIMITERS.map((d) => [d, 0]));
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') i++;
      else if (ch === '"') quoted = false;
      continue;
    }
    if (ch === '"') quoted = true;
    else if (ch === '\n' || ch === '\r') break;
    else if (counts.has(ch)) counts.set(ch, (counts.get(ch) ?? 0) + 1);
  }
  let best = ',';
  for (const d of DELIMITERS) {
    if ((counts.get(d) ?? 0) > (counts.get(best) ?? 0)) best = d;
  }
  return best;
}

/**
 * `text` as records of fields. Quoted fields keep their delimiters and
 * newlines; `""` inside one is a literal quote. A trailing newline ends the
 * file rather than adding an empty record.
 */
export function parseCsv(text: string, delimiter = ','): string[][] {
  const source = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const records: string[][] = [];
  let record: string[] = [];
  let field = '';
  let quoted = false;
  // Whether anything of the CURRENT record has been consumed — what keeps a
  // trailing newline from flushing a phantom empty record at EOF.
  let pending = false;

  const endField = (): void => {
    record.push(field);
    field = '';
  };
  const endRecord = (): void => {
    endField();
    records.push(record);
    record = [];
    pending = false;
  };

  for (let i = 0; i < source.length; i++) {
    const ch = source[i];

    if (quoted) {
      if (ch !== '"') field += ch;
      else if (source[i + 1] === '"') {
        field += '"';
        i++;
      } else quoted = false;
      continue;
    }

    // A quote only opens a quoted field at the START of one; anywhere else
    // it is literal text (`12" pipe`), which is what spreadsheets do too.
    if (ch === '"' && field === '') {
      quoted = true;
      pending = true;
    } else if (ch === delimiter) {
      endField();
      pending = true;
    } else if (ch === '\n' || ch === '\r') {
      endRecord();
      if (ch === '\r' && source[i + 1] === '\n') i++;
    } else {
      field += ch;
      pending = true;
    }
  }
  if (pending || field !== '' || record.length > 0) endRecord();

  return records;
}

/**
 * Which columns may WRAP: only those holding something long enough that
 * wrapping is the lesser evil. Everything else (ids, dates, amounts, short
 * codes) stays on one line, because a table that breaks "2026-01-14" across
 * two lines to buy room for a prose column has made the data harder to read,
 * not easier — and CSS alone can't tell the two kinds of column apart.
 */
export function wrapColumns(grid: Pick<CsvGrid, 'header' | 'rows' | 'columns'>, threshold = 24): boolean[] {
  return Array.from({ length: grid.columns }, (_, i) => {
    const longest = grid.rows.reduce((max, row) => Math.max(max, row[i]?.length ?? 0), 0);
    return Math.max(longest, grid.header[i]?.length ?? 0) > threshold;
  });
}

/** `text` as a rectangular grid: first record as header, every row padded to the widest. */
export function csvGrid(text: string): CsvGrid {
  const delimiter = sniffDelimiter(text);
  const records = parseCsv(text, delimiter);
  const columns = records.reduce((max, r) => Math.max(max, r.length), 0);
  const pad = (r: string[]): string[] =>
    r.length === columns ? r : [...r, ...Array<string>(columns - r.length).fill('')];

  const [header, ...rest] = records;
  return { header: header ? pad(header) : [], rows: rest.map(pad), columns, delimiter };
}
