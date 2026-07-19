import type { Component } from 'svelte';
import Inbox from '@lucide/svelte/icons/inbox';
import Mail from '@lucide/svelte/icons/mail';
import Calendar from '@lucide/svelte/icons/calendar';
import MessageSquare from '@lucide/svelte/icons/message-square';
import ListTodo from '@lucide/svelte/icons/list-todo';
import BookOpen from '@lucide/svelte/icons/book-open';
import Folder from '@lucide/svelte/icons/folder';
import Plug from '@lucide/svelte/icons/plug';
import ListChecks from '@lucide/svelte/icons/list-checks';

export type IcmNode = {
  name: string;
  /** Relative to `mountKey`'s own ICM root (task 4.2 re-key) — never workspace-relative, never absolute. */
  path: string;
  /** The ICM this node belongs to (`Valea.Mounts`'s `icms:` config key) — every node self-describes its own mount so a flattened, multi-mount list (`flattenMountGroups`) can still build a correct href per node. */
  mountKey: string;
  /**
   * `'file'` (A-T15 fix wave) is a non-.md regular file (media, PDF, ...) —
   * listed by `Valea.ICM.tree_for/1` as a leaf with `ext` (lowercase, e.g.
   * `".pdf"`) for icon selection, but never editable/navigable: only `.md`
   * pages open in the editor.
   */
  type: 'folder' | 'page' | 'file';
  children?: IcmNode[];
  pageCount?: number;
  uri?: string;
  /** Lowercase extension incl. the dot (file leaves only), e.g. `".pdf"`. */
  ext?: string;
};

// Loosely typed so any lucide icon component (or compatible svelte component) is accepted.
export type NavIcon = Component<Record<string, unknown>>;

export type NavItem = { id: string; label: string; href: string; icon: NavIcon };
export type NavSection = { label: string | null; items: NavItem[] };
export type NavTreeItem = {
  label: string;
  href: string;
  /** Raw (undecoded, unencoded) icm/ path — what the CRUD API calls expect. */
  path: string;
  /** The ICM this item belongs to — what the CRUD API calls' `mountKey` argument expects (task 4.2/4.3 re-key). */
  mountKey: string;
  count?: number;
  children?: NavTreeItem[];
};

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
    // ONE workspace-wide utility group (the old "Assistant"/"System" split
    // said nothing — Knowledge/Files aren't assistant-specific). The primary
    // Projects section is rendered by the Sidebar between the daily group
    // and this one.
    {
      label: 'Workspace',
      items: [
        { id: 'knowledge', label: 'Knowledge', href: '/knowledge', icon: BookOpen },
        { id: 'files', label: 'Files', href: '/files', icon: Folder },
        { id: 'sources', label: 'Sources', href: '/sources', icon: Plug },
        { id: 'audit', label: 'Audit log', href: '/audit', icon: ListChecks }
      ]
    }
  ];
}

export function encodePath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/');
}

/**
 * Flattens every mount group's tree into a single array, in group order —
 * the shape every pre-A-T15 consumer of the now-deleted `icmStore.nodes`
 * back-compat getter expected. Structurally typed against just `{ tree:
 * IcmNode[] }` (rather than importing `MountGroup` from `stores/icm.svelte`)
 * so this stays a leaf pure-logic module with no reverse dependency on the
 * store layer. Used by consumers that need a single flat search/nav list
 * (the sidebar's persistent `IcmTree` flyout, page-path lookups) — NOT by
 * the Knowledge route's own per-mount section rendering, which reads
 * `icmStore.groups` directly (see `components/knowledge/mount-sections.ts`).
 */
export function flattenMountGroups(groups: Array<{ tree: IcmNode[] }>): IcmNode[] {
  return groups.flatMap((g) => g.tree);
}

/** `/knowledge/<mountKey>/<rel>` (task 4.3) — mountKey and the ICM-relative path are each independently URL-encoded, then joined, so a `/` inside a mount key (never legal per `Valea.Mounts`'s own validation) can't be confused with the path separator. */
export function knowledgeHref(mountKey: string, path: string): string {
  return `/knowledge/${encodeURIComponent(mountKey)}/${encodePath(path)}`;
}

export function icmToNav(nodes: IcmNode[]): NavTreeItem[] {
  return nodes.flatMap((n): NavTreeItem[] => {
    if (n.type === 'folder') {
      return [
        {
          label: n.name,
          href: knowledgeHref(n.mountKey, n.path),
          path: n.path,
          mountKey: n.mountKey,
          count: n.pageCount,
          children: icmToNav(n.children ?? [])
        }
      ];
    }
    // A-T15 fix wave: file leaves never get an editor href — only .md pages
    // open in the editor, so a `/knowledge/<path>` link for a PDF would be a
    // dead page. They're dropped from the sidebar nav entirely; the Knowledge
    // route's own list panes render them as non-clickable rows instead.
    if (n.type === 'file') {
      return [];
    }
    return [{ label: n.name, href: knowledgeHref(n.mountKey, n.path), path: n.path, mountKey: n.mountKey }];
  });
}
