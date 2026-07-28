import type { Component } from 'svelte';
import Inbox from '@lucide/svelte/icons/inbox';
import Mail from '@lucide/svelte/icons/mail';
import Calendar from '@lucide/svelte/icons/calendar';
import MessageSquare from '@lucide/svelte/icons/message-square';
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
  /**
   * Lazy-tree marker (folders only): `false` means `children` is just the
   * not-yet-fetched placeholder `[]`, not a genuinely empty folder — the
   * tree UI shows a loading row and `IcmStore.loadDir` fills it in on
   * demand. Nodes from an eagerly-fetched full tree (`icm_tree`) are
   * stamped `true` throughout.
   */
  childrenLoaded?: boolean;
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
  /** Folders only — mirrors `IcmNode.childrenLoaded` (see its doc comment). */
  loaded?: boolean;
};

export function mainNav(): NavSection[] {
  return [
    {
      label: null,
      items: [
        { id: 'today', label: 'Today', href: '/', icon: Inbox },
        { id: 'mail', label: 'Mail', href: '/mail', icon: Mail },
        { id: 'calendar', label: 'Calendar', href: '/calendar', icon: Calendar },
        { id: 'chat', label: 'Chat', href: '/chat', icon: MessageSquare }
      ]
    },
    // ONE workspace-wide utility group. The primary Projects section is
    // rendered by the Sidebar between the daily group and this one; the
    // file browser (the route still at /knowledge, titled "Files") is
    // reached through each project's own row/actions rather than a global
    // nav item — projects ARE the object, the browser is how you open one.
    {
      label: 'Workspace',
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

/**
 * Depth-first lookup of the node at `path` (ICM-relative) in one mount's
 * tree. Descends only into folders whose path is a `/`-boundary prefix of
 * `path` — in a lazy tree most siblings hold unloaded `[]` placeholders,
 * and there is never a reason to walk them.
 */
export function findIcmNode(nodes: IcmNode[], path: string): IcmNode | undefined {
  for (const node of nodes) {
    if (node.path === path) return node;
    if (node.type === 'folder' && path.startsWith(node.path + '/')) {
      const found = findIcmNode(node.children ?? [], path);
      if (found) return found;
    }
  }
  return undefined;
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
          children: icmToNav(n.children ?? []),
          loaded: n.childrenLoaded !== false
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
