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

  toggleTree(): void {
    this.treeVisible = !this.treeVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, files: { tree: this.treeVisible } });
  }
}

export function createFilesPaneState(_descriptor: PaneDescriptor): FilesPaneState {
  return new FilesPaneState();
}
