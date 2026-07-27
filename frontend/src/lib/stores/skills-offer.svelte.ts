// One-time skill offer per ICM, shown at the mount/create/adopt moment
// (ICM skills design spec, §Frontend/Offer card). Session-local by
// design: the card appears only right after a mount event in THIS app
// session; the durable suppression is the backend dismissed list plus
// the install itself. Never blocks, never nags.

import { api } from '$lib/api/client';
import { workspaceStore } from './workspace.svelte';
import type { SkillRow } from '$lib/components/agent/skills-rows';

export type SkillOffer = { mountKey: string; row: SkillRow };

export function eligibleOffer(rows: SkillRow[], dismissed: string[]): SkillRow | null {
  return rows.find((r) => r.state === 'not_installed' && !dismissed.includes(r.skillId)) ?? null;
}

class SkillsOfferStore {
  private offers = $state<Record<string, SkillOffer>>({});

  async offerFor(mountKey: string): Promise<void> {
    // Generation is caller-sourced everywhere in this codebase, but the
    // mount/create/adopt success sites that call this don't thread one, so
    // read it live off the open workspace (same fallback `MountsStore.refresh`
    // uses). The wrapper requires it — Task 9's `listSkills` takes the
    // generated `{mountKey, generation}` input verbatim.
    const result = await api.listSkills({ mountKey, generation: workspaceStore.generation ?? 0 });
    if (!result.ok) return; // a failed load never surfaces a card
    const data = result.data as { skills: SkillRow[]; dismissed: string[] };
    const row = eligibleOffer(data.skills, data.dismissed);
    if (row) this.offers = { ...this.offers, [mountKey]: { mountKey, row } };
  }

  offerUnder(mountKey: string): SkillOffer | null {
    return this.offers[mountKey] ?? null;
  }

  async dismiss(offer: SkillOffer): Promise<void> {
    this.retire(offer.mountKey);
    await api.dismissSkillsOffer({
      mountKey: offer.mountKey,
      skillId: offer.row.skillId,
      generation: workspaceStore.generation ?? 0
    });
  }

  retire(mountKey: string): void {
    const { [mountKey]: _gone, ...rest } = this.offers;
    this.offers = rest;
  }
}

export const skillsOfferStore = new SkillsOfferStore();
