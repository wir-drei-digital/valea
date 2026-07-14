import { api, type Api } from '../api/client';

/** Minimal surface of `api` this store depends on — same `Pick<Api, ...>` convention as the other T16 stores. */
type WorkflowsApi = Pick<Api, 'listWorkflows'>;

/**
 * One row of `list_workflows` — mirrors `listWorkflowsFields` in
 * `api/client.ts`. Task 7.1 re-keys the registry: a workflow's identity is
 * `{icmId, relativePath}` (`icmId` the owning ICM's stable manifest UUID,
 * survives the ICM moving or being re-mounted under a different key);
 * `mountKey` is the CURRENT workspace-local `icms:` config key (needed to
 * address the ICM — e.g. for a future `{mountKey, relativePath}`-scoped
 * run, Task 7.2). `resolvedPath` is the current absolute path (for the
 * Knowledge "Edit →" link) — not part of the identity, since it changes if
 * the ICM folder moves and `mountKey`/`icmId` do not.
 */
export type WorkflowListItem = {
  icmId: string;
  mountKey: string;
  relativePath: string;
  resolvedPath: string;
  name: string;
  description?: string | null;
  enabled: boolean;
  triggerSource?: string | null;
  riskLevel: string;
  sourceCount?: number;
  steps?: unknown;
  /**
   * The owning ICM's manifest display name (`Valea.Api.Agents`'s
   * `flatten_workflow/2` resolves this from `mountKey` — see its own
   * moduledoc note). Powers `WorkflowCard.svelte`'s "· <mount>" provenance
   * chip via `mountProvenanceLabel` (`workflowHref.ts`).
   */
  icmName?: string;
};

/**
 * Workflow catalog. Workflow definitions live under `workflows/` as ICM-style
 * markdown-with-frontmatter files, so — like `icmStore` — this needs a
 * refetch whenever the backend reports an `icm_changed` push. That wiring is
 * NOT done here: `icm.svelte.ts` (which owns the single `workspace:events`
 * join site — see its `wireIcmEvents` doc) is out of this task's file list,
 * so the caller that eventually wires `workspace:events` up (a later
 * Chat/Workflows UI task) is responsible for also calling
 * `workflowsStore.refetch()` from that same `icm_changed` handler, the same
 * way `wireQueueEvents` (`queue.svelte.ts`) needs the shared channel handed
 * to it rather than opening its own join.
 */
export class WorkflowsStore {
  list: WorkflowListItem[] = $state([]);
  loaded = $state(false);

  #api: WorkflowsApi;

  constructor(api: WorkflowsApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.listWorkflows();
    if (!result.ok) return;

    const data = result.data as { workflows?: WorkflowListItem[] };
    this.list = data.workflows ?? [];
    this.loaded = true;
  }
}

export const workflowsStore = new WorkflowsStore(api);
