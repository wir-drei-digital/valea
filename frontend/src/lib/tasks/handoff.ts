/**
 * Hand-a-task-to-the-assistant (spec §Hand to assistant). The prompt is the
 * contract: it anchors the session on the task's ledger entry so the agent
 * updates the SAME entry (`.valea/briefing.md` already teaches the ledger
 * rules); the UI flips status/assignee and records the session id itself,
 * so a crashed session never leaves an untraceable in_progress task.
 */
import type { TaskEntry } from './filters';

export function handoffPrompt(task: TaskEntry, mountKey: string): string {
  const lines = [
    `Please work on this task from ${mountKey}'s tasks.json ledger (entry id: ${task.id}).`,
    '',
    `Task: ${task.title ?? '(untitled)'}`
  ];
  if (task.notes !== null) lines.push(`Notes: ${task.notes}`);
  if (task.due !== null) lines.push(`Due: ${task.due}`);
  if (task.priority !== null) lines.push(`Priority: ${task.priority}`);
  if (task.source !== null) lines.push(`Source: ${task.source}`);
  lines.push(
    '',
    'When you finish, update this entry in tasks.json: set its status (done when complete), and add a short note of what you did. If you get blocked, set status back to open and record why in the notes.'
  );
  return lines.join('\n');
}

/** Live state of a session id from the recent-sessions groups — null when the id is beyond the recency window (chip renders without a dot). */
export function sessionLiveById(
  groups: { sessions: { id: string; live: boolean }[] }[],
  sessionId: string
): boolean | null {
  for (const group of groups) {
    const found = group.sessions.find((session) => session.id === sessionId);
    if (found) return found.live;
  }
  return null;
}
