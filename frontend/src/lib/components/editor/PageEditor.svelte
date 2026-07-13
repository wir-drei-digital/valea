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
	import { isAllowedImage, resolveImageSrc } from '$lib/editor/image-upload';
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
	 * Shared upload path for both paste and drop: validates the file against
	 * the same allowlist the backend enforces, uploads it, and — on success —
	 * inserts an image node at `pos` with `attrs.src` set to the response's
	 * `relFromPage` (the ON-DISK value; `renderHTML` maps it to a `/files/raw`
	 * URL at display time only, see the extension config below). `pos` is
	 * clamped to the current doc size in case it shifted while the (async)
	 * upload was in flight.
	 */
	async function uploadAndInsert(file: File, pos: number): Promise<void> {
		if (!isAllowedImage(file)) return;

		const result = await api.uploadImage(file, pagePath);
		if (!editor) return;

		if (!result.ok) {
			uploadError = "Couldn't upload the image. Try again.";
			return;
		}

		uploadError = null;
		const insertAt = Math.min(pos, editor.state.doc.content.size);
		editor
			.chain()
			.focus()
			.insertContentAt(insertAt, { type: 'image', attrs: { src: result.data.relFromPage, alt: file.name } })
			.run();
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
						// Image paste/drop (Task C7). Both handlers extract the first
						// allowed image, upload it, and insert an image node once the
						// upload resolves — see `uploadAndInsert` above. Returning
						// `false` (no image found, or the file fails the allowlist)
						// falls through to tiptap's default paste/drop handling, so
						// text/other content is unaffected.
						handlePaste: (view, event) => {
							const items = Array.from(event.clipboardData?.items ?? []);
							const item = items.find((it) => it.kind === 'file' && it.type.startsWith('image/'));
							const file = item?.getAsFile() ?? null;
							if (!file || !isAllowedImage(file)) return false;

							event.preventDefault();
							const pos = view.state.selection.from;
							void uploadAndInsert(file, pos);
							return true;
						},
						handleDrop: (view, event) => {
							const files = Array.from(event.dataTransfer?.files ?? []);
							const file = files.find((f) => isAllowedImage(f));
							if (!file) return false;

							event.preventDefault();
							const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
							const pos = coords ? coords.pos : view.state.selection.from;
							void uploadAndInsert(file, pos);
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
