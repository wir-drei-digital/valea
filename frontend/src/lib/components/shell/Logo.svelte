<script lang="ts">
  // The Valea mark: a leaf inside a circle, drawn in the accent green
  // (var(--act)) with the leaf cut in the paper surface color so it works
  // on any pane background. Sized by the parent via the `size` class.
  let { size = 'size-8' }: { size?: string } = $props();
</script>

<svg viewBox="0 0 32 32" class={[size, 'shrink-0']} role="img" aria-label="Valea">
  <circle cx="16" cy="16" r="16" fill="var(--act)" />
  <!-- Leaf blade: two arcs meeting at tip (top-right) and base (bottom-left). -->
  <path
    d="M22.4 9.6 C 22.9 16.4 19.4 21.4 12.4 22.6 C 10.4 17.2 13.4 11.2 22.4 9.6 Z"
    fill="var(--paper-card)"
  />
  <!-- Central vein, drawn in the accent so it reads as a cut in the blade. -->
  <path
    d="M21 11 C 17 13.6 14.4 16.8 12.9 21.4"
    fill="none"
    stroke="var(--act)"
    stroke-width="1.1"
    stroke-linecap="round"
  />
</svg>
