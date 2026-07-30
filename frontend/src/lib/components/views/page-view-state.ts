/**
 * Which top-level state `MarkdownPageView` renders (issue #2 §4): only the
 * backend's explicit `not_found` may claim the page is gone — every other
 * failure (channel timeout, workspace_changed, transport error) says nothing
 * about the file's existence and renders as `'load-failed'` (couldn't load +
 * retry) instead of a false "doesn't exist anymore".
 */
export function pageViewState(args: {
  loading: boolean;
  /** The failed `icm_page` fetch's error, `null` when it succeeded (or hasn't run). */
  loadError: string | null;
  hasContent: boolean;
}): 'loading' | 'gone' | 'load-failed' | 'ready' {
  if (args.loading || (!args.hasContent && !args.loadError)) return 'loading';
  if (args.loadError === 'not_found') return 'gone';
  if (args.loadError) return 'load-failed';
  return 'ready';
}
