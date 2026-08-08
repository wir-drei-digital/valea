/**
 * The composer's config chips, remembered per workspace — pick a model once
 * and the next session starts with it.
 *
 * Keyed on the WIRE id (`configWireId`), never on the render `id`: the
 * latter is `config-`-prefixed for timeline uniqueness and the adapter
 * rejects it as an unknown option. `ChatView`'s `onSetConfig` already
 * receives the wire id, so that is what arrives here.
 *
 * Per workspace, not global: a strict work profile and a loose personal one
 * must not share a permission mode.
 *
 * Applied to NEWLY CREATED sessions only — `stageFor`/`takeStaged` are that
 * one-shot handoff, the same shape `initial-prompt.ts` uses for a pending
 * first turn, and for the same reason: the creating view and the store that
 * joins the channel are different components, and module state is what
 * bridges them. Resuming an old session keeps whatever configuration it had,
 * which is what you want when reopening last week's work.
 *
 * Storage is an enhancement, never a dependency (`persist.ts`): no
 * `localStorage` just means the memory lasts one app run.
 */
import { readJson, writeJson } from '$lib/persist';

const STORAGE_KEY = 'valea.composer-options';

type ByWorkspace = Record<string, Record<string, string>>;

function readStored(): ByWorkspace {
  const raw = readJson(STORAGE_KEY);
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return {};

  const out: ByWorkspace = {};
  for (const [workspaceId, options] of Object.entries(raw as Record<string, unknown>)) {
    if (!options || typeof options !== 'object' || Array.isArray(options)) continue;
    const clean: Record<string, string> = {};
    for (const [configId, value] of Object.entries(options as Record<string, unknown>)) {
      if (typeof value === 'string') clean[configId] = value;
    }
    out[workspaceId] = clean;
  }
  return out;
}

export class ComposerOptionsStore {
  #byWorkspace: ByWorkspace = readStored();
  /** session id -> the snapshot to apply on its first join. Never persisted: a reloaded session is no longer "just created". */
  #staged = new Map<string, Record<string, string>>();

  remember(workspaceId: string | null, configId: string, value: string): void {
    if (!workspaceId) return;
    this.#byWorkspace = {
      ...this.#byWorkspace,
      [workspaceId]: { ...(this.#byWorkspace[workspaceId] ?? {}), [configId]: value }
    };
    writeJson(STORAGE_KEY, this.#byWorkspace);
  }

  remembered(workspaceId: string | null): Record<string, string> {
    if (!workspaceId) return {};
    return { ...(this.#byWorkspace[workspaceId] ?? {}) };
  }

  /** Snapshot NOW, at creation — so a chip changed while the session boots does not retroactively alter what it starts with. */
  stageFor(sessionId: string, workspaceId: string | null): void {
    this.#staged.set(sessionId, this.remembered(workspaceId));
  }

  takeStaged(sessionId: string): Record<string, string> | null {
    const staged = this.#staged.get(sessionId) ?? null;
    this.#staged.delete(sessionId);
    return staged;
  }
}

export const composerOptions = new ComposerOptionsStore();
