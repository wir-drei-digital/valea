/**
 * A tree row's single glyph. Replaces the uppercase format badge that used
 * to TRAIL a file's name: a badge answered "what format is this" only after
 * you had already read the name, and every row paid for it in width.
 *
 * Monochrome by design — the icon sits at the row's own `text-ink-meta`
 * weight and never reaches for colour. Being a spreadsheet is a fact about a
 * file, not a consequence, and the design system reserves colour for
 * consequences.
 *
 * Keyed on the LABEL, not on `NavTreeItem.ext`: since pages carry their
 * `.md` (see `icmToNav`), the label IS the true basename for every leaf
 * kind, and `ext` is populated for file leaves only. One input, one rule, no
 * kind branch.
 */
import File from '@lucide/svelte/icons/file';
import FileArchive from '@lucide/svelte/icons/file-archive';
import FileBraces from '@lucide/svelte/icons/file-braces';
import FileCode from '@lucide/svelte/icons/file-code';
import FileImage from '@lucide/svelte/icons/file-image';
import FileSpreadsheet from '@lucide/svelte/icons/file-spreadsheet';
import FileTerminal from '@lucide/svelte/icons/file-terminal';
import FileText from '@lucide/svelte/icons/file-text';
import BookText from '@lucide/svelte/icons/book-text';
import Folder from '@lucide/svelte/icons/folder';
import FolderOpen from '@lucide/svelte/icons/folder-open';
import type { NavIcon } from '$lib/shell/nav';

// `file-braces`, NOT `file-json`: the installed @lucide/svelte ships the
// former and has no icon by the latter name.
const BY_EXTENSION: Record<string, NavIcon> = {
  md: FileText, markdown: FileText, txt: FileText, rtf: FileText,

  ts: FileCode, tsx: FileCode, mts: FileCode, cts: FileCode,
  js: FileCode, jsx: FileCode, mjs: FileCode, cjs: FileCode,
  svelte: FileCode, vue: FileCode, html: FileCode, htm: FileCode,
  css: FileCode, scss: FileCode,
  ex: FileCode, exs: FileCode, heex: FileCode, eex: FileCode,
  rs: FileCode, py: FileCode, rb: FileCode, go: FileCode,
  java: FileCode, kt: FileCode, swift: FileCode,
  c: FileCode, h: FileCode, cpp: FileCode, cc: FileCode, hpp: FileCode,
  cs: FileCode, php: FileCode, sql: FileCode,

  sh: FileTerminal, bash: FileTerminal, zsh: FileTerminal, fish: FileTerminal,

  json: FileBraces, yaml: FileBraces, yml: FileBraces,
  toml: FileBraces, xml: FileBraces, ini: FileBraces,

  csv: FileSpreadsheet, tsv: FileSpreadsheet, xlsx: FileSpreadsheet,

  png: FileImage, jpg: FileImage, jpeg: FileImage,
  gif: FileImage, webp: FileImage, svg: FileImage,

  pdf: BookText,

  zip: FileArchive, tar: FileArchive, gz: FileArchive
};

/** Files that carry their type in their whole name rather than an extension. */
const BY_BASENAME: Record<string, NavIcon> = {
  dockerfile: FileTerminal,
  justfile: FileTerminal,
  makefile: FileTerminal
};

export function fileIcon(label: string): NavIcon {
  const base = (label.split('/').pop() ?? '').toLowerCase();
  if (!base) return File;

  const byName = BY_BASENAME[base];
  if (byName) return byName;

  // `> 0`, not `>= 0`: a leading dot is a dotfile, not an extension.
  const dot = base.lastIndexOf('.');
  if (dot <= 0) return File;

  return BY_EXTENSION[base.slice(dot + 1)] ?? File;
}

export function folderIcon(open: boolean): NavIcon {
  return open ? FolderOpen : Folder;
}
