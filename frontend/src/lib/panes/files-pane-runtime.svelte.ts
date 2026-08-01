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
 * It carries no width figure and no add-split action any more: both existed
 * for a header "open a second file" button that has been removed, because a
 * header control has no file to name and could only guess one. The pane's
 * width cap is now purely local to the pane body.
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

  toggleTree(): void {
    this.treeVisible = !this.treeVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, files: { tree: this.treeVisible } });
  }
}

export function createFilesPaneState(_descriptor: PaneDescriptor): FilesPaneState {
  return new FilesPaneState();
}
