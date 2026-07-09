<script lang="ts">
  import type { NavIcon } from '$lib/shell/nav';

  let {
    label,
    href,
    icon: Icon,
    active = false,
    currentPage = false
  }: {
    label: string;
    href: string;
    icon: NavIcon;
    active?: boolean;
    currentPage?: boolean;
  } = $props();
</script>

<a
  {href}
  aria-current={currentPage ? 'page' : undefined}
  class={[
    'flex items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-[13.5px] transition-colors',
    active
      ? 'bg-paper-nav-active font-semibold text-ink-heading'
      : 'text-ink-secondary hover:bg-paper-pill'
  ]}
>
  <Icon class="size-[15px] shrink-0" strokeWidth={1.5} />
  <span class="truncate">{label}</span>
</a>
