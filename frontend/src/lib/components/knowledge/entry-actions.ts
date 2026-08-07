/**
 * What a tree row offers, as data.
 *
 * There are two menus on every row — the `⋯` overflow and the right-click
 * context menu — and they must never drift apart, so neither of them owns a
 * list. This does, and both render whatever it returns. That also puts the
 * gating rules under a unit test instead of under two component templates
 * nobody diffs against each other.
 *
 * Separators are emitted as list members rather than left to the renderer,
 * because whether a group boundary EXISTS depends on whether the group has
 * any surviving members — a folder has no leaf actions, a browser has no
 * reveal — and only the thing that dropped them knows that.
 */
import { startSessionLabel, type EntryKind } from './entry-kind';

export type EntryActionId =
  | 'open-in-tab'
  | 'start-session'
  | 'reveal'
  | 'copy-path'
  | 'copy-name'
  | 'new-page'
  | 'new-folder'
  | 'rename'
  | 'delete';

export type EntryAction =
  | { kind: 'separator' }
  | {
      kind: 'action';
      id: EntryActionId;
      label: string;
      destructive?: true;
      /**
       * Why this action cannot act, or absent when it can. A disabled item
       * still RENDERS, carrying this as its tooltip: a disabled control with
       * a reason teaches, a missing one leaves the user hunting. Same rule
       * `IcmTree`'s "Open in a new tab" button already follows.
       */
      disabledReason?: string;
    };

export function entryActions(input: {
  kind: EntryKind;
  canReveal: boolean;
  revealLabel: string;
  canOpenInTab: boolean;
  openInTabDisabled?: string | null;
}): EntryAction[] {
  const leaf = input.kind !== 'folder';

  const groups: EntryAction[][] = [
    // Opening it.
    [
      ...(leaf && input.canOpenInTab
        ? [
            {
              kind: 'action' as const,
              id: 'open-in-tab' as const,
              label: 'Open in a new tab',
              ...(input.openInTabDisabled ? { disabledReason: input.openInTabDisabled } : {})
            }
          ]
        : []),
      ...(leaf
        ? [
            {
              kind: 'action' as const,
              id: 'start-session' as const,
              label: startSessionLabel(input.kind)
            }
          ]
        : [])
    ],
    // Finding it elsewhere.
    [
      ...(input.canReveal
        ? [{ kind: 'action' as const, id: 'reveal' as const, label: input.revealLabel }]
        : []),
      { kind: 'action', id: 'copy-path', label: 'Copy path' },
      { kind: 'action', id: 'copy-name', label: 'Copy name' }
    ],
    // Making a neighbour.
    [
      { kind: 'action', id: 'new-page', label: 'New page here' },
      { kind: 'action', id: 'new-folder', label: 'New folder here' }
    ],
    // Changing it.
    [
      { kind: 'action', id: 'rename', label: 'Rename' },
      { kind: 'action', id: 'delete', label: 'Delete…', destructive: true }
    ]
  ];

  // Empty groups take their separator with them, which is what keeps a
  // folder's menu from opening on a rule.
  return groups
    .filter((group) => group.length > 0)
    .flatMap((group, i) => (i === 0 ? group : [{ kind: 'separator' as const }, ...group]));
}
