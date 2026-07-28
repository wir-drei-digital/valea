<script lang="ts">
  // Side-panes pass: an image file leaf opened as a view — the bytes come
  // straight from `/files/raw` (same endpoint the editor's inline images
  // already use), so there is nothing to fetch or decode here ourselves.
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();
</script>

<img
  src={rawFileUrl(mountKey, path)}
  alt={path.split('/').pop()}
  class="border-paper-hairline max-w-full rounded-md border"
/>
