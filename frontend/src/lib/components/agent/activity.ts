/**
 * What the agent is doing RIGHT NOW, for the composer's working indicator.
 *
 * "Working…" was true of a two-second edit and of a five-minute research
 * subtask alike, which made it useless exactly when it mattered. This names
 * the work instead.
 *
 * Every running TOOL, uniformly — there is no subtask/normal-tool split
 * here, deliberately. ACP has no subagent concept on the wire: a spawned
 * subtask arrives as an ordinary `tool_call` carrying its own title, and the
 * only way to single those out would be to sniff titles, which breaks the
 * first time the harness rewords one. Listing what is running, named, is
 * both simpler and more useful than guessing at a taxonomy.
 *
 * SECURITY: titles are agent-authored. Consumers use plain interpolation —
 * `{@html}` FORBIDDEN, per the module-wide note in `Transcript.svelte`.
 */
import { asStringOr, type AcpItemLike } from './item-shapes';

export type RunningTool = { id: string; title: string };

/** ACP's non-terminal tool statuses. `completed`/`failed` are the terminal pair. */
const RUNNING = new Set(['pending', 'in_progress']);

export function runningTools(items: AcpItemLike[]): RunningTool[] {
  return items
    .filter((item) => item.type === 'tool' && RUNNING.has(asStringOr(item.status, '')))
    .map((item) => ({
      id: asStringOr(item.id, ''),
      // A title-less tool still gets a row: knowing something is running is
      // the point, and an empty row would read as a rendering bug.
      title: asStringOr(item.title, 'Working…')
    }));
}

/**
 * The indicator's one line. The LAST running tool, not the first: the newest
 * work is what the agent just moved to, and it is what a reader glancing at
 * a moving indicator expects to see.
 */
export function activityLabel(running: RunningTool[]): string {
  return running.length === 0 ? 'Working…' : running[running.length - 1].title;
}
