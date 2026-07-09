<script lang="ts">
  import { Button } from '$lib/components/ui/button/index.js';
  import { Badge } from '$lib/components/ui/badge/index.js';
</script>

<div class="mx-auto flex max-w-2xl flex-col gap-6 p-10">
  <p class="text-overline">Wednesday, July 9</p>

  <h1 class="font-display text-[32px] text-ink-heading">Good morning, Mara.</h1>

  <p class="text-ink-body">
    Three drafts are ready for review, and your calendar has one open hold
    waiting on a reply. Everything else is caught up.
  </p>

  <p class="font-mono text-ink-meta text-[11px]">icm/clients/mara/notes.md</p>

  <div class="flex flex-wrap gap-3">
    <Button variant="default">Approve — put in my Gmail drafts</Button>
    <Button variant="outline">Snooze</Button>
    <Button variant="destructive">Read, then send…</Button>
  </div>

  <div class="flex flex-wrap gap-2">
    <Badge class="bg-act-tint text-act border-transparent">Reply drafted</Badge>
    <Badge class="bg-suggest-tint text-suggest-ink border-transparent">Update suggested</Badge>
    <Badge class="bg-warn-tint text-warn-ink border-transparent">Sends an email</Badge>
  </div>
</div>
