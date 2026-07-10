/**
 * Runs `onBeforeMutate` (if provided) to completion before invoking `run`.
 *
 * Used by RenameDialog/DeleteDialog: when the entry being renamed/deleted is
 * the page currently open in the editor, the route passes `() =>
 * store.flush()` as `onBeforeMutate` so a pending debounced edit lands on
 * disk at the OLD path before the rename/delete API call fires — otherwise
 * the in-memory edit is silently lost (the debounce timer that would have
 * saved it is torn down with the old path/store). A no-op passthrough when
 * `onBeforeMutate` is undefined — the common case for list/tree rows that
 * are not the currently open page, which have no pending edit to lose.
 */
export async function withBeforeMutate<T>(
  onBeforeMutate: (() => Promise<void>) | undefined,
  run: () => Promise<T>
): Promise<T> {
  if (onBeforeMutate) {
    await onBeforeMutate();
  }
  return run();
}
