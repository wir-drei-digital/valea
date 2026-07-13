// Authored for Task C8, structured closely after `slash_command.js` (same
// `@tiptap/suggestion` config shape: `char`, async `items`, tippy `render`,
// item-owned `command`) — the one addition slash_command.js didn't need is a
// per-instance `pluginKey`: this factory is called TWICE (once for `[[`,
// once for `@`), and `Suggestion()`'s default `pluginKey` is a single
// module-level singleton in `@tiptap/suggestion` shared across every call
// that doesn't override it, so two un-keyed instances registered on the same
// editor would silently clobber each other's plugin state.
// @ts-nocheck
import { Extension } from "@tiptap/core"
import { PluginKey } from "@tiptap/pm/state"
import Suggestion from "@tiptap/suggestion"
import tippy from "tippy.js"
import { pickerItems, linkDestination, parentOf } from "../page-link"

const SEARCH_DEBOUNCE_MS = 150

// `@tiptap/suggestion`'s `view.update` awaits the promise `items()` returns
// on EVERY keystroke that starts or changes the suggestion, including the
// very first one (empty query) that flips the plugin from inactive to
// active and fires `onStart` — the call that actually creates the popup. A
// naive "clearTimeout the previous call, let its promise dangle" debounce
// starves exactly that first call whenever the user types a search term
// faster than the debounce window (the common case, not an edge case): the
// popup would simply never appear. So instead of dropping superseded calls,
// every call's resolver is queued and ALL of them are resolved together —
// with the one search that actually runs, for the latest query — once
// typing settles for `wait` ms.
function debounced(fn, wait) {
  let timer = null
  let resolvers = []

  return (...args) => new Promise((resolve) => {
    resolvers.push(resolve)
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      const pending = resolvers
      resolvers = []
      timer = null
      Promise.resolve(fn(...args)).then((result) => {
        pending.forEach((r) => r(result))
      })
    }, wait)
  })
}

function renderMenu() {
  let component = null
  let popup = null

  return {
    onStart: (props) => {
      component = new PageLinkList(props)

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

class PageLinkList {
  constructor({ items, command }) {
    this.items = items
    this.command = command
    this.selectedIndex = 0
    this.element = document.createElement("div")
    this.element.className = "page-link-menu"
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
      button.className = `page-link-item${index === this.selectedIndex ? " is-selected" : ""}${item.kind === "create" ? " is-create" : ""}`

      // Icon is a fixed, non-user-controlled entity string (like
      // slash_command.js's icons) — safe via innerHTML. `item.title` (and
      // `item.snippet`) come from search results / the user's own typed
      // query, so those go through textContent, never innerHTML.
      const icon = document.createElement("span")
      icon.className = "page-link-item-icon"
      icon.innerHTML = item.kind === "create" ? "&#43;" : "&#128196;"
      button.appendChild(icon)

      const body = document.createElement("span")
      body.className = "page-link-item-body"

      const title = document.createElement("span")
      title.className = "page-link-item-title"
      title.textContent = item.title
      body.appendChild(title)

      if (item.kind === "page" && item.snippet) {
        const snippet = document.createElement("span")
        snippet.className = "page-link-item-snippet"
        snippet.textContent = item.snippet
        body.appendChild(snippet)
      }

      button.appendChild(body)

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

// Adapts a pure `PickerItem` (page-link.ts) into the menu-item shape
// `PageLinkList`/the `Suggestion` plugin expect: the same data plus a bound
// `command({editor, range})` that performs this item's actual edit,
// closing over `pagePath`/`api` from the factory call below.
function toMenuItem(item, { pagePath, api }) {
  if (item.kind === "create") {
    return {
      ...item,
      command: async ({ editor, range }) => {
        const result = await api.createIcmPage(parentOf(pagePath), item.query)
        // Guard mirrors PageEditor.svelte's uploadAndInsertAll: the editor
        // may have been destroyed while the create call was in flight.
        // Deliberately does NOT delete `range`/insert anything on failure —
        // the user's typed query text is left untouched rather than losing
        // it with nothing to show for it.
        if (!editor || !result.ok) return

        // The doc can change size while the network call is in flight (the
        // user keeps typing elsewhere) — clamp the captured range to the
        // current doc size, same defensive pattern as uploadAndInsertAll's
        // `Math.min(pos, ...content.size)`, so a since-shrunk doc can't turn
        // this into an out-of-bounds ProseMirror position error.
        const docSize = editor.state.doc.content.size
        const from = Math.min(range.from, docSize)
        const to = Math.min(range.to, docSize)
        if (from > to) return

        editor
          .chain()
          .focus()
          .deleteRange({ from, to })
          .insertContent({
            type: "text",
            text: item.query,
            marks: [{ type: "link", attrs: { href: linkDestination(pagePath, result.data.path) } }],
          })
          .run()
      },
    }
  }

  return {
    ...item,
    command: ({ editor, range }) => {
      editor
        .chain()
        .focus()
        .deleteRange(range)
        .insertContent({
          type: "text",
          text: item.title,
          marks: [{ type: "link", attrs: { href: linkDestination(pagePath, item.path) } }],
        })
        .run()
    },
  }
}

/**
 * Builds one `[[`- or `@`-triggered page-link `Suggestion` extension.
 * `name` must be distinct per instance (see the header comment) — it seeds
 * both the extension name and the plugin key. `allowedPrefixes` defaults to
 * `[' ']` (the same default `@tiptap/suggestion` itself uses when the
 * option is omitted) so `@` only triggers after whitespace/start-of-line —
 * `mara@example` never opens the picker mid-word, since the character
 * before the `@` there is a letter, not an allowed prefix.
 */
export function createPageLinkSuggestion({ char, name, pagePath, api, allowedPrefixes = [" "] }) {
  const search = debounced((query) => api.icmSearch(query), SEARCH_DEBOUNCE_MS)

  return Extension.create({
    name,

    addOptions() {
      return {
        suggestion: {
          char,
          allowedPrefixes,
          pluginKey: new PluginKey(name),
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
          items: async ({ query }) => {
            const result = await search(query)
            const results = result.ok ? result.data.results : []
            return pickerItems(results, query).map((item) => toMenuItem(item, { pagePath, api }))
          },
          render: renderMenu,
        }),
      ]
    },
  })
}
