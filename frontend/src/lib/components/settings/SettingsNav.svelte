<script lang="ts">
  // The dialog's own nav column. Visual grammar is `SidebarItem`'s (icon,
  // label, active fill on `--paper-nav-active`) but it cannot BE
  // `SidebarItem`: that is an `<a href>` and these select a pane without
  // navigating.
  //
  // `<nav>` + `aria-current`, deliberately not `role="tablist"`. These are
  // panes of a dialog, not tabs over one dataset, and the tablist role
  // promises arrow-key semantics we would then owe an implementation and a
  // test.
  import { SETTINGS_SECTIONS, type SettingsSectionId } from './settings-sections';

  let {
    active,
    dirty = [],
    onSelect
  }: {
    active: SettingsSectionId;
    /** Sections with unsaved edits — marked so a switch never looks like a save. */
    dirty?: SettingsSectionId[];
    onSelect: (id: SettingsSectionId) => void;
  } = $props();
</script>

<nav
  aria-label="Settings sections"
  class="bg-paper-panel border-paper-hairline flex w-44 shrink-0 flex-col gap-0.5 border-r p-2"
>
  {#each SETTINGS_SECTIONS as section (section.id)}
    {@const Icon = section.icon}
    <button
      type="button"
      aria-current={active === section.id ? 'true' : undefined}
      onclick={() => onSelect(section.id)}
      class={[
        'flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left text-[13.5px] transition-colors',
        active === section.id
          ? 'bg-paper-nav-active text-ink-heading font-semibold'
          : 'text-ink-secondary hover:bg-paper-pill'
      ]}
    >
      <Icon class="size-[15px] shrink-0" strokeWidth={1.5} />
      <span class="truncate">{section.label}</span>
      {#if dirty.includes(section.id)}
        <!-- The dot is decoration; the `sr-only` text is what a screen reader
             gets — a bare `title` on an empty span has no accessible name. -->
        <span
          class="bg-suggest-dash ml-auto size-1.5 shrink-0 rounded-full"
          title="Unsaved changes"
          aria-hidden="true"
        ></span>
        <span class="sr-only">, unsaved changes</span>
      {/if}
    </button>
  {/each}
</nav>
