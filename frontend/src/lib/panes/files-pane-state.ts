/**
 * Pure rules for what a Files pane has open. The pane owns this state
 * privately — nothing outside it can observe the relationship between the
 * tree and the splits, which is the whole point of the self-contained-pane
 * design.
 *
 * `maxSplits` is the width-derived cap from `pane-fit.ts`'s `splitsThatFit`,
 * never a constant: a narrow pane genuinely holds fewer splits than a wide one.
 * `SPLIT_CAP` is the absolute ceiling underneath it — these functions are the
 * only things that decide how many paths a Files descriptor carries, and a
 * three-path descriptor serializes to `files:<mount>/a|b|c`, which
 * `parsePaneParam` rejects outright. The pane would not render narrow; it
 * would vanish from the URL. So every path-producing branch clamps to
 * `min(SPLIT_CAP, maxSplits)` rather than trusting its caller's number.
 *
 * THE FIRST FILE IS NOT SUBJECT TO THAT CAP. `maxSplits` answers "how many
 * files fit side by side", and a pane with none open is not asking that
 * question. Treating a 0 there as "open nothing" made the pane's own tree
 * inert on every laptop: a split needs `TREE_W + SPLIT_MIN` = 480px of PANE,
 * which a SIDE pane in a two-pane row — `0.4 * (window - 239)`, the arithmetic
 * written out in `pane-fit.ts`'s header — does not reach until a 1439px
 * window; and at the 540px this cost before `SPLIT_MIN` dropped to 240, not
 * until 1589px. Against THAT figure both 1280x800 and 1440x900 were below the
 * line, so every click in the tree silently did nothing and the pane sat on
 * "Pick a file to read it." forever. Against 480 a 1440 now clears it by four
 * tenths of a pixel; 1280 still does not, and neither does anything narrower.
 * The one escape (hiding the tree) removed the thing you would click. A
 * cramped first split is a real reading surface; an inert navigator is not.
 */
export const SPLIT_CAP = 2;

/** How many splits may actually exist: the width allowance, never above the hard cap. */
function effectiveCap(maxSplits: number): number {
  return Math.min(SPLIT_CAP, maxSplits);
}

/** A tree click. Replaces the first split; an already-open file is left where it is. */
export function openInFirst(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  const cap = effectiveCap(maxSplits);
  // The first file always lands — see the module header. The width cap governs
  // how many files sit BESIDE each other, never whether the pane may show one.
  if (paths.length === 0) return [path];
  // A pane that already shows a file keeps showing one even at cap 0 — the
  // click has to land somewhere. It just never gains a split.
  return [path, ...paths.slice(1)].slice(0, Math.max(1, cap));
}

/**
 * The row's "open beside" affordance. Adds a second split, or replaces it when
 * full — and on an empty pane it is simply an open, under the same floor
 * `openInFirst` applies: it is the same click on the same row, and it must not
 * be the one that silently does nothing.
 */
export function openAsSecond(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  const cap = effectiveCap(maxSplits);
  if (paths.length === 0) return [path];
  if (paths.length < cap) return [...paths, path];
  return [...paths.slice(0, Math.max(0, cap - 1)), path];
}

/**
 * Whether the tree row's "Open beside" can do what its name says.
 *
 * False in exactly one case: the pane already shows a file and is too narrow
 * to hold a second, where `openAsSecond` REPLACES the split the control was
 * meant to sit beside. A side pane needs a 2039px window before two splits
 * and a tree fit, so this is not a corner case — without it the only remaining
 * way to open a second split is a control that silently destroys what you were
 * reading, the precise cost the ＋ Split button was deleted for. The row disables itself and says why
 * instead, matching the rule the spec already sets for `＋ Pane`.
 *
 * Two cases that look similar are deliberately TRUE:
 *   - an empty pane — there is nothing to sit beside yet, so the click is
 *     simply an open, under the same first-file floor `openInFirst` takes;
 *   - a full pane at a width that genuinely holds two — replacing the SECOND
 *     split is `openAsSecond`'s designed behaviour, not a surprise.
 */
export function canOpenBeside(paths: string[], maxSplits: number): boolean {
  return paths.length === 0 || effectiveCap(maxSplits) >= 2;
}

export function closeSplit(paths: string[], index: number): string[] {
  if (index < 0 || index >= paths.length) return paths;
  return paths.filter((_, i) => i !== index);
}
