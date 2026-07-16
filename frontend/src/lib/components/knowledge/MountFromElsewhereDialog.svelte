<script lang="ts">
  // "Mount an existing ICM…" — Knowledge's by-reference mount dialog
  // (originally A2-T9's "Mount a folder from elsewhere…"). As of Task 10.4
  // this is ALSO the sidebar's "Mount an ICM" → "Mount an existing ICM…"
  // entry point (`MountIcmAction.svelte`) — ONE shared dialog rather than
  // two divergent ones (brief: "prefer ONE shared dialog component used
  // from both the sidebar footer and Knowledge").
  //
  // Picks an EXTERNAL folder (Tauri directory picker; browser-dev falls
  // back to a text input, same pattern `OpenWorkspaceFlow.svelte` uses) and
  // previews it via `inspect_icm` BEFORE anything mounts — same "we'll show
  // you what's inside before anything mounts" contract Task 10.3's
  // onboarding "Use existing ICM" flow already gives. Only a healthy,
  // format-2 ICM can be confirmed; nothing is ever copied or moved — the
  // folder stays exactly where it already lives.
  //
  // Task 10.4 drops the dialog's old "Name" field entirely:
  // `Valea.Api.Icms.mount_icm` derives the mount key from the target's OWN
  // manifest name and never reads a caller-supplied one — the field was
  // already inert, and the preview now shows the REAL name instead of
  // asking the user to redundantly retype it.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { mountsStore, declareMountErrorMessage } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { basename, type IcmInspection } from '$lib/components/onboarding/onboarding-path';
  import {
    adoptExisting,
    mountExisting,
    type AdoptExistingDeps,
    type MountExistingDeps
  } from '$lib/components/shell/mount-icm-action';

  let {
    open = $bindable(false),
    /**
     * Called after a successful mount, right before the dialog closes.
     * `MountIcmAction.svelte` (Task 10.4) uses this to navigate straight to
     * the newly-mounted ICM's own Knowledge view — same
     * `goToMountedIcm`-style continuation `useExistingIcm`'s onboarding
     * flow gives. Knowledge's own footer entry point leaves this unset: the
     * user is already looking at Knowledge, and `mountsStore.refresh()`
     * (below) is enough to make the new mount show up.
     */
    onMounted
  }: { open?: boolean; onMounted?: (mountKey: string) => void } = $props();

  let path = $state('');
  let inspecting = $state(false);
  let inspectError = $state<string | null>(null);
  let inspection = $state<IcmInspection | null>(null);
  let mounting = $state(false);
  let mountError = $state<string | null>(null);
  // Task 13: the adopt-a-folder consent step's editable "Name" field —
  // defaults to the picked folder's basename the moment an adoptable
  // inspection arrives (see `inspect()` below), stays independently
  // editable after that, same "defaults from, then independently editable"
  // shape `OpenWorkspaceFlow.svelte`'s `workspaceName` has.
  let adoptName = $state('');

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  $effect(() => {
    if (open) {
      path = '';
      inspecting = false;
      inspectError = null;
      inspection = null;
      mounting = false;
      mountError = null;
      adoptName = '';
    }
  });

  const icmName = $derived.by(() => {
    if (!inspection || !inspection.ok) return '';
    const trimmed = inspection.name?.trim();
    return trimmed ? trimmed : basename(path);
  });

  async function inspect() {
    inspectError = null;
    inspection = null;
    mountError = null;

    const trimmedPath = path.trim();
    if (!trimmedPath) {
      inspectError = 'Choose a folder to preview.';
      return;
    }

    inspecting = true;
    const result = await api.inspectIcm(trimmedPath);
    inspecting = false;

    if (!result.ok) {
      inspectError = 'Something went wrong while reading that folder. Try again.';
      return;
    }

    inspection = result.data as IcmInspection;
    if (!inspection.ok && inspection.adoptable) {
      adoptName = basename(trimmedPath);
    }
  }

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      path = selected;
      await inspect();
    }
  }

  // `api.inspectIcm`'s result already carries `{ok, name, description,
  // reason}` (the exact `IcmInspection` shape) once it's a channel/HTTP
  // success; only the outer `data` cast is needed, same as
  // `OpenWorkspaceFlow.svelte`'s own `inspectIcmDep`.
  async function inspectIcmDep(p: string): ReturnType<MountExistingDeps['inspectIcm']> {
    const result = await api.inspectIcm(p);
    if (!result.ok) return result;
    return { ok: true, data: result.data as unknown as IcmInspection };
  }

  // Calls `mount_icm` directly so a successful mount can report back WHICH
  // mount was created — `MountIcmAction.svelte`'s `onMounted` needs it to
  // navigate. Refreshes the catalog and clears any pending adoption-error
  // banner on success, same as `OpenWorkspaceFlow.svelte`'s `mountIcmDep`.
  async function mountIcmDep(p: string, generation: number): ReturnType<MountExistingDeps['mountIcm']> {
    const result = await api.mountIcm(p, generation);
    if (!result.ok) return result;
    const data = result.data as { mountKey: string; id: string };
    mountsStore.clearPendingAdoptError();
    await mountsStore.refresh();
    return { ok: true, mountKey: data.mountKey };
  }

  const deps: MountExistingDeps = {
    inspectIcm: inspectIcmDep,
    mountIcm: mountIcmDep
  };

  // Calls `adopt_icm` directly, same shape `mountIcmDep` above has — the one
  // consented write the adopt-a-folder consent step gates (Task 13),
  // followed by mounting in the same RPC round trip. Refreshes the catalog
  // and clears any pending adoption-error banner on success, same as
  // `mountIcmDep`.
  async function adoptIcmDep(p: string, name: string, generation: number): ReturnType<AdoptExistingDeps['adoptIcm']> {
    const result = await api.adoptIcm(p, name, generation);
    if (!result.ok) return result;
    const data = result.data as { mountKey: string; id: string };
    mountsStore.clearPendingAdoptError();
    await mountsStore.refresh();
    return { ok: true, mountKey: data.mountKey };
  }

  const adoptDeps: AdoptExistingDeps = {
    adoptIcm: adoptIcmDep
  };

  async function confirm() {
    if (!inspection || !inspection.ok) return;
    mountError = null;

    mounting = true;
    const outcome = await mountExisting(path.trim(), workspaceStore.generation ?? 0, deps);
    mounting = false;

    if (!outcome.ok) {
      // Stage 'inspect' only recurs here on a rare re-inspect-at-confirm-time
      // race (the Confirm button only renders once the PREVIEW's own inspect
      // already succeeded) — its `error` is already a human-readable
      // sentence (`IcmInspection.reason`), same as the preview card below.
      // Stage 'adoptable' is the same race turning the folder adoptable
      // instead — "Choose a different folder" re-inspects it, landing on the
      // consent card. Stage 'mount' is the real backend rejection
      // vocabulary, mapped through the same copy table Knowledge's
      // re-enable/undeclare flows use.
      if (outcome.stage === 'mount') {
        mountError = declareMountErrorMessage(outcome.error);
      } else if (outcome.stage === 'inspect') {
        mountError = outcome.error;
      } else {
        mountError = 'That folder changed since you last checked it — choose it again to continue.';
      }
      return;
    }

    open = false;
    onMounted?.(outcome.mountKey);
  }

  async function submitAdopt() {
    if (!inspection || inspection.ok || !inspection.adoptable) return;
    mountError = null;

    mounting = true;
    const outcome = await adoptExisting(path.trim(), adoptName.trim(), workspaceStore.generation ?? 0, adoptDeps);
    mounting = false;

    if (!outcome.ok) {
      // `adoptExisting` never re-inspects, so only the 'mount' stage is
      // actually reachable here — the other two `MountExistingOutcome`
      // variants exist for `mountExisting`'s sake, not this call site's.
      mountError = outcome.stage === 'mount' ? declareMountErrorMessage(outcome.error) : outcome.stage;
      return;
    }

    open = false;
    onMounted?.(outcome.mountKey);
  }

  function chooseDifferent() {
    path = '';
    inspection = null;
    inspectError = null;
    mountError = null;
    adoptName = '';
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Mount an existing ICM</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Reads a knowledge folder right where it already lives — we'll show you what's inside before anything mounts.
        Nothing is copied or moved.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-3">
      {#if inspection}
        <div class="border-paper-border bg-paper-card flex flex-col gap-3 rounded-lg border p-4">
          {#if inspection.ok}
            <div class="flex flex-col gap-1">
              <span class="text-ink-meta text-[11px] tracking-wide uppercase">Location</span>
              <p class="text-ink-meta font-mono text-[11.5px] break-all">{path}</p>
            </div>

            <div class="flex flex-col gap-1">
              <span class="text-ink-meta text-[11px] tracking-wide uppercase">Name</span>
              <p class="text-ink-heading text-[13.5px] font-semibold">{icmName}</p>
            </div>

            {#if inspection.description}
              <p class="text-ink-body text-[13px]">{inspection.description}</p>
            {/if}

            {#if mountError}
              <p role="alert" class="text-warn-ink text-[12.5px]">{mountError}</p>
            {/if}

            <div class="flex flex-wrap gap-2">
              <Button type="button" onclick={confirm} disabled={mounting}>
                {mounting ? 'Mounting…' : 'Mount this folder'}
              </Button>
              <Button type="button" variant="outline" onclick={chooseDifferent} disabled={mounting}>
                Choose a different folder
              </Button>
            </div>
          {:else if inspection.adoptable}
            <!-- Task 13 (Spec D §D4): the adopt-a-folder consent step —
                 `path` isn't a Valea ICM yet, but IS a plain folder Valea
                 could adopt. Copy is EXACT per the brief; the ONLY file this
                 writes is the identity file the copy names. -->
            <div class="flex flex-col gap-2.5">
              <p class="text-ink-body text-[13px]">
                This folder isn't a Valea ICM yet. Add a small identity file (icm.yaml) so Valea can
                recognize this folder. That's the only file Valea will write.
              </p>
              <div class="flex flex-col gap-1.5">
                <Label for="adopt-name">Name</Label>
                <Input id="adopt-name" bind:value={adoptName} disabled={mounting} />
              </div>

              {#if mountError}
                <p role="alert" class="text-warn-ink text-[12.5px]">{mountError}</p>
              {/if}

              <div class="flex flex-wrap gap-2">
                <Button type="button" disabled={mounting || !adoptName.trim()} onclick={() => void submitAdopt()}>
                  Add identity file &amp; mount
                </Button>
                <Button type="button" variant="outline" onclick={chooseDifferent} disabled={mounting}>
                  Choose a different folder
                </Button>
              </div>
            </div>
          {:else}
            <!-- 10.1 flag: `inspection.reason` is a human-readable sentence
                 — surfaced verbatim, calm styling, never remapped. -->
            <p class="text-ink-body text-[13px]">{inspection.reason}</p>
            <Button type="button" variant="outline" onclick={chooseDifferent}>Choose a different folder</Button>
          {/if}
        </div>
      {:else if isTauri}
        <Button type="button" variant="outline" onclick={pickFolder} disabled={inspecting}>
          {inspecting ? 'Checking…' : 'Choose folder…'}
        </Button>
      {:else}
        <div class="flex gap-2">
          <Input bind:value={path} disabled={inspecting} placeholder="/Users/you/Documents/client-notes" />
          <Button type="button" variant="outline" onclick={inspect} disabled={inspecting}>
            {inspecting ? 'Checking…' : 'Choose folder…'}
          </Button>
        </div>
        <p class="text-ink-meta text-[11px]">Dev only — the desktop app uses a folder picker here.</p>
      {/if}

      {#if inspectError}
        <p role="alert" class="text-warn-ink text-[12.5px]">{inspectError}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)}>Cancel</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
