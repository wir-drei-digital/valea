<script lang="ts">
  // The Valea mark: a two-leaf sprig inside a circle, drawn in the accent
  // green (var(--act)) with the sprig cut in the paper surface color so it
  // works on any pane background. Sized by the parent via the `size` class.
  let { size = 'size-8' }: { size?: string } = $props();
</script>

<svg viewBox="0 0 32 32" class={[size, 'shrink-0']} role="img" aria-label="Valea">
  <circle cx="16" cy="16" r="16" fill="var(--act)" />
  <!-- Stem: rises from the base, leaning gently right. -->
  <path
    d="M15.4 25.5 C 15.6 20.5, 16.4 14.5, 19 9"
    fill="none"
    stroke="var(--paper-card)"
    stroke-width="1.7"
    stroke-linecap="round"
  />
  <!-- Lower leaf, branching up-left off the stem. -->
  <path
    d="M15.9 18.9 C 12 18.7, 9.5 16.2, 8.9 12.1 C 13 12.3, 15.7 15, 15.9 18.9 Z"
    fill="var(--paper-card)"
  />
  <!-- Upper leaf, branching up-right toward the stem tip. -->
  <path
    d="M17.4 13.3 C 21.2 13.4, 23.7 11, 24.2 7 C 20.2 7.1, 17.6 9.6, 17.4 13.3 Z"
    fill="var(--paper-card)"
  />
</svg>
