import { describe, it, expect } from 'vitest';
import { linkDestination, pickerItems, parentOf, filterSameMount, type SearchResult } from './page-link';

function result(overrides: Partial<SearchResult> = {}): SearchResult {
	return {
		path: 'Notes/A.md',
		mount: 'main',
		title: 'A',
		snippet: 'snippet',
		terms: ['a'],
		...overrides
	};
}

describe('linkDestination', () => {
	it('links a same-directory sibling with no leading ../', () => {
		expect(linkDestination('Notes/A.md', 'Notes/Sibling.md')).toBe('Sibling.md');
	});

	it('links a cross-folder page with one ../ hop', () => {
		expect(linkDestination('Notes/A.md', 'Offers/X.md')).toBe('../Offers/X.md');
	});

	it('links between distant top-level folders within one ICM (multiple ../ hops)', () => {
		expect(linkDestination('first/Sub/A.md', 'second/C.md')).toBe('../../second/C.md');
	});

	it('links a root-level source to a nested target', () => {
		expect(linkDestination('A.md', 'Notes/B.md')).toBe('Notes/B.md');
	});

	it('links a nested source to a root-level target', () => {
		expect(linkDestination('Notes/A.md', 'B.md')).toBe('../B.md');
	});

	it('computes a destination scoped entirely within one ICM (e.g. "coaching"), using ordinary relative path math for every case', () => {
		// sourcePath/targetPath are both ICM-relative within the SAME mountKey — the
		// caller (page_link_suggestion.js) scopes icmSearch/createIcmPage to
		// pagePath's own mountKey before either ever reaches this function, so
		// there is no "external mount" case to special-case here.
		expect(linkDestination('Sessions/Week1.md', 'Templates/Intake Form.md')).toBe(
			'../Templates/Intake Form.md'
		);
	});

	it('never treats a leading slash as a vocabulary tag — Task 9.6 removed the external-mount absolute-path fork', () => {
		// A leading slash is just an ordinary (if unusual) path character now;
		// every real path is ICM-relative within its own mountKey. This guards
		// against the old fork (return targetPath verbatim) coming back.
		expect(linkDestination('Notes/A.md', '/Offers/B.md')).toBe('../Offers/B.md');
	});

	it('preserves spaces in the destination (the <> wrapping is the converter’s job, not this)', () => {
		expect(linkDestination('Notes/A.md', 'Offers/My Offer.md')).toBe('../Offers/My Offer.md');
	});

	it('preserves spaces on a same-directory link too', () => {
		expect(linkDestination('Notes/A.md', 'Notes/My Page.md')).toBe('My Page.md');
	});
});

describe('filterSameMount', () => {
	// Fix-wave Finding 1 (task-9.6-report.md): `icm_search` scopes to the
	// primary ICM PLUS every ICM it declares related (`Valea.ICM.Search`,
	// search.ex:11-14, Task 5.6) — each hit carries its OWN `mount`. Markdown
	// links inside an ICM are ICM-relative and cannot address another mount
	// (the portability invariant), so the `[[`/`@` picker must only ever
	// offer results from the page's OWN mount.
	it('keeps only results whose mount matches the page being edited', () => {
		const sameMount = result({ path: 'Sibling.md', mount: 'primary' });
		const otherMount = result({ path: 'Related.md', mount: 'related-icm' });
		expect(filterSameMount([sameMount, otherMount], 'primary')).toEqual([sameMount]);
	});

	it('returns an empty array when every result is from a different mount', () => {
		const otherMount = result({ path: 'Related.md', mount: 'related-icm' });
		expect(filterSameMount([otherMount], 'primary')).toEqual([]);
	});

	it('preserves result order and all fields for same-mount hits', () => {
		const a = result({ path: 'A.md', mount: 'primary', title: 'A' });
		const b = result({ path: 'B.md', mount: 'primary', title: 'B' });
		expect(filterSameMount([a, b], 'primary')).toEqual([a, b]);
	});

	it('returns an empty array for an empty results list', () => {
		expect(filterSameMount([], 'primary')).toEqual([]);
	});
});

describe('pickerItems', () => {
	it('maps search results to page items, preserving fields', () => {
		const r = result({ path: 'Notes/A.md', title: 'A' });
		expect(pickerItems([r], 'a')).toEqual([{ ...r, kind: 'page' }]);
	});

	it('appends a create item when the query is non-empty and no result title matches exactly', () => {
		const r = result({ title: 'Alpha' });
		expect(pickerItems([r], 'Beta')).toEqual([
			{ ...r, kind: 'page' },
			{ kind: 'create', title: 'Create "Beta"', query: 'Beta' }
		]);
	});

	it('appends a create item when there are no results at all and the query is non-empty', () => {
		expect(pickerItems([], 'New Page')).toEqual([
			{ kind: 'create', title: 'Create "New Page"', query: 'New Page' }
		]);
	});

	it('omits the create item when a result title matches the query exactly', () => {
		const r = result({ title: 'Meeting Notes' });
		expect(pickerItems([r], 'Meeting Notes')).toEqual([{ ...r, kind: 'page' }]);
	});

	it('omits the create item on an exact-title match case-insensitively', () => {
		const r = result({ title: 'Meeting Notes' });
		expect(pickerItems([r], 'meeting notes')).toEqual([{ ...r, kind: 'page' }]);
	});

	it('omits the create item entirely when the query is empty', () => {
		const r = result({ title: 'Alpha' });
		expect(pickerItems([r], '')).toEqual([{ ...r, kind: 'page' }]);
	});

	it('omits the create item when the query is only whitespace', () => {
		const r = result({ title: 'Alpha' });
		expect(pickerItems([r], '   ')).toEqual([{ ...r, kind: 'page' }]);
	});

	it('trims the query used for the create item title/query fields', () => {
		expect(pickerItems([], '  New Page  ')).toEqual([
			{ kind: 'create', title: 'Create "New Page"', query: 'New Page' }
		]);
	});
});

describe('parentOf', () => {
	it('returns the directory of a nested workspace-relative page', () => {
		expect(parentOf('Notes/A.md')).toBe('Notes');
	});

	it('returns an empty string for a root-level page', () => {
		expect(parentOf('A.md')).toBe('');
	});
});
