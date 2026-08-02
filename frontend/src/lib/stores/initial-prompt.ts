/**
 * One-shot handoff of a pending FIRST USER TURN — the text the user typed
 * into a new-session composer — from the creation site to the chat route.
 * The composer creates the session, stashes the typed text under the new
 * session id, and navigates; the chat page takes it (exactly once) and hands
 * it to AgentSessionStore, which pushes it as the first user turn on join.
 * Module-level state survives SPA navigation and intentionally does NOT
 * survive a reload — a reloaded session simply has no pending prompt, which
 * is safe.
 *
 * Spec 2026-08-02: nothing composes a prompt here any more. The entry points
 * ("Start a session with this page", "Start a session about this message")
 * used to stash a canned opening turn that the agent answered before the user
 * had said a word; they now open a composer with the source attached and send
 * nothing. What that prompt spelled out about the source is injected into the
 * session's system prompt instead (`SessionSettings.related_line/1` plus the
 * origin premise), so only the user's own words travel through here.
 */
const pending = new Map<string, string>();

export function setInitialPrompt(sessionId: string, text: string): void {
  pending.set(sessionId, text);
}

export function takeInitialPrompt(sessionId: string): string | null {
  const text = pending.get(sessionId) ?? null;
  pending.delete(sessionId);
  return text;
}
