// Vendored from tiptap_phoenix (assets/js/extensions/bubble_menu.js) on 2026-07-10 — framework-agnostic, no LiveView coupling.
// Adapted: the original's `pushEvent` option (named after Phoenix LiveView's
// `pushEvent` but never actually importing/depending on LiveView) has been
// renamed to the framework-neutral `onAction` — a plain optional callback of
// shape `(event: string, payload: object) => void`.
// Adapted (2026-07-10, Task 7): the hardcoded mark-button row has been
// trimmed to bold/italic/strike (+ the separate link button below it), per
// this phase's spec of "bold/italic/strike/link only". Underline was removed
// because the underline extension is not installed — `toggleMark('underline')`
// throws (`getMarkType` errors on an unknown mark name) the instant the
// button is clicked. Code was removed as out of scope for this phase.
// @ts-nocheck
import { Plugin, PluginKey } from "@tiptap/pm/state"
import { Extension } from "@tiptap/core"
import tippy from "tippy.js"

const pluginKey = new PluginKey("bubbleMenu")

const LINK_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/>
  <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
</svg>`

const ARROW_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
  <path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>
</svg>`

function createMenuElement(editor, extras, onAction) {
  const menu = document.createElement("div")
  menu.className = "bubble-menu"

  const buttons = [
    { label: "B", mark: "bold", style: "font-weight:700" },
    { label: "I", mark: "italic", style: "font-style:italic" },
    { label: "S", mark: "strike", style: "text-decoration:line-through" },
  ]

  buttons.forEach(({ label, mark, style }) => {
    const btn = document.createElement("button")
    btn.innerHTML = `<span style="${style}">${label}</span>`
    btn.setAttribute("data-mark", mark)
    btn.addEventListener("mousedown", (e) => {
      e.preventDefault()
      editor.chain().focus().toggleMark(mark).run()
    })
    menu.appendChild(btn)
  })

  // Separator
  const sep = document.createElement("div")
  sep.className = "bubble-menu-separator"
  menu.appendChild(sep)

  // Link button
  const linkBtn = document.createElement("button")
  linkBtn.innerHTML = LINK_SVG
  linkBtn.setAttribute("data-action", "link")
  linkBtn.addEventListener("mousedown", (e) => {
    e.preventDefault()
    if (editor.isActive("link")) {
      editor.chain().focus().unsetLink().run()
      updateActiveStates(menu, editor)
      return
    }
    toggleLinkInput(menu, editor)
  })
  menu.appendChild(linkBtn)

  // Link input row (hidden by default)
  const linkRow = document.createElement("div")
  linkRow.className = "bubble-menu-link-input"
  linkRow.style.display = "none"

  const urlInput = document.createElement("input")
  urlInput.type = "text"
  urlInput.className = "bubble-menu-url-input"
  urlInput.placeholder = "Paste URL..."

  urlInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault()
      const url = urlInput.value.trim()
      if (url && /^https?:\/\//i.test(url)) {
        editor.chain().focus().setLink({ href: url }).run()
      }
      hideLinkInput(menu)
    }
    if (e.key === "Escape") {
      e.preventDefault()
      hideLinkInput(menu)
      editor.commands.focus()
    }
  })

  linkRow.appendChild(urlInput)
  menu.appendChild(linkRow)

  // Extra items (app-injected buttons and inputs)
  // Collect input rows separately so they're appended at the end
  const deferredInputRows = []

  if (extras.length > 0 && onAction) {
    let activeExtraInput = null

    // Expose reset function for the plugin's update handler
    menu._resetExtraInputs = () => {
      if (activeExtraInput) {
        activeExtraInput.style.display = "none"
        activeExtraInput = null
      }
    }

    extras.forEach((item) => {
      if (item.type === "separator") {
        const extraSep = document.createElement("div")
        extraSep.className = "bubble-menu-separator"
        menu.appendChild(extraSep)
        return
      }

      if (item.type === "button") {
        if (!item.event) return
        const btn = document.createElement("button")
        btn.className = "bubble-menu-extra-btn"
        btn.innerHTML = (item.icon || "") + `<span>${item.label}</span>`
        btn.addEventListener("mousedown", (e) => {
          e.preventDefault()
          const payload = item.getPayload ? item.getPayload(editor) : {}
          onAction(item.event, payload)
        })
        menu.appendChild(btn)
        return
      }

      if (item.type === "input") {
        if (!item.event) return
        const btn = document.createElement("button")
        btn.className = "bubble-menu-extra-btn"
        btn.innerHTML = (item.icon || "") + `<span>${item.label}</span>`

        // Create input row for this extra
        const inputRow = document.createElement("div")
        inputRow.className = "bubble-menu-extra-input"
        inputRow.style.display = "none"

        const input = document.createElement("input")
        input.type = "text"
        input.className = "bubble-menu-url-input"
        input.placeholder = item.placeholder || "Type here..."

        function submitInput() {
          const val = input.value.trim()
          if (!val) return
          const payload = item.getPayload
            ? item.getPayload(editor, val)
            : { value: val }
          onAction(item.event, payload)
          inputRow.style.display = "none"
          input.value = ""
          activeExtraInput = null
          editor.commands.focus()
        }

        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            e.preventDefault()
            submitInput()
          }
          if (e.key === "Escape") {
            e.preventDefault()
            inputRow.style.display = "none"
            input.value = ""
            activeExtraInput = null
            editor.commands.focus()
          }
        })

        // Submit button with arrow icon
        const submitBtn = document.createElement("button")
        submitBtn.className = "bubble-menu-input-submit"
        submitBtn.innerHTML = ARROW_SVG
        submitBtn.addEventListener("mousedown", (e) => {
          e.preventDefault()
          submitInput()
        })

        inputRow.appendChild(input)
        inputRow.appendChild(submitBtn)

        btn.addEventListener("mousedown", (e) => {
          e.preventDefault()
          if (activeExtraInput === inputRow) {
            inputRow.style.display = "none"
            activeExtraInput = null
            return
          }
          // Hide any other open input
          if (activeExtraInput) {
            activeExtraInput.style.display = "none"
          }
          hideLinkInput(menu)
          inputRow.style.display = "flex"
          activeExtraInput = inputRow
          setTimeout(() => input.focus(), 50)
        })

        menu.appendChild(btn)
        deferredInputRows.push(inputRow)
      }
    })
  }

  // Append all input rows at the end so they don't break the button row
  deferredInputRows.forEach((row) => menu.appendChild(row))

  return menu
}

function toggleLinkInput(menu, editor) {
  const linkRow = menu.querySelector(".bubble-menu-link-input")
  const urlInput = menu.querySelector(".bubble-menu-url-input")
  if (!linkRow || !urlInput) return

  const isVisible = linkRow.style.display !== "none"
  if (isVisible) {
    hideLinkInput(menu)
    return
  }

  // Hide any extra inputs
  menu._resetExtraInputs?.()
  menu.querySelectorAll(".bubble-menu-extra-input").forEach((row) => {
    row.style.display = "none"
  })

  // Pre-fill with existing href if editing a link
  const attrs = editor.getAttributes("link")
  urlInput.value = attrs.href || ""

  linkRow.style.display = "flex"
  // Small delay to let the menu reposition
  setTimeout(() => urlInput.focus(), 50)
}

function hideLinkInput(menu) {
  const linkRow = menu.querySelector(".bubble-menu-link-input")
  if (linkRow) linkRow.style.display = "none"
}

function hideAllInputs(menu) {
  hideLinkInput(menu)
  menu._resetExtraInputs?.()
  menu.querySelectorAll(".bubble-menu-extra-input").forEach((row) => {
    row.style.display = "none"
  })
}

function hasOpenInput(menu) {
  const linkRow = menu.querySelector(".bubble-menu-link-input")
  if (linkRow && linkRow.style.display !== "none") return true

  const extraInputs = menu.querySelectorAll(".bubble-menu-extra-input")
  for (const input of extraInputs) {
    if (input.style.display !== "none") return true
  }

  return false
}

function updateActiveStates(menu, editor) {
  menu.querySelectorAll("button[data-mark]").forEach((btn) => {
    const mark = btn.getAttribute("data-mark")
    btn.classList.toggle("is-active", editor.isActive(mark))
  })
  const linkBtn = menu.querySelector('button[data-action="link"]')
  if (linkBtn) {
    linkBtn.classList.toggle("is-active", editor.isActive("link"))
  }
}

/**
 * Creates a BubbleMenu extension with optional extra items.
 *
 * @param {Object} [options]
 * @param {Array}  [options.extras] - Extra items to add to the bubble menu.
 *   Each item is an object with a `type` property:
 *   - `{ type: 'separator' }` — visual separator
 *   - `{ type: 'button', label, icon?, event, getPayload: (editor) => object }` — simple click action
 *   - `{ type: 'input', label, icon?, placeholder?, event, getPayload: (editor, inputValue) => object }` — click opens input, Enter submits
 * @param {Function} [options.onAction] - Optional callback invoked as onAction(event, payload)
 *   when an extra button/input fires. Framework-agnostic — the host app wires this to
 *   whatever transport it wants (HTTP call, store update, etc).
 * @returns {Extension} A Tiptap extension
 */
export function createBubbleMenu(options = {}) {
  const { extras = [], onAction = null } = options

  return Extension.create({
    name: "customBubbleMenu",

    addProseMirrorPlugins() {
      const editor = this.editor
      let popup = null
      let menuEl = null

      return [
        new Plugin({
          key: pluginKey,
          view: () => {
            menuEl = createMenuElement(editor, extras, onAction)

            popup = tippy("body", {
              getReferenceClientRect: null,
              appendTo: () => document.body,
              content: menuEl,
              interactive: true,
              trigger: "manual",
              placement: "top",
              offset: [0, 8],
              maxWidth: 360,
            })

            return {
              update: (view, prevState) => {
                const { state } = view
                const { selection } = state
                const { empty, from, to } = selection

                // Don't hide while user is typing in any input (link or extras)
                // But if editor regained focus, close inputs and proceed
                if (hasOpenInput(menuEl)) {
                  if (view.hasFocus()) {
                    hideAllInputs(menuEl)
                  } else {
                    return
                  }
                }

                if (empty || !view.hasFocus()) {
                  popup?.[0]?.hide()
                  hideAllInputs(menuEl)
                  return
                }

                // Don't show for node selections (images, etc)
                if (selection.node) {
                  popup?.[0]?.hide()
                  hideAllInputs(menuEl)
                  return
                }

                // Don't show inside code blocks
                const $from = state.doc.resolve(from)
                if ($from.parent.type.name === "codeBlock") {
                  popup?.[0]?.hide()
                  hideAllInputs(menuEl)
                  return
                }

                updateActiveStates(menuEl, editor)

                popup?.[0]?.setProps({
                  getReferenceClientRect: () => {
                    const coords = view.coordsAtPos(from)
                    const endCoords = view.coordsAtPos(to)
                    return {
                      top: coords.top,
                      bottom: endCoords.bottom,
                      left: coords.left,
                      right: endCoords.right,
                      width: endCoords.right - coords.left,
                      height: endCoords.bottom - coords.top,
                      x: coords.left,
                      y: coords.top,
                    }
                  },
                })
                popup?.[0]?.show()
              },

              destroy: () => {
                popup?.[0]?.destroy()
                menuEl?.remove()
              },
            }
          },
        }),
      ]
    },
  })
}

// Backwards-compatible static export (no extras)
export const BubbleMenu = createBubbleMenu()
