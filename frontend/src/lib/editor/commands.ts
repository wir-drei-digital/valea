// Valea's own slash-command list (Task 7). Deliberately NOT the vendored
// `defaultCommands` from `vendor/slash_command.js` — that list includes
// "Image" (setImage) and "Toggle" (setDetails), and neither the image nor
// the details/details-summary/details-content extensions are installed in
// this app. Calling either command's chain method throws a TypeError the
// instant the item is picked. Every command below is cross-checked against
// an installed extension (see PageEditor.svelte's extension list):
//   - heading/bulletList/orderedList/blockquote/horizontalRule/codeBlock ->
//     part of @tiptap/starter-kit
//   - taskList -> @tiptap/extension-task-list (toggleTaskList command)
//   - table -> @tiptap/extension-table (insertTable command)
//
// Pure data + editor command runs — no store imports, no DOM access, so this
// module is trivially unit-testable and reusable outside the slash menu
// (e.g. a future "insert block" toolbar) without dragging in Svelte state.
import type { Editor } from "@tiptap/core";

export interface SlashCommandItem {
	/** Shown as the menu row's label. */
	title: string;
	/** Short label/glyph rendered in the menu's icon slot (HTML, via innerHTML — keep it to entities/short text). */
	icon?: string;
	/** Applies the block transform. Receives the live editor instance; the
	 * caller (PageEditor) is responsible for focusing and clearing the "/"
	 * trigger text before invoking this. */
	run: (editor: Editor) => void;
}

export const commands: SlashCommandItem[] = [
	{
		title: "Heading 1",
		icon: "H1",
		run: (editor) => editor.chain().focus().setHeading({ level: 1 }).run()
	},
	{
		title: "Heading 2",
		icon: "H2",
		run: (editor) => editor.chain().focus().setHeading({ level: 2 }).run()
	},
	{
		title: "Heading 3",
		icon: "H3",
		run: (editor) => editor.chain().focus().setHeading({ level: 3 }).run()
	},
	{
		title: "Bullet List",
		icon: "&#8226;",
		run: (editor) => editor.chain().focus().toggleBulletList().run()
	},
	{
		title: "Numbered List",
		icon: "1.",
		run: (editor) => editor.chain().focus().toggleOrderedList().run()
	},
	{
		title: "Task List",
		icon: "&#9744;",
		run: (editor) => editor.chain().focus().toggleTaskList().run()
	},
	{
		title: "Table",
		icon: "&#9638;",
		run: (editor) =>
			editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()
	},
	{
		title: "Quote",
		icon: "&#10077;",
		run: (editor) => editor.chain().focus().setBlockquote().run()
	},
	{
		title: "Divider",
		icon: "&#8212;",
		run: (editor) => editor.chain().focus().setHorizontalRule().run()
	},
	{
		title: "Code Block",
		icon: "&lt;&gt;",
		run: (editor) => editor.chain().focus().setCodeBlock().run()
	}
];
