<script lang="ts">
  // The one-time skill offer under an ICM's sidebar group (ICM skills design
  // spec §Frontend/Offer card). A quiet suggestion — hairline border, no
  // accent fill, an amber "Suggested" overline (amber is the suggestion ink,
  // never a call-to-action fill). It appears only right after this ICM was
  // mounted/created/adopted in THIS session; "Not now" dismisses it durably
  // (backend list), Install… hands off to the same consent dialog the
  // settings panel uses. Never blocks, never nags.
  import { Button } from '$lib/components/ui/button/index.js';
  import SkillConsentDialog from '$lib/components/agent/SkillConsentDialog.svelte';
  import { skillsOfferStore, type SkillOffer } from '$lib/stores/skills-offer.svelte';

  let { offer, mountName }: { offer: SkillOffer; mountName: string } = $props();

  let consentOpen = $state(false);
</script>

<div class="border-paper-hairline ml-[17px] mt-1 flex flex-col gap-1.5 rounded-lg border p-2.5">
  <span class="text-suggest-ink text-[11px] font-bold tracking-[0.09em] uppercase">Suggested</span>
  <p class="text-ink-body text-[12px]">
    Your assistant can learn the ICM methodology — install the {offer.row.name} skill into this folder?
  </p>
  <div class="flex gap-2">
    <Button type="button" size="sm" onclick={() => (consentOpen = true)}>Install…</Button>
    <Button type="button" size="sm" variant="ghost" onclick={() => void skillsOfferStore.dismiss(offer)}>
      Not now
    </Button>
  </div>
</div>

<SkillConsentDialog
  bind:open={consentOpen}
  mode="install"
  row={offer.row}
  mountKey={offer.mountKey}
  {mountName}
  edited={false}
  onDone={() => skillsOfferStore.retire(offer.mountKey)}
/>
