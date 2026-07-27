<script lang="ts">
  // The Skills section of the agent settings modal (ICM skills design spec
  // §Frontend). Lists every mounted ICM and, per ICM, the catalog skills
  // with their current on-disk state (`Valea.Skills.state/2`) and the one
  // action that state offers (`actionFor`). Install/update route through the
  // consent dialog; remove asks a plain confirm first. Nothing here writes
  // without an explicit click — the RPCs are control-token-gated and
  // generation-guarded, and the click is the consent.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { MountSummary } from '$lib/stores/mounts.svelte';
  import SkillConsentDialog from './SkillConsentDialog.svelte';
  import { actionFor, stateLabel, type SkillRow } from './skills-rows';

  type Group = { mountKey: string; mountName: string; rows: SkillRow[] };

  let groups = $state<Group[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);

  // Install/update consent — one instance, re-targeted per action click
  // (same per-row-props pattern the Knowledge dialogs use).
  let consentOpen = $state(false);
  let consentMode = $state<'install' | 'update'>('install');
  let consentRow = $state<SkillRow | null>(null);
  let consentMountKey = $state('');
  let consentMountName = $state('');
  let consentEdited = $state(false);

  // Remove confirm — likewise one re-targeted instance.
  let removeOpen = $state(false);
  let removeRow = $state<SkillRow | null>(null);
  let removeMountKey = $state('');
  let removeMountName = $state('');
  let removing = $state(false);

  const visibleGroups = $derived(groups.filter((g) => g.rows.length > 0));

  function skillsOf(mountKey: string, generation: number): Promise<SkillRow[]> {
    return api.listSkills({ mountKey, generation }).then((result) => {
      if (!result.ok) return [];
      return (result.data as { skills: SkillRow[] }).skills;
    });
  }

  async function load(): Promise<void> {
    loading = true;
    error = null;
    const generation = workspaceStore.generation ?? 0;

    const icmsResult = await api.listIcms(generation);
    if (!icmsResult.ok) {
      error = "Couldn't load your ICMs. Try again in a moment.";
      loading = false;
      return;
    }

    const icms = (icmsResult.data as { icms?: MountSummary[] }).icms ?? [];
    groups = await Promise.all(
      icms.map(async (icm): Promise<Group> => {
        const rows = await skillsOf(icm.mountKey, generation);
        return { mountKey: icm.mountKey, mountName: icm.name, rows };
      })
    );
    loading = false;
  }

  async function reloadMount(mountKey: string): Promise<void> {
    const rows = await skillsOf(mountKey, workspaceStore.generation ?? 0);
    groups = groups.map((g) => (g.mountKey === mountKey ? { ...g, rows } : g));
  }

  onMount(() => {
    void load();
  });

  function openInstall(group: Group, row: SkillRow): void {
    consentMode = 'install';
    consentRow = row;
    consentMountKey = group.mountKey;
    consentMountName = group.mountName;
    consentEdited = false;
    consentOpen = true;
  }

  function openUpdate(group: Group, row: SkillRow): void {
    consentMode = 'update';
    consentRow = row;
    consentMountKey = group.mountKey;
    consentMountName = group.mountName;
    consentEdited = row.state === 'edited';
    consentOpen = true;
  }

  function openRemove(group: Group, row: SkillRow): void {
    removeRow = row;
    removeMountKey = group.mountKey;
    removeMountName = group.mountName;
    removeOpen = true;
  }

  async function confirmRemove(): Promise<void> {
    if (!removeRow) return;
    removing = true;
    const result = await api.uninstallSkill({
      mountKey: removeMountKey,
      skillId: removeRow.skillId,
      generation: workspaceStore.generation ?? 0
    });
    removing = false;
    removeOpen = false;

    if (!result.ok) {
      error = "Couldn't remove the skill. Try again in a moment.";
      return;
    }
    await reloadMount(removeMountKey);
  }
</script>

{#if loading && groups.length === 0}
  <p class="text-ink-meta text-[13px]">Loading…</p>
{:else if visibleGroups.length === 0}
  <p class="text-ink-meta text-[12.5px]">
    Mount an ICM to add skills to it. Skills install into the ICM's own folder.
  </p>
{:else}
  <div class="flex flex-col gap-4">
    {#each visibleGroups as group (group.mountKey)}
      <div class="flex flex-col gap-2">
        <p class="text-overline">{group.mountName}</p>
        {#each group.rows as row (row.skillId)}
          <div class="flex items-start justify-between gap-3">
            <div class="flex flex-col gap-0.5">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-ink-heading text-[13.5px] font-medium">{row.name}</span>
                <span class="text-ink-meta text-[11.5px]">{stateLabel(row)}</span>
              </div>
              {#if row.description}
                <p class="text-ink-meta text-[12px]">{row.description}</p>
              {/if}
            </div>
            <div class="shrink-0">
              {#if actionFor(row) === 'install'}
                <Button type="button" size="sm" onclick={() => openInstall(group, row)}>Install…</Button>
              {:else if actionFor(row) === 'update'}
                <Button type="button" size="sm" variant="outline" onclick={() => openUpdate(group, row)}>
                  Update…
                </Button>
              {:else if actionFor(row) === 'remove'}
                <Button type="button" size="sm" variant="ghost" onclick={() => openRemove(group, row)}>
                  Remove
                </Button>
              {/if}
            </div>
          </div>
        {/each}
      </div>
    {/each}
  </div>
{/if}

{#if error}
  <p role="alert" class="text-warn-ink mt-2 text-[12.5px]">{error}</p>
{/if}

{#if consentRow}
  <SkillConsentDialog
    bind:open={consentOpen}
    mode={consentMode}
    row={consentRow}
    mountKey={consentMountKey}
    mountName={consentMountName}
    edited={consentEdited}
    onDone={() => void reloadMount(consentMountKey)}
  />
{/if}

<Dialog.Root bind:open={removeOpen}>
  <Dialog.Content class="sm:max-w-sm">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">
        Remove {removeRow?.name} from {removeMountName}?
      </Dialog.Title>
      <Dialog.Description class="text-ink-body">You can reinstall it any time.</Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer>
      <Button type="button" variant="ghost" onclick={() => (removeOpen = false)} disabled={removing}>
        Keep
      </Button>
      <Button
        type="button"
        variant="outline"
        class="border-warn-border text-warn-ink hover:bg-warn-tint hover:text-warn-ink"
        onclick={() => void confirmRemove()}
        disabled={removing}
      >
        {removing ? 'Removing…' : 'Remove'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
