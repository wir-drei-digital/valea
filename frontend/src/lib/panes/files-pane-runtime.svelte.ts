/**
 * Per-Files-pane runtime state, created by `PaneHost` and shared between the
 * header controls and the pane body. Pure rules live in `files-pane-state.ts`;
 * this is only the reactive container.
 *
 * It lives in the HOST rather than in the pane because `PaneHost` renders the
 * pane header before mounting the view, so a pane cannot hand stateful chrome
 * upward to an already-rendering parent. One instance per mounted pane — two
 * Files panes never share a `maxSplits` or an auto-open claim. Only the tree
 * preference is shared, and that goes through `pane-memory`, not through here.
 */
import { loadChrome, saveChrome } from './pane-memory';
import type { PaneDescriptor } from './pane-route';

export class FilesPaneState {
  kind = 'files' as const;
  treeVisible = $state(loadChrome().files.tree);
  /** Width-derived split cap, written by the pane body once it knows its width. */
  maxSplits = $state(2);
  /** Which split auto-open claimed; see `auto-open.ts`. */
  autoIndex = $state<number | null>(null);
  /** Set by the body so the header's ＋ Split can drive it. */
  addSplit: (() => void) | null = $state(null);

  toggleTree(): void {
    this.treeVisible = !this.treeVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, files: { tree: this.treeVisible } });
  }
}

export function createFilesPaneState(_descriptor: PaneDescriptor): FilesPaneState {
  return new FilesPaneState();
}
