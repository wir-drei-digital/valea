/**
 * Shared line-diff engine — LCS over lines, capped for render safety.
 * Used by PermissionCard (B11, single edit/write diff) and the queue card's
 * memory-update review (B12, same DiffRow shape). Small inputs only (editor
 * pages, tool params): the O(m*n) DP table is fine at the sizes agent tool
 * calls and mount pages run at, not intended for large-file diffing.
 */
export type DiffRow = { type: 'ctx' | 'add' | 'del'; text: string };

/** LCS-based line diff. Small inputs only (editor pages, tool params). */
export function lineDiff(
  oldText: string,
  newText: string,
  cap = 400
): { rows: DiffRow[]; truncated: boolean } {
  const a = oldText === '' ? [] : oldText.split('\n');
  const b = newText === '' ? [] : newText.split('\n');
  const m = a.length;
  const n = b.length;

  const MAX_LCS_CELLS = 4_000_000; // ~2000×2000 lines — beyond this, skip LCS

  // Oversized inputs skip the LCS pass entirely: render as bounded
  // delete-then-add so the dialog stays responsive on agent-sized payloads.
  if ((m + 1) * (n + 1) > MAX_LCS_CELLS) {
    const rows: DiffRow[] = [
      ...a.map((text) => ({ type: 'del' as const, text })),
      ...b.map((text) => ({ type: 'add' as const, text }))
    ];
    return { rows: rows.slice(0, cap), truncated: true };
  }

  // DP table of LCS lengths
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array<number>(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const rows: DiffRow[] = [];
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (a[i] === b[j]) {
      rows.push({ type: 'ctx', text: a[i] });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      rows.push({ type: 'del', text: a[i] });
      i++;
    } else {
      rows.push({ type: 'add', text: b[j] });
      j++;
    }
  }
  while (i < m) rows.push({ type: 'del', text: a[i++] });
  while (j < n) rows.push({ type: 'add', text: b[j++] });

  if (rows.length > cap) return { rows: rows.slice(0, cap), truncated: true };
  return { rows, truncated: false };
}
