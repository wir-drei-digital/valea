/**
 * Per-Files-pane runtime state, created by `PaneHost` and shared between the
 * header controls and the pane body. Pure rules live in `files-pane-state.ts`;
 * this is only the reactive container.
 *
 * It lives in the HOST rather than in the pane because `PaneHost` renders the
 * pane header before mounting the view, so a pane cannot hand stateful chrome
 * upward to an already-rendering parent. One instance per mounted pane — two
 * Files panes never share an auto-open claim. Only the tree preference is
 * shared, and that goes through `pane-memory`, not through here.
 *
 * It carries no width FIGURE and no add-split action: both existed for a header
 * "open a second file" button that was removed, because a header control has no
 * file to name and could only guess one. What DOES cross back up is a reason or
 * an action, never a measurement — `treeBlocked`, `compareBlocked`, and the two
 * handler slots the header's controls call, all of which exist because the
 * control lives in the header while the thing it governs lives in the body.
 *
 * The TAB STRIP is in the header band too (it is the pane's title now), so
 * `pendingTab` lives here rather than in the body: both halves render it.
 */
import { loadChrome, saveChrome } from './pane-memory';
import type { PaneDescriptor } from './pane-route';

export class FilesPaneState {
  kind = 'files' as const;
  treeVisible = $state(loadChrome().files.tree);
  /** Which split auto-open claimed; see `auto-open.ts`. */
  autoIndex = $state<number | null>(null);
  /**
   * The file that was IN the claimed split when the claim was made.
   *
   * The claim is an index, and `paths` is rewritten by things no split-removal
   * hook can see: navigating this route to a different file or a different
   * ICM (the primary Files surface outlives every one of those navigations),
   * Back, a hand-edited URL. A claim that survived one of those would name
   * whatever now sits in that slot, and the next assistant read would overwrite
   * a file the user put there — the exact eviction the rule exists to prevent.
   *
   * So an index that no longer holds this file is not a claim, it is a
   * coincidence, and `FilesPane` refuses it. It does not replace `shiftAuto`:
   * that MOVES the claim through a removal the pane did see, which keeps
   * recycling working where this check alone would give up.
   */
  autoPath = $state<string | null>(null);

  /**
   * Why the tree cannot be shown right now, or `null` when it can.
   *
   * Written by the pane BODY, which is the only thing that can measure the
   * pane, and read by the header control, which sits in `PaneHost`'s header and
   * can measure nothing. That is the same header/body bridge `treeVisible`
   * already is, in the other direction — and it is what keeps the toggle from
   * lying: with a file open in a pane too narrow for `TREE_W + SPLIT_MIN` the
   * body hides the tree regardless of the preference, and a button still
   * reading "Hide the file tree", `aria-pressed="true"`, over no tree is worse
   * than a disabled one, because it names a state that is not on screen.
   */
  treeBlocked = $state<string | null>(null);

  /**
   * The compare escape, written by the pane BODY for the same reason
   * `treeBlocked` is: the header holds the control and can measure nothing.
   *
   * `compareShown` is what is ON SCREEN, never the descriptor — below the
   * width threshold the body falls back to the active tab alone without
   * rewriting the URL, so a control reading the descriptor would announce
   * `aria-pressed="true"` over a single column.
   */
  compareShown = $state(false);
  /** Why compare cannot act — too narrow, or fewer than two tabs — or `null`. */
  compareBlocked = $state<string | null>(null);
  /**
   * A tab the user asked for but has not filled yet — ＋, then a file.
   *
   * Deliberately not in the URL: it holds nothing, so there is nothing to
   * address, and a reload legitimately loses it. At most one exists at a time,
   * so ＋ while one is waiting is a no-op rather than a strip full of identical
   * empty chips. While it is showing, NOTHING is on screen — no tab chip and no
   * tree row may read as current.
   */
  pendingTab = $state(false);

  /**
   * Registered by the pane body, which owns every descriptor rewrite. The
   * header cannot do any of them itself: it never sees `PaneContext`.
   */
  toggleCompare = $state<(() => void) | null>(null);
  showTab = $state<((index: number) => void) | null>(null);
  closeTab = $state<((index: number) => void) | null>(null);

  /** What is actually rendered: the preference, unless the width overrides it. */
  get treeShown(): boolean {
    return this.treeVisible && this.treeBlocked === null;
  }

  toggleTree(): void {
    // Matches the `aria-disabled` control: the guard covers pointer AND
    // keyboard activation, which an `aria-disabled` button still receives.
    if (this.treeBlocked !== null) return;
    this.treeVisible = !this.treeVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, files: { tree: this.treeVisible } });
  }
}

export function createFilesPaneState(_descriptor: PaneDescriptor): FilesPaneState {
  return new FilesPaneState();
}
