/**
 * Which colour an account's avatar wears. Keyed on the account slug so one
 * account looks the same everywhere (`accountColorIndex`).
 *
 * These are dedicated `--avatar-fill-*` tokens rather than borrowed
 * consequence colours. `contrast.test.ts` pins the invariant this palette
 * exists to keep: every fill carries `--primary-foreground` at >= 4.5:1, in
 * every theme. Adding a fifth colour means adding a fifth token and letting
 * that test tell you whether it is dark enough.
 */
import { accountColorIndex } from './mail-shapes';

export const AVATAR_FILLS = [
  'bg-avatar-fill-1',
  'bg-avatar-fill-2',
  'bg-avatar-fill-3',
  'bg-avatar-fill-4'
] as const;

export function avatarFillFor(slug: string): string {
  return AVATAR_FILLS[accountColorIndex(slug, AVATAR_FILLS.length)];
}
