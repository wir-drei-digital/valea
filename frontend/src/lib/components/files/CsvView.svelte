<script lang="ts">
  // `.csv` gets a table instead of a wall of commas: first record as the
  // header, every row padded to the widest record so the grid can't go
  // ragged. Parsing is guesswork on a format that has no schema — a stray
  // quote, a semicolon export, a file that isn't really tabular — so the
  // Raw toggle is not a nicety here, it is the escape hatch that makes the
  // guess safe to make. It shows exactly what `PlainTextView` would.
  //
  // SECURITY: cells are file content — plain interpolation only ({value}),
  // {@html} is FORBIDDEN (same rule as every content view).
  //
  // Fetch shape (token header, wire-level 500 KB cap, real abort on
  // re-point) is `PlainTextView`'s, shared through `capped-text.ts`.
  import { SegmentedControl } from '$lib/components/shell';
  import { rawFileHeaders, rawFileUrl } from './raw-url';
  import { cappedResponseText } from './capped-text';
  import { csvGrid, wrapColumns } from './csv';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  /**
   * Rows RENDERED, not rows parsed. 500 KB of CSV can be tens of thousands
   * of records, and a cell is a DOM node each — past a point the table stops
   * being readable long before it stops being expensive.
   */
  const ROW_CAP = 1000;

  let text = $state<string | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);
  let view = $state<'table' | 'raw'>('table');

  const grid = $derived.by(() => {
    if (text === null) return null;
    const parsed = csvGrid(text);
    // The byte cap can cut mid-record, so the last one is only a fragment of
    // a row — dropping it beats rendering a half-truthy line of data.
    if (truncated && parsed.rows.length > 0) parsed.rows.pop();
    return parsed;
  });

  const shownRows = $derived(grid ? grid.rows.slice(0, ROW_CAP) : []);
  const wrappable = $derived(grid ? wrapColumns(grid) : []);
  const overCap = $derived(grid ? grid.rows.length - shownRows.length : 0);

  const note = $derived.by(() => {
    const parts: string[] = [];
    if (truncated) parts.push('the first 500 KB');
    if (overCap > 0) parts.push(`the first ${ROW_CAP.toLocaleString()} rows`);
    return parts.length ? `Showing ${parts.join(' and ')}.` : null;
  });

  $effect(() => {
    // Captured before the await so a response for a file the reader has
    // since navigated away from is dropped rather than shown.
    const target = { mountKey, path };
    const controller = new AbortController();
    let cancelled = false;
    text = null;
    error = null;
    truncated = false;
    void (async () => {
      try {
        const res = await fetch(rawFileUrl(target.mountKey, target.path), {
          headers: rawFileHeaders(),
          signal: controller.signal
        });
        if (!res.ok) throw new Error(String(res.status));
        const result = await cappedResponseText(res);
        if (cancelled) return;
        truncated = result.truncated;
        text = result.text;
      } catch {
        if (!cancelled) error = "This file can't be displayed.";
      }
    })();
    return () => {
      cancelled = true;
      controller.abort();
    };
  });
</script>

{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else if grid === null}
  <p class="text-ink-meta text-[13px]">Loading…</p>
{:else}
  <div class="flex flex-col gap-2">
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <p class="text-ink-meta min-w-0 flex-1 text-[11.5px]">
        {grid.rows.length.toLocaleString()}
        {grid.rows.length === 1 ? 'row' : 'rows'} · {grid.columns}
        {grid.columns === 1 ? 'column' : 'columns'}{note ? ` · ${note}` : ''}
      </p>
      <!-- The same segmented grammar (and component) the knowledge page's
           Friendly/Raw toggle uses; it stays put in both modes, because it
           is how the reader gets back. -->
      <div class="shrink-0">
        <SegmentedControl
          label="CSV display"
          value={view}
          options={[
            { value: 'table', label: 'Table' },
            { value: 'raw', label: 'Raw' }
          ]}
          onChange={(v) => (view = v as 'table' | 'raw')}
        />
      </div>
    </div>

    {#if view === 'raw'}
      <pre
        class="text-ink-body font-mono text-[12px] leading-relaxed break-words whitespace-pre-wrap">{text}</pre>
    {:else if grid.columns === 0}
      <p class="text-ink-meta text-[13px]">This file is empty.</p>
    {:else}
      <!-- Wide files scroll HERE, inside the card, so the pane itself never
           scrolls sideways. -->
      <div class="border-paper-hairline overflow-x-auto rounded-lg border">
        <!-- `min-w-full`, not `w-full`: the table fills the pane, but a column
             is never squeezed BELOW its content to make room for a long one —
             which is what turned dates into "2026-01-" / "14". The cell cap
             below is the other half of that: only genuinely long cells wrap. -->
        <table class="min-w-full border-collapse text-[12.5px]">
          <thead>
            <tr>
              {#each grid.header as cell, j (j)}
                <th
                  class={[
                    'border-paper-hairline bg-paper-panel text-ink-heading border-b px-2.5 py-1.5 text-left font-medium',
                    wrappable[j] ? 'max-w-[26rem] break-words' : 'whitespace-nowrap'
                  ]}
                >
                  {cell}
                </th>
              {/each}
            </tr>
          </thead>
          <tbody>
            {#each shownRows as row, i (i)}
              <tr>
                {#each row as cell, j (j)}
                  <!-- `pre-wrap`: a cell's own spacing is data too. -->
                  <td
                    class={[
                      'border-paper-hairline text-ink-body border-b px-2.5 py-1.5 align-top',
                      wrappable[j] ? 'max-w-[26rem] break-words whitespace-pre-wrap' : 'whitespace-pre'
                    ]}>{cell}</td
                  >
                {/each}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
      {#if grid.rows.length === 0}
        <p class="text-ink-meta text-[12px]">No data rows — this file is just a header.</p>
      {/if}
    {/if}
  </div>
{/if}
