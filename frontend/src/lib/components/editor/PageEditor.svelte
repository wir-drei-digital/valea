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
	import '$lib/editor/tiptap.css';

	/** ProseMirror document JSON — the wire format for page bodies. */
	type PMDoc = Record<string, unknown>;

	let { content, onChange }: { content: PMDoc; onChange: () => void } = $props();

	let host = $state<HTMLElement | null>(null);
	let editor: Editor | null = null;

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
						}
					},
					extensions: [
						StarterKit,
						Placeholder.configure({
							placeholder: "Write it the way you'd tell a new assistant…"
						}),
						Link.configure({ openOnClick: false, autolink: true }),
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

<div bind:this={host} class="page-editor min-h-full"></div>
