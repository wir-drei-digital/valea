/**
 * The Settings dialog's panes, as data.
 *
 * Adding a setting is an entry here plus a component in `sections/` — the
 * modal does not grow a branch per pane. The registry deliberately holds
 * identity and labels only, not component references: the component lookup
 * lives in `SettingsModal.svelte` where the imports already are, and what
 * is worth asserting on in a test is the ORDER and the ids.
 */
import type { NavIcon } from '$lib/shell/nav';
import Bot from '@lucide/svelte/icons/bot';
import Palette from '@lucide/svelte/icons/palette';

export type SettingsSectionId = 'agent' | 'appearance';

export type SettingsSection = {
  id: SettingsSectionId;
  label: string;
  icon: NavIcon;
};

export const SETTINGS_SECTIONS: readonly SettingsSection[] = [
  { id: 'agent', label: 'Agent', icon: Bot },
  { id: 'appearance', label: 'Appearance', icon: Palette }
];

/** Where the dialog opens. */
export const DEFAULT_SECTION: SettingsSectionId = 'agent';
