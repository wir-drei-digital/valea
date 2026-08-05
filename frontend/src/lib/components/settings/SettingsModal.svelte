<script lang="ts">
  // Settings: a nav column and a section pane. Was `HarnessSettingsModal`,
  // which was one pane with no nav.
  //
  // Sections mount lazily on first selection and then STAY mounted
  // (`shown`). That is not an optimisation — destroying `AgentSection` on a
  // switch would discard an unsaved harness command, which is the input to
  // a consent decision.
  import { tick, type Component } from 'svelte';
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
  let panes = $state<Partial<Record<SettingsSectionId, HTMLElement | null>>>({});

  // `$effect.pre`, NOT `$effect`. Every open starts on the default section, and
  // the reset has to land BEFORE the content subtree renders with it. A plain
  // user `$effect` runs AFTER that render, so a reopen would first render the
  // previous `active`/`shown` — mounting a section, then destroying it one
  // frame later when this reset shrinks `shown`. Harmless while the panes were
  // static, not harmless now that a pane can hold state or a mount-time effect.
  // Pre-effects flush in tree order ahead of the render effects below them, so
  // the subtree is created from the settled values.
  //
  // Resetting on close (`if (!open)`) would fix the ordering too, but the dialog
  // animates out over ~100ms and stays mounted for it, so the user would watch
  // the pane rewind to Agent as it faded.
  $effect.pre(() => {
    if (open) {
      active = DEFAULT_SECTION;
      shown = new Set([DEFAULT_SECTION]);
    }
  });

  // Spec (Accessibility): "Focus moves to the section heading on switch so a
  // screen reader announces the new pane." Only on a user-initiated SWITCH —
  // the open-time reset above assigns `active` directly and never comes
  // through here, so initial focus stays with the dialog's own management.
  // `tick()` first: a first selection mounts the pane, and the `<h2>` (each
  // section's pane title, made focusable with tabindex="-1") does not exist
  // to focus until the DOM has caught up.
  async function select(id: SettingsSectionId): Promise<void> {
    if (id === active) return;
    active = id;
    if (!shown.has(id)) shown = new Set([...shown, id]);
    await tick();
    panes[id]?.querySelector<HTMLElement>('h2')?.focus();
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

    <!-- `pr-10`, not `pr-5`: Dialog.Content's close button is absolutely
         positioned (top-2 right-2, size-7), so scrolled content would pass
         UNDER its transparent ghost footprint and clicks there would close
         the dialog. The wider gutter keeps content out of that band. -->
    <div class="min-w-0 flex-1 overflow-y-auto p-5 pr-10">
      {#each SETTINGS_SECTIONS as section (section.id)}
        {@const Section = SECTION_COMPONENTS[section.id]}
        <div hidden={active !== section.id} bind:this={panes[section.id]}>
          {#if shown.has(section.id)}
            <Section bind:this={instances[section.id]} />
          {/if}
        </div>
      {/each}
    </div>
  </Dialog.Content>
</Dialog.Root>
