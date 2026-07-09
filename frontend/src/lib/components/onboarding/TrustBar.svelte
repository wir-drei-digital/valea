<script lang="ts">
  // §DESIGN_SYSTEM.md §7/§10 — trust bar footer: three items with small icons
  // (green act-dot / lock / folder), plus the mono "open the hood" style link
  // on the far right that opens the workspace explainer.
  import Lock from '@lucide/svelte/icons/lock';
  import Folder from '@lucide/svelte/icons/folder';

  let { onExplain }: { onExplain: () => void } = $props();
</script>

<div
  class="flex flex-col gap-4 border-t border-paper-hairline pt-5 text-[12.5px] text-ink-secondary sm:flex-row sm:items-center sm:justify-between"
>
  <ul class="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:gap-6">
    <li class="flex items-center gap-2">
      <span class="size-1.5 shrink-0 rounded-full bg-act-dot"></span>
      Runs on this Mac — nothing leaves it during setup
    </li>
    <li class="flex items-center gap-2">
      <Lock class="size-3.5 shrink-0 text-ink-meta" strokeWidth={1.5} />
      Your keys stay in the system keychain
    </li>
    <li class="flex items-center gap-2">
      <Folder class="size-3.5 shrink-0 text-ink-meta" strokeWidth={1.5} />
      Export or walk away with the folder anytime
    </li>
  </ul>

  <button
    type="button"
    onclick={onExplain}
    class="self-start font-mono text-[11.5px] text-ink-meta transition-colors hover:text-ink-secondary sm:self-auto"
  >
    &gt;_ What's in a workspace?
  </button>
</div>
