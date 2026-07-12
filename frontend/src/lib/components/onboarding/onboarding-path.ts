// Pure branch-decision logic for the open/create dialog's ICM-aware
// onboarding: given an `inspect_path` RPC result (see
// `Valea.Workspace.Adopt.classify_path/1` on the backend) and the raw path
// the user picked, decides which of the three UI modes `OpenWorkspaceFlow`
// should show. Kept pure and separate from the component so the branch
// decision — the part most worth getting exactly right — is testable
// without mounting Svelte.
import type { PathInspection } from '$lib/api/client';

export type OnboardingMode =
  | { mode: 'open' }
  | { mode: 'adopt'; originalPath: string; suggestedName: string; description: string | null }
  | { mode: 'unsupported' };

/**
 * `kind: "workspace"` -> the existing "inspect then open" path.
 * `kind: "other"` -> the existing "doesn't look like a Valea workspace"
 * error — unchanged from before this task.
 * `kind: "icm"` -> the new adopt-by-move consent step. `originalPath` is
 * the EXACT path the user picked (not re-derived or normalized) — the
 * consent step shows this verbatim so the user can verify what's about to
 * move. `suggestedName` prefills the new workspace's name field: the
 * manifest's own `name` when it's a real (non-blank) string, otherwise the
 * source folder's own basename.
 */
export function decideOnboardingMode(inspection: PathInspection, path: string): OnboardingMode {
  switch (inspection.kind) {
    case 'workspace':
      return { mode: 'open' };

    case 'other':
      return { mode: 'unsupported' };

    case 'icm': {
      const trimmedName = inspection.name?.trim();
      return {
        mode: 'adopt',
        originalPath: path,
        suggestedName: trimmedName ? trimmedName : basename(path),
        description: inspection.description
      };
    }
  }
}

/** Last path segment, ignoring a trailing slash. POSIX paths only (macOS/Linux). */
export function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx === -1 ? trimmed : trimmed.slice(idx + 1);
}

/**
 * Parent directory, ignoring a trailing slash — used to prefill the adopt
 * dialog's default parent folder (the source's own parent, since the new
 * workspace can't be scaffolded AT the source path itself). Returns "/"
 * for a top-level path or the root path itself.
 */
export function dirname(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx <= 0 ? '/' : trimmed.slice(0, idx);
}
