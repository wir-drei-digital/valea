import { describe, it, expect } from 'vitest';
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
import { fileIcon, folderIcon } from './file-icon';

describe('fileIcon', () => {
  it('picks a bucket per extension', () => {
    expect(fileIcon('notes.md')).toBe(FileText);
    expect(fileIcon('client.ts')).toBe(FileCode);
    expect(fileIcon('deploy.sh')).toBe(FileTerminal);
    expect(fileIcon('workspace.yaml')).toBe(FileBraces);
    expect(fileIcon('ledger.csv')).toBe(FileSpreadsheet);
    expect(fileIcon('logo.png')).toBe(FileImage);
    expect(fileIcon('invoice.pdf')).toBe(BookText);
    expect(fileIcon('backup.zip')).toBe(FileArchive);
  });

  it('matches well-known extension-less basenames', () => {
    expect(fileIcon('Dockerfile')).toBe(FileTerminal);
    expect(fileIcon('Justfile')).toBe(FileTerminal);
  });

  it('is case-insensitive', () => {
    expect(fileIcon('README.MD')).toBe(FileText);
  });

  it('falls back for a dotfile, an unknown extension, and an empty name', () => {
    expect(fileIcon('.env.example')).toBe(File);
    expect(fileIcon('LICENSE')).toBe(File);
    expect(fileIcon('archive.bin')).toBe(File);
    expect(fileIcon('')).toBe(File);
  });
});

describe('folderIcon', () => {
  it('states open and closed', () => {
    expect(folderIcon(true)).toBe(FolderOpen);
    expect(folderIcon(false)).toBe(Folder);
  });
});
