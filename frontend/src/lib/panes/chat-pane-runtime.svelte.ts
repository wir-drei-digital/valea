/**
 * Per-Chat-pane runtime state. Same host-owned arrangement as
 * `files-pane-runtime.svelte.ts`: the header's sessions toggle and the pane
 * body both read this one object, and neither parents the other.
 */
import { loadChrome, saveChrome } from './pane-memory';
import type { PaneDescriptor } from './pane-route';

export class ChatPaneState {
  kind = 'chat' as const;
  sessionsVisible = $state(loadChrome().chat.sessions);

  toggleSessions(): void {
    this.sessionsVisible = !this.sessionsVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, chat: { sessions: this.sessionsVisible } });
  }
}

export function createChatPaneState(_descriptor: PaneDescriptor): ChatPaneState {
  return new ChatPaneState();
}
