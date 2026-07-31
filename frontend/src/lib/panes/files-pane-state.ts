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
 */
import type { NavTreeItem } from '$lib/shell/nav';

export const SPLIT_CAP = 2;

/** How many splits may actually exist: the width allowance, never above the hard cap. */
function effectiveCap(maxSplits: number): number {
  return Math.min(SPLIT_CAP, maxSplits);
}

/** A tree click. Replaces the first split; an already-open file is left where it is. */
export function openInFirst(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  const cap = effectiveCap(maxSplits);
  if (paths.length === 0) return cap >= 1 ? [path] : [];
  // A pane that already shows a file keeps showing one even at cap 0 — the
  // click has to land somewhere. It just never gains a split.
  return [path, ...paths.slice(1)].slice(0, Math.max(1, cap));
}

/** The row's "open beside" affordance. Adds a second split, or replaces it when full. */
export function openAsSecond(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  const cap = effectiveCap(maxSplits);
  if (paths.length === 0) return cap >= 1 ? [path] : [];
  if (paths.length < cap) return [...paths, path];
  return [...paths.slice(0, Math.max(0, cap - 1)), path];
}

export function closeSplit(paths: string[], index: number): string[] {
  if (index < 0 || index >= paths.length) return paths;
  return paths.filter((_, i) => i !== index);
}

export function canAddSplit(paths: string[], maxSplits: number): boolean {
  return paths.length < effectiveCap(maxSplits);
}

/** A split whose file was deleted. Its sibling survives — see the spec's per-subject rule. */
export function dropVanished(paths: string[], vanished: string): string[] {
  return paths.filter((p) => p !== vanished);
}

/**
 * What the header's "Open a second file" button opens: the first leaf in the
 * pane's own tree that is not already in a split, depth-first in display
 * order. `null` when the tree offers nothing new — the button is then
 * disabled rather than dead, because a control that looks available and does
 * nothing is worse than one that says it cannot act.
 *
 * The button has no file to name (the tree row's "Open beside" is the
 * affordance that does), so the pane picks one and the user re-targets that
 * split from the tree. Unloaded folders are simply not descended into: this
 * reads the tree that is on screen and never triggers a fetch, so what the
 * button opens is always something the user can already see.
 */
export function firstUnopenedLeaf(nodes: NavTreeItem[], openPaths: string[]): string | null {
  for (const node of nodes) {
    if (node.children) {
      const found = firstUnopenedLeaf(node.children, openPaths);
      if (found !== null) return found;
      continue;
    }
    if (!openPaths.includes(node.path)) return node.path;
  }
  return null;
}
