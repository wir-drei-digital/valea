<script lang="ts">
  // Settings: a nav column and a section pane. Was `HarnessSettingsModal`,
  // which was one pane with no nav.
  //
  // Sections mount lazily on first selection and then STAY mounted
  // (`shown`). That is not an optimisation — destroying `AgentSection` on a
  // switch would discard an unsaved harness command, which is the input to
  // a consent decision.
  import type { Component } from 'svelte';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import SettingsNav from './SettingsNav.svelte';
  import AgentSection from './sections/AgentSection.svelte';
  import AppearanceSection from './sections/AppearanceSection.svelte';
  import { SETTINGS_SECTIONS, DEFAULT_SECTION, type SettingsSectionId } from './settings-sections';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  /**
   * What a section may expose to the shell. Optional because most sections
   * have nothing to say — only a pane holding unsaved input the user could
   * lose needs to answer for it.
   */
  type SectionInstance = { isDirty?: () => boolean };
  type SectionComponent = Component<Record<string, never>, SectionInstance>;

  // The id→component lookup, keyed by the registry's own union rather than
  // written out as an `{#if}` chain: adding a section to
  // `settings-sections.ts` without a component here is then a COMPILE error
  // instead of a blank pane.
  const SECTION_COMPONENTS: Record<SettingsSectionId, SectionComponent> = {
    agent: AgentSection,
    appearance: AppearanceSection
  };

  let active = $state<SettingsSectionId>(DEFAULT_SECTION);
  let shown = $state<Set<SettingsSectionId>>(new Set([DEFAULT_SECTION]));
  let instances = $state<Partial<Record<SettingsSectionId, SectionInstance | null>>>({});

  $effect(() => {
    if (open) {
      active = DEFAULT_SECTION;
      shown = new Set([DEFAULT_SECTION]);
    }
  });

  function select(id: SettingsSectionId): void {
    active = id;
    if (!shown.has(id)) shown = new Set([...shown, id]);
  }

  const dirtySections = $derived(
    SETTINGS_SECTIONS.filter((section) => instances[section.id]?.isDirty?.() === true).map(
      (section) => section.id
    )
  );
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="flex h-[min(600px,85vh)] gap-0 overflow-hidden p-0 sm:max-w-3xl">
    <Dialog.Title class="sr-only">Settings</Dialog.Title>
    <Dialog.Description class="sr-only">
      Configure how Valea runs your agent and how the app looks.
    </Dialog.Description>

    <SettingsNav {active} dirty={dirtySections} onSelect={select} />

    <div class="min-w-0 flex-1 overflow-y-auto p-5">
      {#each SETTINGS_SECTIONS as section (section.id)}
        {@const Section = SECTION_COMPONENTS[section.id]}
        <div hidden={active !== section.id}>
          {#if shown.has(section.id)}
            <Section bind:this={instances[section.id]} />
          {/if}
        </div>
      {/each}
    </div>
  </Dialog.Content>
</Dialog.Root>
