<script lang="ts">
	// Notion-like block editor for ICM pages, built on tiptap. Lifecycle
	// pattern (host element, editor built in an untrack()-wrapped $effect,
	// destroyed on both effect cleanup and onDestroy) follows the magus
	// reference component:
	// /Users/daniel/Development/magus/frontend/src/lib/components/brain/brain-editor.svelte
	import { onDestroy, untrack } from 'svelte';
	import { Editor } from '@tiptap/core';
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
	import { DragHandle } from '$lib/editor/vendor/drag_handle.js';
	import { commands, type SlashCommandItem } from '$lib/editor/commands';
	import { allowedImageFiles, isAllowedImage, resolveImageSrc } from '$lib/editor/image-upload';
	import { api } from '$lib/api/client';
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
	 */
	let { content, onChange, pagePath }: { content: PMDoc; onChange: () => void; pagePath: string } = $props();

	let host = $state<HTMLElement | null>(null);
	let editor: Editor | null = null;

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
						}
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
						// Formatting bubble on selection — bold/italic/strike/link only
						// this phase (see vendor/bubble_menu.js's header comment for why
						// underline/code were trimmed from the vendored button row).
						createBubbleMenu(),
						DragHandle
					],
					onUpdate: () => onChange()
				})
		);

		return () => {
			editor?.destroy();
			editor = null;
		};
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
