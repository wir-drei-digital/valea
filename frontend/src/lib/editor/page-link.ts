/**
 * Pure logic for the `[[` / `@` page-link picker (Task C8). No I/O — the
 * impure caller is `page_link_suggestion.js` (via `PageEditor.svelte`),
 * which supplies `api.icmSearch` results here and turns `linkDestination`'s
 * output into a link mark's `href`.
 */

/** One `Valea.Api.ICM`'s `:search` action result row (see C2's `icmSearchFields`). */
export type SearchResult = {
	path: string;
	mount: string;
	title: string;
	snippet: string;
	terms: string[];
};

export type PageLinkItem = SearchResult & { kind: 'page' };
/** `query` is the raw (trimmed) search text — the picker's create handler passes it straight to `api.createIcmPage`, no re-parsing of `title`. */
export type CreateLinkItem = { kind: 'create'; title: string; query: string };
export type PickerItem = PageLinkItem | CreateLinkItem;

function dirnameOf(path: string): string {
	const idx = path.lastIndexOf('/');
	return idx === -1 ? '' : path.slice(0, idx);
}

/** Workspace-relative paths never start with `/`; absolute (external-mount) physical paths always do — that leading slash is the ONLY vocabulary tag the FE has. */
function isAbsolute(path: string): boolean {
	return path.startsWith('/');
}

/**
 * Lexical relative path from `fromDir` to `toPath` — mirrors
 * `Valea.Paths.relative/2` (backend/lib/valea/paths.ex) exactly: split both
 * on `/`, drop the common leading segments, then join one `".."` per
 * remaining `fromDir` segment with the remaining `toPath` segments. Pure
 * segment math, no filesystem access; both arguments must already be in the
 * same vocabulary (both workspace-relative, or both absolute).
 */
function relative(fromDir: string, toPath: string): string {
	const from = fromDir.split('/').filter((seg) => seg.length > 0);
	const to = toPath.split('/').filter((seg) => seg.length > 0);

	let common = 0;
	while (common < from.length && common < to.length && from[common] === to[common]) {
		common++;
	}

	const ups = new Array(from.length - common).fill('..');
	return [...ups, ...to.slice(common)].join('/');
}

/**
 * The on-disk `href` for a link from `sourcePath` (the page being edited,
 * Task C7's `pagePath`) to `targetPath` (a search result's or newly-created
 * page's `path`). Per the editor spec's path rule:
 *
 *   - both workspace-relative -> relative path from the source's directory
 *     (the `relative` math above);
 *   - `targetPath` absolute -> `targetPath` verbatim (an external-mount
 *     target is only addressable by its physical path, regardless of where
 *     the source lives);
 *   - `targetPath` workspace-relative but `sourcePath` absolute -> also
 *     `targetPath` verbatim: workspace-relative is the one vocabulary the FE
 *     has for it, and there is no physical path from an external-mount
 *     source's perspective to compute a lexical relative from. This is the
 *     non-portable cross-boundary case the spec accepts as-is (correct only
 *     for a reader inside the same workspace).
 *
 * The two "verbatim" branches collapse to the same result (return
 * `targetPath` unchanged whenever EITHER side is absolute) — spelled out
 * above because the two have different justifications, even though the code
 * is one condition.
 */
export function linkDestination(sourcePath: string, targetPath: string): string {
	if (isAbsolute(targetPath) || isAbsolute(sourcePath)) return targetPath;
	return relative(dirnameOf(sourcePath), targetPath);
}

/**
 * Maps `icm_search` results to picker menu items, appending a `create` item
 * — `Create "<query>"` — when `query` (trimmed) is non-empty and no result's
 * `title` exactly matches it (case-insensitively — "meeting notes" should
 * not offer to create a duplicate of an existing "Meeting Notes"). An empty
 * `query` never gets a create item, whether or not there are results (the
 * user hasn't typed a name to create yet).
 */
export function pickerItems(results: SearchResult[], query: string): PickerItem[] {
	const pageItems: PickerItem[] = results.map((result) => ({ ...result, kind: 'page' }));
	const trimmedQuery = query.trim();

	if (trimmedQuery === '') return pageItems;

	const hasExactTitleMatch = results.some(
		(result) => result.title.trim().toLowerCase() === trimmedQuery.toLowerCase()
	);
	if (hasExactTitleMatch) return pageItems;

	return [...pageItems, { kind: 'create', title: `Create "${trimmedQuery}"`, query: trimmedQuery }];
}

/**
 * The directory `pagePath` lives in, in `pagePath`'s own vocabulary
 * (workspace-relative or absolute) — the `parentPath` argument
 * `api.createIcmPage` expects when creating a new sibling page from the
 * picker's create-on-empty item. A root-level page (`"Welcome.md"`) has no
 * parent segment, so this returns `""` (the workspace root, matching
 * `dirnameOf`'s empty-string convention used throughout the editor's pure
 * modules, e.g. `image-upload.ts`).
 */
export function parentOf(pagePath: string): string {
	return dirnameOf(pagePath);
}
