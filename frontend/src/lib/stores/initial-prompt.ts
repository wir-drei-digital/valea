/**
 * One-shot handoff of a composed opening prompt from a session entry point
 * ("Start a session with this page", "Start a session about this message")
 * to the chat route. The entry point creates the session, stashes the
 * prompt under the new session id, and navigates; the chat page takes it
 * (exactly once) and hands it to AgentSessionStore, which pushes it as the
 * first user turn on join. Module-level state survives SPA navigation and
 * intentionally does NOT survive a reload — a reloaded session simply has
 * no pending prompt, which is safe.
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

export function pageSessionPrompt(relativePath: string): string {
  return [
    `Read \`${relativePath}\` and follow it.`,
    `If it describes a procedure or workflow, execute it step by step. I'll approve any file changes through the permission gate as you go.`,
    `If it's reference material, give me a short summary and wait for my direction.`
  ].join(' ');
}

/**
 * Same handoff for a NON-.md file leaf (a PDF, an image, a CSV, a
 * LICENSE) — reachable from the tree's row menu since Task 10. Deliberately
 * not `pageSessionPrompt`'s wording: "follow it" presumes a document
 * written as instructions, which a scanned invoice or a logo is not, so
 * this one opens by asking what the file contains and only then offers the
 * execute-it branch. The grant side is identical (`context_doc` validates
 * any regular file inside the ICM and the read root is the mount, not
 * `*.md`), so nothing but the words changes.
 */
export function fileSessionPrompt(relativePath: string): string {
  return [
    `Read \`${relativePath}\` and tell me what's in it.`,
    `If it describes a procedure or workflow, execute it step by step. I'll approve any file changes through the permission gate as you go.`,
    `Otherwise, give me a short summary and wait for my direction.`
  ].join(' ');
}
