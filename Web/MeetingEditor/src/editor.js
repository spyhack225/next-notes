import { Editor } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import TaskList from '@tiptap/extension-task-list'
import TaskItem from '@tiptap/extension-task-item'
import Placeholder from '@tiptap/extension-placeholder'
import { TableKit } from '@tiptap/extension-table'
import MarkdownIt from 'markdown-it'

const markdownParser = new MarkdownIt({ html: false, linkify: true, breaks: true })
const canvas = document.querySelector('#editor')
const bubble = document.querySelector('#bubble')
const blockMenu = document.querySelector('#block-menu')
const slashMenu = document.querySelector('#slash-menu')
const gutter = document.querySelector('#gutter')
const status = document.querySelector('#status')
let activeBlock = null
let slashRange = null
let currentSlashItems = []
let slashIndex = 0
let applyingDocument = false

function send(type, extra = {}) {
  window.webkit?.messageHandlers?.notes?.postMessage({ type, ...extra })
}

const editor = new Editor({
  element: canvas,
  extensions: [
    StarterKit.configure({ link: { openOnClick: false, autolink: true } }),
    TaskList,
    TaskItem.configure({ nested: true }),
    TableKit.configure({ table: { resizable: true } }),
    Placeholder.configure({ placeholder: 'Write something, or type / for commands…', emptyEditorClass: 'is-empty' }),
  ],
  content: '',
  editorProps: {
    attributes: { 'aria-label': 'Meeting notes', spellcheck: 'true' },
    handleKeyDown(_view, event) {
      if (event.key === 'Escape') { hideMenus(); return false }
      if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); formats.link(); return true }
      if (slashMenu.classList.contains('visible') && ['ArrowUp', 'ArrowDown'].includes(event.key)) {
        event.preventDefault()
        slashIndex = (slashIndex + (event.key === 'ArrowDown' ? 1 : -1) + currentSlashItems.length) % currentSlashItems.length
        highlightSlashItem()
        return true
      }
      if (event.key === 'Enter' && slashMenu.classList.contains('visible')) {
        event.preventDefault()
        if (currentSlashItems[slashIndex]) applySlash(currentSlashItems[slashIndex])
        return true
      }
      return false
    },
  },
  onUpdate() {
    if (!applyingDocument) send('changed', { html: editor.getHTML(), markdown: toMarkdown(editor.getJSON()) })
    updateSlashMenu()
    updateGutter()
  },
  onSelectionUpdate() { updateBubble(); updateSlashMenu(); updateGutter() },
  onFocus() { updateGutter() },
  onBlur() { window.setTimeout(() => { if (!document.activeElement?.closest('.menu, #bubble, #gutter')) hideMenus() }, 160) },
})

function escapeMarkdown(text) { return text.replace(/([\\`*_\[\]])/g, '\\$1') }
function inline(nodes = []) {
  return nodes.map(node => {
    if (node.type === 'hardBreak') return '  \n'
    let value = node.type === 'text' ? escapeMarkdown(node.text || '') : inline(node.content)
    for (const mark of node.marks || []) {
      if (mark.type === 'bold') value = `**${value}**`
      else if (mark.type === 'italic') value = `*${value}*`
      else if (mark.type === 'strike') value = `~~${value}~~`
      else if (mark.type === 'code') value = `\`${node.text || ''}\``
      else if (mark.type === 'link' && /^https?:\/\//i.test(mark.attrs?.href || '')) value = `[${value}](${mark.attrs.href})`
      else if (mark.type === 'underline') value = `<u>${value}</u>`
    }
    return value
  }).join('')
}
function block(node, depth = 0) {
  const children = node.content || []
  const content = inline(children)
  if (node.type === 'paragraph') return content
  if (node.type === 'heading') return `${'#'.repeat(node.attrs?.level || 1)} ${content}`
  if (node.type === 'blockquote') return children.map(child => block(child).split('\n').map(line => `> ${line}`).join('\n')).join('\n>\n')
  if (node.type === 'codeBlock') return `\`\`\`${node.attrs?.language || ''}\n${children.map(child => child.text || '').join('')}\n\`\`\``
  if (node.type === 'horizontalRule') return '---'
  if (node.type === 'table') {
    const rows = children.map(row => (row.content || []).map(cell => (cell.content || [])
      .map(part => inline(part.content || []).replace(/\|/g, '\\|')).join('<br>')))
    const columns = Math.max(1, ...rows.map(row => row.length))
    const header = rows.shift() || Array(columns).fill('')
    return [
      `| ${header.join(' | ')} |`,
      `| ${Array(columns).fill('---').join(' | ')} |`,
      ...rows.map(row => `| ${row.join(' | ')} |`),
    ].join('\n')
  }
  if (node.type === 'bulletList' || node.type === 'orderedList' || node.type === 'taskList') {
    return children.map((item, i) => {
      const marker = node.type === 'taskList' ? `- [${item.attrs?.checked ? 'x' : ' '}] ` : node.type === 'orderedList' ? `${(node.attrs?.start || 1) + i}. ` : '- '
      const parts = (item.content || []).map(child => block(child, depth + 1))
      const first = parts.shift() || ''
      const rest = parts.map(part => part.split('\n').map(line => `  ${line}`).join('\n')).join('\n')
      return `${'  '.repeat(depth)}${marker}${first}${rest ? `\n${rest}` : ''}`
    }).join('\n')
  }
  return children.map(child => block(child, depth)).join('\n\n')
}
function toMarkdown(doc) { return (doc.content || []).map(node => block(node)).join('\n\n').trim() }
function legacyHTML(markdown) {
  const wrapper = document.createElement('div')
  wrapper.innerHTML = markdownParser.render(markdown || '')
  wrapper.querySelectorAll('li').forEach(item => {
    const first = item.firstChild
    if (first?.nodeType !== Node.TEXT_NODE) return
    const match = first.textContent.match(/^\[([ xX])\]\s*/)
    if (!match || item.parentElement?.tagName !== 'UL') return
    first.textContent = first.textContent.slice(match[0].length)
    item.parentElement.setAttribute('data-type', 'taskList')
    item.setAttribute('data-type', 'taskItem')
    item.setAttribute('data-checked', match[1].toLowerCase() === 'x' ? 'true' : 'false')
  })
  return wrapper.innerHTML
}

const blocks = [
  ['Text', 'text', 'Plain paragraph', () => editor.chain().focus().setParagraph().run()],
  ['Heading 1', 'h1', 'Large heading', () => editor.chain().focus().toggleHeading({ level: 1 }).run()],
  ['Heading 2', 'h2', 'Medium heading', () => editor.chain().focus().toggleHeading({ level: 2 }).run()],
  ['Heading 3', 'h3', 'Small heading', () => editor.chain().focus().toggleHeading({ level: 3 }).run()],
  ['Bulleted list', 'bullets', 'Simple list', () => editor.chain().focus().toggleBulletList().run()],
  ['Numbered list', 'numbers', 'Steps in order', () => editor.chain().focus().toggleOrderedList().run()],
  ['To-do list', 'todo', 'Tasks with checkboxes', () => editor.chain().focus().toggleTaskList().run()],
  ['Quote', 'quote', 'Quoted text', () => editor.chain().focus().toggleBlockquote().run()],
  ['Code', 'code', 'Code block', () => editor.chain().focus().toggleCodeBlock().run()],
  ['Divider', 'divider', 'Horizontal line', () => editor.chain().focus().setHorizontalRule().run()],
  ['Table', 'table', 'Grid for details', () => editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run()],
]

function hideMenus() {
  bubble.classList.remove('visible')
  blockMenu.classList.remove('visible')
  slashMenu.classList.remove('visible')
}
function positionMenu(element, rect) {
  const left = Math.max(8, Math.min(rect.left, window.innerWidth - element.offsetWidth - 8))
  const top = Math.max(8, Math.min(rect.bottom + 7, window.innerHeight - element.offsetHeight - 8))
  element.style.left = `${left}px`
  element.style.top = `${top}px`
}
function makeMenuItem(label, hint, action) {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'menu-item'
  const name = document.createElement('span')
  name.textContent = label
  const detail = document.createElement('small')
  detail.textContent = hint
  button.append(name, detail)
  button.addEventListener('mousedown', event => event.preventDefault())
  button.addEventListener('click', () => { action(); hideMenus(); updateGutter() })
  return button
}
function fillBlocks(target, choices = blocks, replace = true) {
  const items = choices.map(([label, , hint, action]) => makeMenuItem(label, hint, action))
  if (replace) target.replaceChildren(...items)
  else target.append(...items)
}
function updateBubble() {
  if (editor.state.selection.empty || !editor.isFocused) { bubble.classList.remove('visible'); return }
  const rect = window.getSelection()?.getRangeAt(0)?.getBoundingClientRect()
  if (!rect) return
  bubble.classList.add('visible')
  positionMenu(bubble, rect)
  bubble.querySelectorAll('[data-format]').forEach(button => {
    const format = button.dataset.format
    button.classList.toggle('active', format.startsWith('h') ? editor.isActive('heading', { level: Number(format[1]) }) : editor.isActive(format))
  })
}

const formats = {
  bold: () => editor.chain().focus().toggleBold().run(),
  italic: () => editor.chain().focus().toggleItalic().run(),
  underline: () => editor.chain().focus().toggleUnderline().run(),
  strike: () => editor.chain().focus().toggleStrike().run(),
  code: () => editor.chain().focus().toggleCode().run(),
  link: () => {
    const existing = editor.getAttributes('link').href || ''
    const url = window.prompt('Link URL', existing || 'https://')
    if (url === null) return
    if (!url.trim()) editor.chain().focus().unsetLink().run()
    else if (/^https?:\/\//i.test(url)) editor.chain().focus().extendMarkRange('link').setLink({ href: url }).run()
    else send('error', { message: 'Use a link beginning with https:// or http://' })
  },
}
bubble.querySelectorAll('[data-format]').forEach(button => {
  button.addEventListener('mousedown', event => event.preventDefault())
  button.addEventListener('click', () => { formats[button.dataset.format]?.(); updateBubble() })
})
for (const [selector, choices] of [
  ['#text-style', blocks.slice(0, 4)],
  ['#list-style', blocks.slice(4, 7)],
]) {
  const button = bubble.querySelector(selector)
  button.addEventListener('mousedown', event => event.preventDefault())
  button.addEventListener('click', () => {
    fillBlocks(blockMenu, choices)
    blockMenu.classList.add('visible')
    positionMenu(blockMenu, bubble.getBoundingClientRect())
  })
}

function currentBlock() {
  const { $from } = editor.state.selection
  if ($from.depth < 1) return null
  const pos = $from.before(1)
  return { pos, node: $from.node(1), dom: editor.view.nodeDOM(pos) }
}
function updateGutter() {
  activeBlock = currentBlock()
  const rect = activeBlock?.dom instanceof Element ? activeBlock.dom.getBoundingClientRect() : null
  if (!rect || rect.bottom < 0 || rect.top > window.innerHeight) { gutter.classList.remove('visible'); return }
  gutter.classList.add('visible')
  gutter.style.top = `${rect.top + 2}px`
}
function openBlockMenu() {
  const block = currentBlock()
  if (!block) return
  activeBlock = block
  blockMenu.replaceChildren()
  const caption = document.createElement('div')
  caption.className = 'menu-caption'
  caption.textContent = 'Turn into'
  blockMenu.append(caption)
  fillBlocks(blockMenu, blocks, false)
  const divider = document.createElement('div')
  divider.className = 'menu-divider'
  blockMenu.append(divider)
  blockMenu.append(makeMenuItem('Duplicate', 'Copy this block below', () => {
    const { pos, node } = activeBlock
    editor.view.dispatch(editor.state.tr.insert(pos + node.nodeSize, node.copy(node.content)))
  }))
  blockMenu.append(makeMenuItem('Copy', 'Copy block text', () => send('copy', { text: activeBlock.node.textContent })))
  if (editor.isActive('table')) {
    blockMenu.append(makeMenuItem('Add row', 'Below this row', () => editor.chain().focus().addRowAfter().run()))
    blockMenu.append(makeMenuItem('Add column', 'To the right', () => editor.chain().focus().addColumnAfter().run()))
    blockMenu.append(makeMenuItem('Delete row', 'Remove this row', () => editor.chain().focus().deleteRow().run()))
    blockMenu.append(makeMenuItem('Delete column', 'Remove this column', () => editor.chain().focus().deleteColumn().run()))
  }
  blockMenu.append(makeMenuItem('Move up', 'Move this block earlier', () => moveBlock(-1)))
  blockMenu.append(makeMenuItem('Move down', 'Move this block later', () => moveBlock(1)))
  blockMenu.append(makeMenuItem('Delete', 'Remove this block', () => {
    const { pos, node } = activeBlock
    editor.view.dispatch(editor.state.tr.delete(pos, pos + node.nodeSize))
  }))
  blockMenu.classList.add('visible')
  positionMenu(blockMenu, gutter.getBoundingClientRect())
}
gutter.querySelector('#add-block').addEventListener('click', () => {
  const block = currentBlock()
  if (!block) return
  editor.chain().focus(block.pos + block.node.nodeSize).insertContentAt(block.pos + block.node.nodeSize, { type: 'paragraph' }).run()
  fillBlocks(blockMenu)
  blockMenu.classList.add('visible')
  positionMenu(blockMenu, gutter.getBoundingClientRect())
})
gutter.querySelector('#block-actions').addEventListener('click', openBlockMenu)
function moveBlock(direction) {
  const block = activeBlock
  if (!block) return
  const doc = editor.state.doc
  const sibling = direction < 0 ? doc.childBefore(block.pos) : doc.childAfter(block.pos + block.node.nodeSize)
  if (!sibling.node) return
  const destination = direction < 0 ? sibling.offset : block.pos + sibling.node.nodeSize
  editor.view.dispatch(editor.state.tr.delete(block.pos, block.pos + block.node.nodeSize).insert(destination, block.node))
}
let draggedBlock = null
const handle = gutter.querySelector('#block-actions')
handle.draggable = true
handle.title = 'Drag to move, click for block actions'
handle.addEventListener('dragstart', event => {
  draggedBlock = currentBlock()
  if (!draggedBlock) { event.preventDefault(); return }
  event.dataTransfer.effectAllowed = 'move'
  event.dataTransfer.setData('text/plain', 'meeting-block')
})
canvas.addEventListener('dragover', event => {
  if (!draggedBlock) return
  event.preventDefault()
  event.dataTransfer.dropEffect = 'move'
})
canvas.addEventListener('drop', event => {
  if (!draggedBlock) return
  event.preventDefault()
  const coords = editor.view.posAtCoords({ left: event.clientX, top: event.clientY })
  if (!coords) return
  const $target = editor.state.doc.resolve(coords.pos)
  if ($target.depth < 1) return
  const targetPos = $target.before(1)
  const targetNode = $target.node(1)
  const targetDOM = editor.view.nodeDOM(targetPos)
  const after = targetDOM instanceof Element && event.clientY > targetDOM.getBoundingClientRect().top + targetDOM.getBoundingClientRect().height / 2
  let insertPos = targetPos + (after ? targetNode.nodeSize : 0)
  if (insertPos > draggedBlock.pos) insertPos -= draggedBlock.node.nodeSize
  if (insertPos !== draggedBlock.pos) editor.view.dispatch(editor.state.tr.delete(draggedBlock.pos, draggedBlock.pos + draggedBlock.node.nodeSize).insert(insertPos, draggedBlock.node))
  draggedBlock = null
})
handle.addEventListener('dragend', () => { draggedBlock = null })

function updateSlashMenu() {
  const { $from, empty } = editor.state.selection
  const textBefore = $from.parent.textBetween(0, $from.parentOffset)
  const match = empty && textBefore.match(/(?:^|\s)\/([^\s]*)$/)
  if (!match || !editor.isFocused) { slashMenu.classList.remove('visible'); slashRange = null; return }
  currentSlashItems = blocks.filter(([label, alias]) => `${label} ${alias}`.toLowerCase().includes(match[1].toLowerCase()))
  if (!currentSlashItems.length) { slashMenu.classList.remove('visible'); return }
  slashRange = { from: $from.pos - match[0].length + (match[0].startsWith('/') ? 0 : 1), to: $from.pos }
  fillBlocks(slashMenu, currentSlashItems.map(([label, alias, hint, action]) => [label, alias, hint, () => applySlash([label, alias, hint, action])]))
  slashIndex = 0
  highlightSlashItem()
  slashMenu.classList.add('visible')
  const rect = editor.view.coordsAtPos($from.pos)
  positionMenu(slashMenu, { left: rect.left, bottom: rect.bottom })
}
function highlightSlashItem() {
  slashMenu.querySelectorAll('.menu-item').forEach((button, index) => button.classList.toggle('selected', index === slashIndex))
}
function applySlash(item) {
  if (!slashRange) return
  editor.chain().focus().deleteRange(slashRange).run()
  slashRange = null
  item[3]()
  hideMenus()
}

window.setDocument = ({ html, markdown }) => {
  applyingDocument = true
  const content = html || legacyHTML(markdown) || '<p></p>'
  editor.commands.setContent(content, { emitUpdate: false })
  applyingDocument = false
  updateGutter()
  send('loaded', { markdown: toMarkdown(editor.getJSON()) })
}
window.addEventListener('resize', () => { updateGutter(); updateBubble() })
document.addEventListener('scroll', updateGutter, true)
document.addEventListener('click', event => {
  if (!event.target.closest('#gutter, .menu, #bubble')) blockMenu.classList.remove('visible')
  const anchor = event.target.closest('#editor a')
  if (anchor && (event.metaKey || event.ctrlKey)) { event.preventDefault(); send('openLink', { url: anchor.href }) }
})
status.textContent = 'Saved automatically'
send('ready')
