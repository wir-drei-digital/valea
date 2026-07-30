/**
 * Session file-activity aggregation (file-activity rail — see
 * docs/superpowers/specs/2026-07-30-session-file-activity-design.md).
 * Pure: derives "which files did this session touch" from the timeline
 * items `AgentSessionStore` already holds. Chronology is the item's INDEX
 * in the ordered items array — snapshot items carry no per-item `seq`
 * (store class doc), so `seq` must never be used here.
 */
import type { AcpItemLike, ToolDiff, ToolLocation } from './item-shapes';
import { asString, toolDiff, toolLocations } from './item-shapes';

export type FileBadge = 'read' | 'edited' | 'created' | 'deleted' | 'renamed';

/** One completed edit call against a file; `diff` absent when the call carried none. */
export type FileEdit = { diff?: ToolDiff };

export type FileActivity = {
  key: string;
  relPath?: string;
  path: string;
  name: string;
  dir: string;
  kindBadge: FileBadge;
  read: boolean;
  edited: boolean;
  edits: FileEdit[];
  lastIndex: number;
};

/**
 * The `created` badge infers "new file" from an empty/absent `oldText` on the
 * file's FIRST completed edit diff. Nothing in the codebase proves overwrites
 * always carry `oldText` — this flag exists so the manual-acceptance pass can
 * flip it to false (falling back to `edited`) if a live overwrite arrives
 * without one. Known accepted miss while enabled: creating an EMPTY file (no
 * `newText`) shows `edited`.
 */
export const CREATED_INFERENCE_ENABLED: boolean = true;

/** Splits on `/` AND `\` — outside-mount paths arrive verbatim from the agent (Windows included). */
export function splitPathName(p: string): { name: string; dir: string } {
  const idx = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return idx === -1 ? { name: p, dir: '' } : { name: p.slice(idx + 1), dir: p.slice(0, idx) };
}

const FILE_KINDS = new Set(['read', 'edit', 'delete', 'move']);

type Accum = {
  relPath?: string;
  path: string;
  read: boolean;
  edited: boolean;
  deleted: boolean;
  renamed: boolean;
  edits: FileEdit[];
  lastIndex: number;
};

function dedupeLocations(locations: ToolLocation[]): ToolLocation[] {
  const seen = new Set<string>();
  return locations.filter((l) => {
    const key = l.relPath ?? l.path;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * Deterministic diff→row attribution (spec): single location wins outright;
 * otherwise the location whose path/relPath equals or suffix-matches
 * `diff.path`; otherwise the first location.
 */
function pickDiffLocation(
  locations: ToolLocation[],
  diff: ToolDiff | undefined
): ToolLocation | undefined {
  if (!diff) return undefined;
  if (locations.length <= 1) return locations[0];
  const target = diff.path;
  if (target) {
    const match = locations.find(
      (l) =>
        l.path === target ||
        l.relPath === target ||
        l.path.endsWith(`/${target}`) ||
        (l.relPath !== undefined && target.endsWith(`/${l.relPath}`))
    );
    if (match) return match;
  }
  return locations[0];
}

function badgeFor(a: Accum): FileBadge {
  if (a.deleted) return 'deleted';
  if (a.renamed) return 'renamed';
  if (a.edited && CREATED_INFERENCE_ENABLED) {
    const first = a.edits.find((e) => e.diff !== undefined);
    const d = first?.diff;
    if (d && !d.oldText && d.newText) return 'created';
  }
  if (a.edited) return 'edited';
  return 'read';
}

export function deriveFileActivity(items: AcpItemLike[]): FileActivity[] {
  const byKey = new Map<string, Accum>();

  const touch = (key: string, path: string, relPath: string | undefined, index: number): Accum => {
    const existing = byKey.get(key);
    if (existing) {
      existing.lastIndex = index;
      // Reachable via the synthesized row below: a diff-only edit is keyed by
      // `diff.path` with no relPath, so a later LOCATED call whose relPath
      // equals that key lands here carrying the backend-proven relPath. Take
      // it — without the upgrade the row stays "outside-mount", i.e. not
      // openable, for a file we now know sits in the mount.
      if (existing.relPath === undefined && relPath !== undefined) existing.relPath = relPath;
      return existing;
    }
    const created: Accum = {
      relPath,
      path,
      read: false,
      edited: false,
      deleted: false,
      renamed: false,
      edits: [],
      lastIndex: index
    };
    byKey.set(key, created);
    return created;
  };

  items.forEach((item, index) => {
    if (item.type !== 'tool') return;
    const kind = asString(item.kind);
    if (!FILE_KINDS.has(kind)) return;
    if (asString(item.status) !== 'completed') return;

    const locations = dedupeLocations(toolLocations(item));
    const diff = kind === 'edit' ? toolDiff(item) : undefined;

    if (locations.length === 0) {
      // Synthesize a row only for an edit that at least names its file.
      if (kind === 'edit' && diff?.path) {
        const acc = touch(diff.path, diff.path, undefined, index);
        acc.edited = true;
        acc.edits.push({ diff });
      }
      return;
    }

    const diffTarget = pickDiffLocation(locations, diff);
    for (const l of locations) {
      const acc = touch(l.relPath ?? l.path, l.path, l.relPath, index);
      if (kind === 'read') acc.read = true;
      if (kind === 'delete') acc.deleted = true;
      if (kind === 'move') acc.renamed = true;
      if (kind === 'edit') {
        acc.edited = true;
        acc.edits.push(l === diffTarget && diff ? { diff } : {});
      }
    }
  });

  return [...byKey.entries()]
    .map(([key, a]) => {
      const display = a.relPath ?? a.path;
      const { name, dir } = splitPathName(display);
      return {
        key,
        relPath: a.relPath,
        path: a.path,
        name,
        dir,
        kindBadge: badgeFor(a),
        read: a.read,
        edited: a.edited,
        edits: a.edits,
        lastIndex: a.lastIndex
      };
    })
    .sort((x, y) => {
      const xChanged = x.kindBadge !== 'read' ? 0 : 1;
      const yChanged = y.kindBadge !== 'read' ? 0 : 1;
      if (xChanged !== yChanged) return xChanged - yChanged;
      return y.lastIndex - x.lastIndex;
    });
}

/** Auto-open fires only on the 0 -> >0 transition of the derived count (attach included). */
export function shouldAutoOpen(prevCount: number, count: number, closedByUser: boolean): boolean {
  return !closedByUser && prevCount === 0 && count > 0;
}

const MAX_CLOSED_REMEMBERED = 50;

/**
 * Per-session "the user closed the rail" memory — in-memory only (a fresh
 * app launch starts over, deliberately), capped so an arbitrarily long run
 * can't grow it unboundedly. `close()` re-inserts at the end of the
 * insertion-ordered Set, so eviction drops the LEAST-RECENTLY-CLOSED id —
 * re-closing a session keeps it from aging out.
 */
export class ClosedRailMemory {
  #ids = new Set<string>();

  isClosed(id: string): boolean {
    return this.#ids.has(id);
  }

  close(id: string): void {
    this.#ids.delete(id);
    this.#ids.add(id);
    if (this.#ids.size > MAX_CLOSED_REMEMBERED) {
      const oldest = this.#ids.values().next().value;
      if (oldest !== undefined) this.#ids.delete(oldest);
    }
  }

  reopen(id: string): void {
    this.#ids.delete(id);
  }
}

export const closedRailMemory = new ClosedRailMemory();
