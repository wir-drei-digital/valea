<script lang="ts">
  // §5 "Status pill — one per screen, bottom of sidebar. Names the transport or 'All local'."
  let { label }: { label: string } = $props();
</script>

<div class="inline-flex items-center gap-1.5 rounded-full bg-paper-pill px-2.5 py-1">
  <span class="size-1.5 rounded-full bg-act-dot"></span>
  <span class="text-[11.5px] text-ink-secondary">{label}</span>
</div>
