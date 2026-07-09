import type { Component } from 'svelte';
import Inbox from '@lucide/svelte/icons/inbox';
import Mail from '@lucide/svelte/icons/mail';
import Calendar from '@lucide/svelte/icons/calendar';
import MessageSquare from '@lucide/svelte/icons/message-square';
import ListTodo from '@lucide/svelte/icons/list-todo';
import RefreshCw from '@lucide/svelte/icons/refresh-cw';
import BookOpen from '@lucide/svelte/icons/book-open';
import Folder from '@lucide/svelte/icons/folder';
import Plug from '@lucide/svelte/icons/plug';
import ListChecks from '@lucide/svelte/icons/list-checks';

export type IcmNode = {
  name: string;
  path: string;
  type: 'folder' | 'page';
  children?: IcmNode[];
  pageCount?: number;
  uri?: string;
};

// Loosely typed so any lucide icon component (or compatible svelte component) is accepted.
export type NavIcon = Component<Record<string, unknown>>;

export type NavItem = { id: string; label: string; href: string; icon: NavIcon };
export type NavSection = { label: string | null; items: NavItem[] };
export type NavTreeItem = { label: string; href: string; count?: number; children?: NavTreeItem[] };

export function mainNav(): NavSection[] {
  return [
    {
      label: null,
      items: [
        { id: 'today', label: 'Today', href: '/', icon: Inbox },
        { id: 'mail', label: 'Mail', href: '/mail', icon: Mail },
        { id: 'calendar', label: 'Calendar', href: '/calendar', icon: Calendar },
        { id: 'chat', label: 'Chat', href: '/chat', icon: MessageSquare },
        { id: 'tasks', label: 'Tasks', href: '/tasks', icon: ListTodo }
      ]
    },
    {
      label: 'Assistant',
      items: [
        { id: 'workflows', label: 'Workflows', href: '/workflows', icon: RefreshCw },
        { id: 'knowledge', label: 'Knowledge', href: '/knowledge', icon: BookOpen },
        { id: 'files', label: 'Files', href: '/files', icon: Folder }
      ]
    },
    {
      label: 'System',
      items: [
        { id: 'sources', label: 'Sources', href: '/sources', icon: Plug },
        { id: 'audit', label: 'Audit log', href: '/audit', icon: ListChecks }
      ]
    }
  ];
}

export function encodePath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/');
}

export function icmToNav(nodes: IcmNode[]): NavTreeItem[] {
  return nodes.map((n) =>
    n.type === 'folder'
      ? {
          label: n.name,
          href: `/knowledge/${encodePath(n.path)}`,
          count: n.pageCount,
          children: icmToNav(n.children ?? [])
        }
      : { label: n.name, href: `/knowledge/${encodePath(n.path)}` }
  );
}
