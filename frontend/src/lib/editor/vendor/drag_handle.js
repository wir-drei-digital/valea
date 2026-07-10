// Vendored from tiptap_phoenix (assets/js/extensions/drag_handle.js) on 2026-07-10 — framework-agnostic, no LiveView coupling.
// Adapted (2026-07-10, Task 7): the "Turn into → Toggle" context-menu item has
// been removed. It called `.setDetails()`, but the details/details-summary/
// details-content extensions are not installed in this app — calling that
// chain method throws a TypeError as soon as the item is clicked.
// @ts-nocheck
import { Extension } from "@tiptap/core"
import { Plugin, PluginKey } from "@tiptap/pm/state"
import tippy from "tippy.js"

const pluginKey = new PluginKey("dragHandle")

const GRIP_SVG = `<svg width="10" height="14" viewBox="0 0 10 14" fill="currentColor">
  <circle cx="2" cy="2" r="1.5"/>
  <circle cx="8" cy="2" r="1.5"/>
  <circle cx="2" cy="7" r="1.5"/>
  <circle cx="8" cy="7" r="1.5"/>
  <circle cx="2" cy="12" r="1.5"/>
  <circle cx="8" cy="12" r="1.5"/>
</svg>`

function resolveTopLevelBlock(view, pos) {
  try {
    const $pos = view.state.doc.resolve(pos)
    if ($pos.depth < 1) return null
    const start = $pos.before(1)
    const node = view.state.doc.nodeAt(start)
    if (!node) return null
    const dom = view.nodeDOM(start)
    if (!dom || dom.nodeType !== 1) return null
    return { pos: start, node, dom }
  } catch {
    return null
  }
}

/**
 * Find the nearest top-level block by comparing mouse Y to block DOM rects.
 * Used as fallback when posAtCoords fails (e.g. cursor outside editor bounds).
 */
function findNearestBlock(view, mouseY) {
  const doc = view.state.doc
  let closest = null
  let closestDist = Infinity

  doc.forEach((node, offset) => {
    const dom = view.nodeDOM(offset)
    if (!dom || dom.nodeType !== 1) return
    const rect = dom.getBoundingClientRect()
    const blockMidY = rect.top + rect.height / 2
    const dist = Math.abs(mouseY - blockMidY)
    if (dist < closestDist) {
      closestDist = dist
      closest = { pos: offset, node, dom }
    }
  })

  return closest
}

function createContextMenu(editor, blockPos, onAction) {
  const menu = document.createElement("div")
  menu.className = "block-context-menu"

  const sections = [
    {
      label: null,
      items: [
        {
          label: "Duplicate",
          icon: "&#8853;",
          action: () => {
            const { state, dispatch } = editor.view
            const node = state.doc.nodeAt(blockPos)
            if (!node) return
            dispatch(state.tr.insert(blockPos + node.nodeSize, node.copy(node.content)))
          },
        },
        {
          label: "Delete",
          icon: "&#10005;",
          action: () => {
            const { state, dispatch } = editor.view
            const node = state.doc.nodeAt(blockPos)
            if (!node) return
            dispatch(state.tr.delete(blockPos, blockPos + node.nodeSize))
          },
        },
        {
          label: "Copy to clipboard",
          icon: "&#128203;",
          action: () => {
            const node = editor.view.state.doc.nodeAt(blockPos)
            if (node) navigator.clipboard.writeText(node.textContent)
          },
        },
      ],
    },
    {
      label: "Turn into",
      items: [
        {
          label: "Text",
          icon: "&#182;",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setParagraph().run(),
        },
        {
          label: "Heading 1",
          icon: "H1",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setHeading({ level: 1 }).run(),
        },
        {
          label: "Heading 2",
          icon: "H2",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setHeading({ level: 2 }).run(),
        },
        {
          label: "Heading 3",
          icon: "H3",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setHeading({ level: 3 }).run(),
        },
        {
          label: "Bullet List",
          icon: "&#8226;",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).toggleBulletList().run(),
        },
        {
          label: "Ordered List",
          icon: "1.",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).toggleOrderedList().run(),
        },
        {
          label: "Blockquote",
          icon: "&#10077;",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setBlockquote().run(),
        },
        {
          label: "Code Block",
          icon: "&lt;&gt;",
          action: () =>
            editor.chain().focus().setTextSelection(blockPos + 1).setCodeBlock().run(),
        },
      ],
    },
  ]

  sections.forEach((section, sectionIdx) => {
    if (sectionIdx > 0) {
      const divider = document.createElement("div")
      divider.className = "block-context-menu-divider"
      menu.appendChild(divider)
    }

    if (section.label) {
      const label = document.createElement("div")
      label.className = "block-context-menu-label"
      label.textContent = section.label
      menu.appendChild(label)
    }

    section.items.forEach((item) => {
      const btn = document.createElement("button")
      btn.className = "block-context-menu-item"
      btn.innerHTML = `<span class="block-context-menu-icon">${item.icon}</span><span>${item.label}</span>`
      btn.addEventListener("mousedown", (e) => {
        e.preventDefault()
        item.action()
        onAction?.()
      })
      menu.appendChild(btn)
    })
  })

  return menu
}

export const DragHandle = Extension.create({
  name: "dragHandle",

  addProseMirrorPlugins() {
    const editor = this.editor
    let handle = null
    let currentBlockPos = null
    let currentBlockDom = null
    let hideTimeout = null
    let contextPopup = null
    let dropIndicator = null

    // Mouse-based drag state
    let isDragging = false
    let dragBlockPos = null
    let dragBlockNode = null
    let dragBlockDom = null
    let didDragMove = false

    /**
     * Get the outer editor container to mount the handle.
     * This sits inside padding, giving room for the handle to the left.
     */
    function getHandleContainer() {
      // editor.view.dom = .ProseMirror
      // .parentElement = [data-tiptap-editor]
      // .parentElement = outer container
      return editor.view.dom.parentElement?.parentElement
    }

    function createHandle() {
      const container = getHandleContainer()
      if (!container) return null

      handle = document.createElement("div")
      handle.className = "drag-handle"
      handle.innerHTML = GRIP_SVG
      container.style.position = "relative"
      container.appendChild(handle)

      handle.addEventListener("mouseenter", () => {
        clearTimeout(hideTimeout)
      })

      handle.addEventListener("mouseleave", () => {
        if (!isDragging) scheduleHide()
      })

      // Mouse-based drag: start on mousedown
      handle.addEventListener("mousedown", (e) => {
        if (e.button !== 0) return
        if (currentBlockPos === null) return

        e.preventDefault()
        e.stopPropagation()

        dragBlockPos = currentBlockPos
        dragBlockNode = editor.view.state.doc.nodeAt(dragBlockPos)
        dragBlockDom = currentBlockDom
        didDragMove = false

        if (!dragBlockNode) return

        isDragging = true
        dragBlockDom?.classList.add("is-dragging")
        document.body.style.cursor = "grabbing"

        document.addEventListener("mousemove", onDragMove)
        document.addEventListener("mouseup", onDragEnd)
      })

      return handle
    }

    function resolveBlockAtMouse(event) {
      const view = editor.view
      const editorRect = view.dom.getBoundingClientRect()

      // Clamp X to inside the editor content so posAtCoords doesn't fail
      const clampedX = Math.max(
        editorRect.left + 10,
        Math.min(event.clientX, editorRect.right - 10),
      )

      const pos = view.posAtCoords({ left: clampedX, top: event.clientY })
      if (pos) {
        const result = resolveTopLevelBlock(view, pos.pos)
        if (result) return result
      }

      // Fallback: find nearest block by Y position
      return findNearestBlock(view, event.clientY)
    }

    function onDragMove(event) {
      if (!isDragging) return
      didDragMove = true

      const result = resolveBlockAtMouse(event)
      if (!result || !result.dom) return

      const blockRect = result.dom.getBoundingClientRect()
      const midY = blockRect.top + blockRect.height / 2
      const y = event.clientY < midY ? blockRect.top : blockRect.bottom
      showDropIndicator(y)
    }

    function onDragEnd(event) {
      document.removeEventListener("mousemove", onDragMove)
      document.removeEventListener("mouseup", onDragEnd)

      hideDropIndicator()
      document.body.style.cursor = ""
      dragBlockDom?.classList.remove("is-dragging")

      const wasDrag = didDragMove

      if (!isDragging || dragBlockPos === null || !dragBlockNode) {
        isDragging = false
        dragBlockPos = null
        dragBlockNode = null
        dragBlockDom = null
        didDragMove = false
        return
      }

      // Only perform move if the mouse actually moved (not just a click)
      if (wasDrag) {
        const result = resolveBlockAtMouse(event)
        if (result && result.pos !== dragBlockPos) {
          const blockRect = result.dom.getBoundingClientRect()
          const midY = blockRect.top + blockRect.height / 2
          const insertBefore = event.clientY < midY

          let targetPos = insertBefore
            ? result.pos
            : result.pos + result.node.nodeSize

          const { state, dispatch } = editor.view
          const currentNode = state.doc.nodeAt(dragBlockPos)

          if (currentNode) {
            const draggedEnd = dragBlockPos + currentNode.nodeSize

            if (targetPos !== dragBlockPos && targetPos !== draggedEnd) {
              let tr = state.tr

              if (dragBlockPos < targetPos) {
                targetPos -= currentNode.nodeSize
                tr = tr.delete(dragBlockPos, draggedEnd)
                tr = tr.insert(targetPos, currentNode)
              } else {
                tr = tr.insert(targetPos, currentNode)
                tr = tr.delete(
                  dragBlockPos + currentNode.nodeSize,
                  draggedEnd + currentNode.nodeSize,
                )
              }
              dispatch(tr)
            }
          }
        }
      }

      isDragging = false
      dragBlockPos = null
      dragBlockNode = null
      dragBlockDom = null
      didDragMove = false

      // If it was a click (no drag movement), open context menu
      if (!wasDrag && currentBlockPos !== null) {
        openContextMenu()
      }
    }

    function openContextMenu() {
      if (!handle || currentBlockPos === null) return

      contextPopup?.destroy()

      const menuEl = createContextMenu(editor, currentBlockPos, () => {
        contextPopup?.hide()
      })

      contextPopup = tippy(handle, {
        content: menuEl,
        interactive: true,
        trigger: "manual",
        placement: "bottom-start",
        offset: [0, 4],
        appendTo: () => document.body,
      })
      contextPopup.show()
    }

    function showHandle(blockDom, blockPos) {
      clearTimeout(hideTimeout)
      if (!handle) createHandle()
      if (!handle) return

      currentBlockPos = blockPos
      currentBlockDom = blockDom

      const container = getHandleContainer()
      if (!container || !blockDom) return

      const containerRect = container.getBoundingClientRect()
      const blockRect = blockDom.getBoundingClientRect()

      handle.style.top = `${blockRect.top - containerRect.top}px`
      handle.style.left = "2px"
      handle.style.opacity = "1"
      handle.style.pointerEvents = "auto"
    }

    function scheduleHide() {
      if (contextPopup?.state?.isVisible) return
      hideTimeout = setTimeout(() => {
        if (handle) {
          handle.style.opacity = "0"
          handle.style.pointerEvents = "none"
        }
        currentBlockPos = null
        currentBlockDom = null
      }, 250)
    }

    function showDropIndicator(y) {
      const container = getHandleContainer()
      if (!container) return
      if (!dropIndicator) {
        dropIndicator = document.createElement("div")
        dropIndicator.className = "drop-indicator"
        container.appendChild(dropIndicator)
      }
      const containerRect = container.getBoundingClientRect()
      dropIndicator.style.top = `${y - containerRect.top}px`
      dropIndicator.style.display = "block"
    }

    function hideDropIndicator() {
      if (dropIndicator) {
        dropIndicator.style.display = "none"
      }
    }

    return [
      new Plugin({
        key: pluginKey,
        view: () => ({
          update: () => {},
          destroy: () => {
            document.removeEventListener("mousemove", onDragMove)
            document.removeEventListener("mouseup", onDragEnd)
            handle?.remove()
            dropIndicator?.remove()
            contextPopup?.destroy()
          },
        }),
        props: {
          handleDOMEvents: {
            mousemove: (view, event) => {
              if (isDragging) return false
              if (handle?.contains(event.target)) return false

              // Try precise position first
              const pos = view.posAtCoords({
                left: event.clientX,
                top: event.clientY,
              })

              let result = null
              if (pos) {
                result = resolveTopLevelBlock(view, pos.pos)
              }

              // Fallback: find nearest block by Y coordinate
              if (!result) {
                result = findNearestBlock(view, event.clientY)
              }

              if (result) {
                showHandle(result.dom, result.pos)
              }

              return false
            },
            mouseleave: () => {
              if (!isDragging) scheduleHide()
              return false
            },
          },
        },
      }),
    ]
  },
})
