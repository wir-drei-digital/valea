import { describe, it, expect } from 'vitest';
import { linkDestination, pickerItems, parentOf, type SearchResult } from './page-link';

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

	it('links across embedded mounts (both workspace-relative, different mount-prefix segments)', () => {
		expect(linkDestination('first/Sub/A.md', 'second/C.md')).toBe('../../second/C.md');
	});

	it('links a root-level source to a nested target', () => {
		expect(linkDestination('A.md', 'Notes/B.md')).toBe('Notes/B.md');
	});

	it('links a nested source to a root-level target', () => {
		expect(linkDestination('Notes/A.md', 'B.md')).toBe('../B.md');
	});

	it('returns an absolute target verbatim when the source is workspace-relative', () => {
		expect(linkDestination('Notes/A.md', '/Users/daniel/External/B.md')).toBe(
			'/Users/daniel/External/B.md'
		);
	});

	it('returns an absolute target verbatim when the source is also absolute', () => {
		expect(linkDestination('/Users/daniel/External/A.md', '/Users/daniel/External/B.md')).toBe(
			'/Users/daniel/External/B.md'
		);
	});

	it('returns a workspace-relative target verbatim when the source is absolute (non-portable cross-boundary case)', () => {
		expect(linkDestination('/Users/daniel/External/A.md', 'Notes/B.md')).toBe('Notes/B.md');
	});

	it('preserves spaces in the destination (the <> wrapping is the converter’s job, not this)', () => {
		expect(linkDestination('Notes/A.md', 'Offers/My Offer.md')).toBe('../Offers/My Offer.md');
	});

	it('preserves spaces on a same-directory link too', () => {
		expect(linkDestination('Notes/A.md', 'Notes/My Page.md')).toBe('My Page.md');
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

	it('returns the directory of an absolute (external-mount) page', () => {
		expect(parentOf('/Users/daniel/External/Clients/Acme.md')).toBe('/Users/daniel/External/Clients');
	});
});
