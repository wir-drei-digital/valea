<script lang="ts">
	// Notion-like block editor for ICM pages, built on tiptap. Lifecycle
	// pattern (host element, editor built in an untrack()-wrapped $effect,
	// destroyed on both effect cleanup and onDestroy) follows the magus
	// reference component:
	// /Users/daniel/Development/magus/frontend/src/lib/components/brain/brain-editor.svelte
	import { onDestroy, untrack } from 'svelte';
	import { Editor, Extension } from '@tiptap/core';
	import { Plugin, PluginKey } from '@tiptap/pm/state';
	import { Decoration, DecorationSet } from '@tiptap/pm/view';
	import type { Node as ProseMirrorNode } from '@tiptap/pm/model';
	import StarterKit from '@tiptap/starter-kit';
	import Placeholder from '@tiptap/extension-placeholder';
	import Link from '@tiptap/extension-link';
	import Image from '@tiptap/extension-image';
	import Typography from '@tiptap/extension-typography';
	import Table from '@tiptap/extension-table';
	import TableRow from '@tiptap/extension-table-row';
	import TableCell from '@tiptap/extension-table-cell';
	import TableHeader from '@tiptap/extension-table-header';
	import TaskList from '@tiptap/extension-task-list';
	import TaskItem from '@tiptap/extension-task-item';
	import { createBubbleMenu } from '$lib/editor/vendor/bubble_menu.js';
	import { createSlashCommand } from '$lib/editor/vendor/slash_command.js';
	import { createPageLinkSuggestion } from '$lib/editor/vendor/page_link_suggestion.js';
	import { DragHandle } from '$lib/editor/vendor/drag_handle.js';
	import { commands, type SlashCommandItem } from '$lib/editor/commands';
	import { allowedImageFiles, isAllowedImage, resolveImageSrc } from '$lib/editor/image-upload';
	import { classifyHref } from '$lib/editor/link-nav';
	import { api } from '$lib/api/client';
	import { goto } from '$app/navigation';
	import { encodePath } from '$lib/shell/nav';
	import * as Dialog from '$lib/components/ui/dialog/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import '$lib/editor/tiptap.css';

	/** ProseMirror document JSON — the wire format for page bodies. */
	type PMDoc = Record<string, unknown>;

	/**
	 * `pagePath` (Task C7) — the workspace-relative (or, for an external
	 * mount, absolute) path of the page being edited. Needed for two things:
	 * uploads are attributed to it (`api.uploadImage`, which the backend uses
	 * to pick the target mount's `Assets/` folder and compute
	 * `rel_from_page`), and the image extension's `renderHTML` resolves a
	 * stored relative `src` against it (via `resolveImageSrc`) to build the
	 * `/files/raw?path=...` URL the `<img>` actually loads.
	 *
	 * `dangling` (Task C9) — the set of resolved page-kind link targets the
	 * route has confirmed do NOT exist on disk (`collectDocLinkPaths` +
	 * `api.icmPathsExist`, recomputed on load and after each save). Drives
	 * two things here: the `link-dangling` decoration below, and the
	 * click-to-create confirm dialog. Optional/defaults empty so a caller
	 * that hasn't computed it yet (or a page with no links) just renders
	 * plainly.
	 */
	let {
		content,
		onChange,
		pagePath,
		dangling = new Set<string>()
	}: { content: PMDoc; onChange: () => void; pagePath: string; dangling?: Set<string> } = $props();

	let host = $state<HTMLElement | null>(null);
	let editor: Editor | null = null;
	// Flips true right after `editor` is assigned (see the build effect below)
	// — a plain `$state` boolean so the dangling-sync effect further down has
	// something REACTIVE to depend on. `editor` itself is a bare `let`, so an
	// effect reading it directly would never re-run when it's (re)assigned.
	let editorReady = $state(false);

	// -- dangling-link create dialog (Task C9) ---------------------------

	let createDialogOpen = $state(false);
	let createTarget = $state<{ parentDir: string; name: string; fullPath: string } | null>(null);
	let createSubmitting = $state(false);
	let createError = $state<string | null>(null);

	function basenameNoExt(path: string): string {
		const idx = path.lastIndexOf('/');
		const base = idx === -1 ? path : path.slice(idx + 1);
		return base.replace(/\.md$/i, '');
	}

	function dirnameOf(path: string): string {
		const idx = path.lastIndexOf('/');
		return idx === -1 ? '' : path.slice(0, idx);
	}

	function openCreateDialogFor(targetPath: string): void {
		createTarget = { parentDir: dirnameOf(targetPath), name: basenameNoExt(targetPath), fullPath: targetPath };
		createError = null;
		createSubmitting = false;
		createDialogOpen = true;
	}

	async function confirmCreateDanglingPage(): Promise<void> {
		if (!createTarget || createSubmitting) return;

		createSubmitting = true;
		createError = null;
		const result = await api.createIcmPage(createTarget.parentDir, createTarget.name);
		createSubmitting = false;

		if (!result.ok) {
			createError = "Couldn't create that page. Try again.";
			return;
		}

		createDialogOpen = false;
		const path = (result.data as { path: string }).path;
		void goto(`/knowledge/${encodePath(path)}`);
	}

	// Set on a failed paste/drop upload, cleared on the next successful one.
	// Deliberately local/quiet (no store plumbing) — mirrors the visual
	// language of the route's own save-error line (`text-warn-ink`, `role=
	// "alert"`) without hijacking `PageEditorStore.error`, whose 'dirty'/
	// 'saving'/'conflict' semantics are about the autosave loop, not image
	// uploads.
	let uploadError = $state<string | null>(null);

	/**
	 * Shared upload path for both paste and drop. `files` is already filtered
	 * to the allowlist (`allowedImageFiles`, called by the handlers below), so
	 * every entry here gets uploaded and inserted — a single failed upload
	 * (network error, server rejection) sets the quiet `uploadError` for that
	 * file but does not stop the rest of the batch. Uploads run sequentially
	 * (one `await` at a time, not `Promise.all`) so insertion order matches
	 * paste/drop order: `pos` starts at the paste caret / drop coordinates,
	 * then advances to `editor.state.selection.from` after each successful
	 * insert (tiptap's `insertContentAt` moves the selection to the end of
	 * the just-inserted content by default), so the next image lands right
	 * after the previous one instead of at the original position again.
	 * Clamped to the current doc size at each insert in case it shifted while
	 * an upload was in flight. On success, `attrs.src` is set to the
	 * response's `relFromPage` (the ON-DISK value; `renderHTML` maps it to a
	 * `/files/raw` URL at display time only, see the extension config below).
	 */
	async function uploadAndInsertAll(files: File[], pos: number): Promise<void> {
		for (const file of files) {
			if (!isAllowedImage(file)) continue;

			const result = await api.uploadImage(file, pagePath);
			if (!editor) return;

			if (!result.ok) {
				uploadError = "Couldn't upload the image. Try again.";
				continue;
			}

			uploadError = null;
			const insertAt = Math.min(pos, editor.state.doc.content.size);
			editor
				.chain()
				.focus()
				.insertContentAt(insertAt, { type: 'image', attrs: { src: result.data.relFromPage, alt: file.name } })
				.run();
			pos = editor.state.selection.from;
		}
	}

	export function getJSON(): PMDoc {
		return editor ? (editor.getJSON() as PMDoc) : {};
	}

	/**
	 * Replaces the document (e.g. after a reload/conflict resolution) without
	 * re-mounting the editor and without firing onChange — the `false` second
	 * argument tells tiptap not to emit an update transaction, so this can't
	 * loop back into the host's own save path.
	 */
	export function setContent(next: PMDoc): void {
		if (!editor) return;
		editor.commands.setContent(next, false);
	}

	export function focus(): void {
		editor?.commands.focus();
	}

	export function isEmpty(): boolean {
		return editor ? editor.isEmpty : true;
	}

	// Adapts commands.ts's { title, icon?, run(editor) } shape to the vendored
	// slash_command.js's expected { title, icon, command({editor, range}) }
	// shape: delete the "/" trigger range first, then apply the command's
	// own chain. Kept here (not in commands.ts) so commands.ts stays pure
	// data + editor-command runs with no knowledge of the suggestion range.
	function toSlashItems(items: SlashCommandItem[]) {
		return items.map((item) => ({
			title: item.title,
			icon: item.icon ?? '',
			command: ({ editor: ed, range }: { editor: Editor; range: { from: number; to: number } }) => {
				ed.chain().focus().deleteRange(range).run();
				item.run(ed);
			}
		}));
	}

	// -- dangling-link decoration (Task C9) -------------------------------
	//
	// A plain ProseMirror plugin (not a tiptap Mark/Node), wrapped in a
	// no-op `Extension` below so it slots into the `extensions` array like
	// everything else. Decoration-only: `state.apply` never touches
	// `tr.doc`, and the sync effect further down dispatches a meta-only
	// transaction (no steps) to refresh it — so this can never corrupt or
	// even mark dirty the page's actual content, only how a `link` mark
	// renders.
	//
	// State (not a plain closure variable) so the current dangling set
	// SURVIVES normal editing transactions: `apply` re-decorates from
	// scratch only when the sync effect hands it a fresh set via
	// `tr.setMeta`; every other transaction (typing, formatting, ...) just
	// remaps the existing decorations through `tr.mapping`, matching the
	// standard ProseMirror decoration-plugin pattern.
	const danglingLinkPluginKey = new PluginKey('link-dangling');

	function computeDanglingDecorations(doc: ProseMirrorNode, danglingPaths: Set<string>): DecorationSet {
		if (danglingPaths.size === 0) return DecorationSet.empty;

		const decorations: Decoration[] = [];
		doc.descendants((node, pos) => {
			if (!node.isText) return;
			const linkMark = node.marks.find((m) => m.type.name === 'link');
			if (!linkMark) return;

			const href = linkMark.attrs.href;
			if (typeof href !== 'string') return;

			const classification = classifyHref(href, pagePath);
			if (classification.kind === 'page' && danglingPaths.has(classification.path)) {
				decorations.push(Decoration.inline(pos, pos + node.nodeSize, { class: 'link-dangling' }));
			}
		});

		return DecorationSet.create(doc, decorations);
	}

	function createDanglingLinkExtension() {
		return Extension.create({
			name: 'danglingLinkDecoration',
			addProseMirrorPlugins() {
				return [
					new Plugin<DecorationSet>({
						key: danglingLinkPluginKey,
						state: {
							init: () => DecorationSet.empty,
							apply(tr, old) {
								const meta = tr.getMeta(danglingLinkPluginKey) as { dangling: Set<string> } | undefined;
								if (meta) return computeDanglingDecorations(tr.doc, meta.dangling);
								return old.map(tr.mapping, tr.doc);
							}
						},
						props: {
							decorations(state) {
								return danglingLinkPluginKey.getState(state);
							}
						}
					})
				];
			}
		});
	}

	/**
	 * Editor `handleClickOn` (Task C9): fires for every node containing the
	 * click position, inside-out, including the text node under the
	 * cursor — so a click on a link mark's text lands here with that mark
	 * present on `node.marks`. Reads `pagePath`/`dangling` live off the
	 * component's own props (not a closure snapshot) since this callback
	 * runs on every click, long after editor construction.
	 *
	 *  - `page`, not dangling → `goto` the existing page.
	 *  - `page`, dangling → open the create-confirm dialog instead of
	 *    navigating to a page that doesn't exist yet.
	 *  - `external` → open in a new tab (never navigate the app itself away
	 *    from the editor).
	 *  - `file` → no-op; this editor has nothing to open it with.
	 *
	 * Returns `true` (event handled) whenever the click landed on a link
	 * mark at all, even for the `file` no-op branch — this suppresses
	 * ProseMirror's/the browser's own click-through behavior on the `<a>`
	 * (harmless since `Link` is configured with `openOnClick: false`
	 * anyway, but explicit here for clarity).
	 */
	function handleLinkClick(node: ProseMirrorNode, event: MouseEvent): boolean {
		const linkMark = node.marks.find((m) => m.type.name === 'link');
		if (!linkMark) return false;

		const href = linkMark.attrs.href;
		if (typeof href !== 'string' || href === '') return false;

		event.preventDefault();
		const classification = classifyHref(href, pagePath);

		if (classification.kind === 'external') {
			window.open(classification.url, '_blank', 'noopener,noreferrer');
			return true;
		}
		if (classification.kind === 'file') {
			return true;
		}

		if (dangling.has(classification.path)) {
			openCreateDialogFor(classification.path);
		} else {
			void goto(`/knowledge/${encodePath(classification.path)}`);
		}
		return true;
	}

	// Build the editor exactly once, when the host mounts. untrack() keeps
	// later prop changes (e.g. content refreshed after a save round-trip)
	// from tearing down and recreating the editor mid-edit, which would drop
	// the caret — content updates after mount flow through setContent().
	$effect(() => {
		if (!host) return;
		const element = host;

		editor = untrack(
			() =>
				new Editor({
					element,
					content,
					editorProps: {
						attributes: {
							class: 'tiptap-editor-content focus:outline-none'
						},
						// Image paste/drop (Task C7). Both handlers extract EVERY
						// allowed image from the event (`allowedImageFiles` — an item
						// that fails the allowlist, e.g. an SVG, never blocks an
						// allowed sibling elsewhere in the same paste/drop) and hand
						// the batch to `uploadAndInsertAll` above, which uploads and
						// inserts each in order. Returning `false` (no allowed image
						// anywhere in the event) falls through to tiptap's default
						// paste/drop handling, so text/other content is unaffected.
						handlePaste: (view, event) => {
							const items = Array.from(event.clipboardData?.items ?? []);
							const candidates = items
								.filter((it) => it.kind === 'file')
								.map((it) => it.getAsFile())
								.filter((f): f is File => f !== null);
							const files = allowedImageFiles(candidates);
							if (files.length === 0) return false;

							event.preventDefault();
							const pos = view.state.selection.from;
							void uploadAndInsertAll(files, pos);
							return true;
						},
						handleDrop: (view, event) => {
							const files = allowedImageFiles(Array.from(event.dataTransfer?.files ?? []));
							if (files.length === 0) return false;

							event.preventDefault();
							const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
							const pos = coords ? coords.pos : view.state.selection.from;
							void uploadAndInsertAll(files, pos);
							return true;
						},
						// Link-click navigation + dangling-link create (Task C9). Fires
						// for every node containing the click, inside-out — delegates
						// to `handleLinkClick`, which no-ops (`false`) for anything
						// without a link mark so normal caret placement/selection is
						// unaffected everywhere else in the doc.
						handleClickOn: (_view, _pos, node, _nodePos, event) => handleLinkClick(node, event)
					},
					extensions: [
						StarterKit,
						Placeholder.configure({
							placeholder: "Write it the way you'd tell a new assistant…"
						}),
						Link.configure({ openOnClick: false, autolink: true }),
						// `src` attrs stay the ON-DISK value (relative-from-page, or
						// absolute for an external mount) — `renderHTML` maps it through
						// `resolveImageSrc` for the DOM `<img>` only, at display time, so
						// the stored/serialized attribute is never the `/files/raw` URL.
						Image.extend({
							renderHTML({ HTMLAttributes }) {
								return [
									'img',
									{ ...HTMLAttributes, src: resolveImageSrc(String(HTMLAttributes.src ?? ''), pagePath) }
								];
							}
						}),
						Typography,
						Table.configure({ resizable: false }),
						TableRow,
						TableCell,
						TableHeader,
						TaskList,
						TaskItem.configure({ nested: true }),
						createSlashCommand(toSlashItems(commands)),
						// Page-link picker (Task C8): two Suggestion instances sharing one
						// factory, distinguished by `name` (see the factory's header
						// comment on why a shared/default plugin key would clobber one
						// instance's state) — `[[` for an explicit link-picker trigger,
						// `@` for a mention-style trigger. Both search the SAME `pagePath`
						// (relative-link math is computed from the page being edited) and
						// the same injected `api` (icmSearch for results, createIcmPage
						// for the create-on-empty item).
						createPageLinkSuggestion({ char: '[[', name: 'pageLinkBracket', pagePath, api }),
						createPageLinkSuggestion({ char: '@', name: 'pageLinkMention', pagePath, api }),
						// Formatting bubble on selection — bold/italic/strike/link only
						// this phase (see vendor/bubble_menu.js's header comment for why
						// underline/code were trimmed from the vendored button row).
						createBubbleMenu(),
						DragHandle,
						// Dangling-link decoration (Task C9) — see the factory's own
						// header comment above. Registered last; order among
						// `addProseMirrorPlugins` extensions doesn't affect decoration
						// correctness here (this plugin only reads marks other
						// extensions already produced, never edits the doc).
						createDanglingLinkExtension()
					],
					onUpdate: () => onChange()
				})
		);
		editorReady = true;

		return () => {
			editorReady = false;
			editor?.destroy();
			editor = null;
		};
	});

	// Syncs the `dangling` prop into the decoration plugin whenever it
	// changes (the route recomputes it on load and after each save) — a
	// meta-only transaction, not a content edit, so this can't mark the
	// page dirty or loop back into `onChange`/the save loop (see the
	// factory's header comment). Depends on `editorReady` ($state, so
	// reactive) rather than the bare `editor` variable, which an effect
	// could never see get (re)assigned.
	$effect(() => {
		const current = dangling;
		if (!editorReady || !editor) return;
		editor.view.dispatch(editor.state.tr.setMeta(danglingLinkPluginKey, { dangling: current }));
	});

	onDestroy(() => {
		editor?.destroy();
		editor = null;
	});
</script>

{#if uploadError}
	<p role="alert" class="text-warn-ink mb-2 text-[12px]">{uploadError}</p>
{/if}
<div bind:this={host} class="page-editor min-h-full"></div>

<Dialog.Root
	open={createDialogOpen}
	onOpenChange={(open) => {
		createDialogOpen = open;
	}}
>
	<Dialog.Content class="sm:max-w-sm">
		<Dialog.Header>
			<Dialog.Title class="font-display text-[19px] text-ink-heading">Create this page?</Dialog.Title>
			<Dialog.Description class="text-ink-body">
				This link points to a page that doesn't exist yet.
				<span class="font-mono text-[12px]">{createTarget?.fullPath ?? ''}</span>
			</Dialog.Description>
		</Dialog.Header>

		{#if createError}
			<p role="alert" class="text-[12.5px] text-warn-ink">{createError}</p>
		{/if}

		<Dialog.Footer>
			<Button
				type="button"
				variant="outline"
				onclick={() => (createDialogOpen = false)}
				disabled={createSubmitting}
			>
				Cancel
			</Button>
			<Button type="button" onclick={confirmCreateDanglingPage} disabled={createSubmitting}>
				{createSubmitting ? 'Creating…' : 'Create page'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
