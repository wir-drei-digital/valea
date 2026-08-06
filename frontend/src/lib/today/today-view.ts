/**
 * View helpers shared by the Today page's pieces. Relocated out of
 * `routes/+page.svelte` when the attention and briefing cards became
 * components (Today/Tasks redesign): the same stamp is formatted by the route
 * and by both cards, and a third copy is how two of them drift apart.
 */

/**
 * "Aug 6, 09:30" — the one timestamp shape Today uses, in the viewer's own
 * locale and zone. A string that is not a date is returned UNCHANGED rather
 * than rendered as "Invalid Date": these stamps come out of user-owned files
 * (`today.json`) and a mangled one should show what it actually says.
 */
export function formatTimestamp(iso: string): string {
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return iso;
  return parsed.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  });
}
