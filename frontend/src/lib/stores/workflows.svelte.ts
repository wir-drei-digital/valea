import { api, type Api } from '../api/client';

/** Minimal surface of `api` this store depends on — same `Pick<Api, ...>` convention as the other T16 stores. */
type WorkflowsApi = Pick<Api, 'listWorkflows'>;

/** One row of `list_workflows` — mirrors `listWorkflowsFields` in `api/client.ts`. */
export type WorkflowListItem = {
  path: string;
  name: string;
  description?: string | null;
  enabled: boolean;
  triggerSource?: string | null;
  riskLevel: string;
  sourceCount?: number;
  steps?: unknown;
  /**
   * The owning mount's manifest display name (A-T15 — `Valea.Api.Agents`'s
   * `flatten_workflow/1` passes `Valea.Workflows.list/0`'s per-workflow
   * `mount` field through). Powers `WorkflowCard.svelte`'s "· <mount>"
   * provenance chip via `mountProvenanceLabel` (`workflowHref.ts`).
   */
  mount?: string;
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
