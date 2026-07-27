// Pure row-state helpers shared by SkillsPanel, SkillConsentDialog, and
// the sidebar offer card. States mirror `Valea.Skills.state/2`'s
// vocabulary (ICM skills design spec, §On-disk contract).

export type SkillRow = {
  skillId: string;
  name: string;
  description: string | null;
  sourceUrl: string | null;
  license: string | null;
  pinned: string | null;
  state: 'not_installed' | 'foreign' | 'edited' | 'update_available' | 'installed';
  installedVersion: string | null;
};

export type SkillAction = 'install' | 'update' | 'remove' | null;

export function actionFor(row: SkillRow): SkillAction {
  switch (row.state) {
    case 'not_installed':
      return 'install';
    case 'update_available':
    case 'edited':
      return 'update';
    case 'installed':
      return 'remove';
    case 'foreign':
      return null;
  }
}

export function stateLabel(row: SkillRow): string {
  switch (row.state) {
    case 'not_installed':
      return 'Not installed';
    case 'installed':
      return 'Installed';
    case 'update_available':
      return 'Update available';
    case 'edited':
      return 'Edited by you';
    case 'foreign':
      return 'Installed by hand';
  }
}
