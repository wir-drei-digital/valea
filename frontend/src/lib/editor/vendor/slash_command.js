// Vendored from tiptap_phoenix (assets/js/extensions/slash_command.js) on 2026-07-10 — framework-agnostic, no LiveView coupling.
// @ts-nocheck
import { Extension } from "@tiptap/core"
import Suggestion from "@tiptap/suggestion"
import tippy from "tippy.js"

export const defaultCommands = [
  { title: "Text", description: "Plain text block", icon: "&#182;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setParagraph().run()
  }},
  { title: "Heading 1", description: "Large heading", icon: "H1", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setHeading({ level: 1 }).run()
  }},
  { title: "Heading 2", description: "Medium heading", icon: "H2", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setHeading({ level: 2 }).run()
  }},
  { title: "Heading 3", description: "Small heading", icon: "H3", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setHeading({ level: 3 }).run()
  }},
  { title: "Bullet List", description: "Unordered list", icon: "&#8226;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).toggleBulletList().run()
  }},
  { title: "Numbered List", description: "Ordered list", icon: "1.", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).toggleOrderedList().run()
  }},
  { title: "Quote", description: "Blockquote", icon: "&#10077;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setBlockquote().run()
  }},
  { title: "Code Block", description: "Code with syntax highlighting", icon: "&lt;&gt;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setCodeBlock().run()
  }},
  { title: "Image", description: "Insert image from URL", icon: "&#128444;", command: ({ editor, range }) => {
    const url = window.prompt("Image URL:")
    if (url) {
      editor.chain().focus().deleteRange(range).setImage({ src: url }).run()
    }
  }},
  { title: "Divider", description: "Horizontal rule", icon: "&#8212;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setHorizontalRule().run()
  }},
  { title: "Table", description: "Insert a table", icon: "&#9638;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()
  }},
  { title: "Toggle", description: "Collapsible section", icon: "&#9654;", command: ({ editor, range }) => {
    editor.chain().focus().deleteRange(range).setDetails().command(({ tr, state }) => {
      // Auto-open the newly created details block
      const { $from } = state.selection
      for (let d = $from.depth; d > 0; d--) {
        const node = $from.node(d)
        if (node.type.name === "details") {
          tr.setNodeMarkup($from.before(d), undefined, { ...node.attrs, open: true })
          return true
        }
      }
      return true
    }).run()
  }},
]

function filterCommands(items, query) {
  return items.filter(item =>
    item.title.toLowerCase().includes(query.toLowerCase())
  )
}

function renderMenu() {
  let component = null
  let popup = null

  return {
    onStart: (props) => {
      component = new CommandList(props)

      if (!props.clientRect) return

      popup = tippy("body", {
        getReferenceClientRect: props.clientRect,
        appendTo: () => document.body,
        content: component.element,
        showOnCreate: true,
        interactive: true,
        trigger: "manual",
        placement: "bottom-start",
        offset: [0, 4],
      })
    },

    onUpdate: (props) => {
      component.update(props)

      if (!props.clientRect) return

      popup?.[0]?.setProps({
        getReferenceClientRect: props.clientRect,
      })
    },

    onKeyDown: (props) => {
      if (props.event.key === "Escape") {
        popup?.[0]?.hide()
        return true
      }
      return component?.onKeyDown(props.event) ?? false
    },

    onExit: () => {
      popup?.[0]?.destroy()
      component?.destroy()
    },
  }
}

class CommandList {
  constructor({ items, command }) {
    this.items = items
    this.command = command
    this.selectedIndex = 0
    this.element = document.createElement("div")
    this.element.className = "slash-command-menu"
    this.render()
  }

  update({ items, command }) {
    this.items = items
    this.command = command
    this.selectedIndex = 0
    this.render()
  }

  onKeyDown(event) {
    if (event.key === "ArrowUp") {
      this.selectedIndex = (this.selectedIndex + this.items.length - 1) % this.items.length
      this.render()
      return true
    }
    if (event.key === "ArrowDown") {
      this.selectedIndex = (this.selectedIndex + 1) % this.items.length
      this.render()
      return true
    }
    if (event.key === "Enter") {
      const item = this.items[this.selectedIndex]
      if (item) this.command(item)
      return true
    }
    return false
  }

  render() {
    this.element.innerHTML = ""
    this.items.forEach((item, index) => {
      const button = document.createElement("button")
      button.className = `slash-command-item${index === this.selectedIndex ? " is-selected" : ""}`
      button.innerHTML = `
        <span class="slash-command-item-icon">${item.icon}</span>
        <span>${item.title}</span>
      `
      button.addEventListener("mousedown", (e) => {
        e.preventDefault()
        this.command(item)
      })
      button.addEventListener("mouseenter", () => {
        this.selectedIndex = index
        this.render()
      })
      this.element.appendChild(button)
    })
  }

  destroy() {
    this.element.remove()
  }
}

export function createSlashCommand(items) {
  const commandItems = items || defaultCommands

  return Extension.create({
    name: "slashCommand",

    addOptions() {
      return {
        suggestion: {
          char: "/",
          command: ({ editor, range, props }) => {
            props.command({ editor, range })
          },
        },
      }
    },

    addProseMirrorPlugins() {
      return [
        Suggestion({
          editor: this.editor,
          ...this.options.suggestion,
          items: ({ query }) => filterCommands(commandItems, query),
          render: renderMenu,
        }),
      ]
    },
  })
}

export const SlashCommand = createSlashCommand()
