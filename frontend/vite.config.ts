import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';

// Env-overridable so a second dev stack (worktree preview, UI verification
// rig) can run beside `just dev-desktop` without fighting over 4273/4200.
const port = Number(process.env.VALEA_FRONTEND_PORT ?? 4273);
const backend = process.env.VALEA_BACKEND_ORIGIN ?? 'http://localhost:4200';

export default defineConfig({
  plugins: [tailwindcss(), sveltekit()],
  server: {
    port,
    strictPort: true,
    proxy: {
      '/api': backend,
      '/rpc': backend,
      // Only the backend's file ENDPOINTS, one by one — a bare `/files`
      // prefix would shadow the SPA's /files route on full-page loads
      // (Phoenix answers with its baked index.html and stale hashed assets →
      // blank page). A new one here needs a line here too.
      '/files/upload': backend,
      '/files/raw': backend,
      '/files/ticket': backend,
      '/calendar/feed.ics': backend,
      '/socket': { target: backend.replace(/^http/, 'ws'), ws: true }
    }
  },
  // Two suites, split by what they need from the compiler.
  //
  // `unit` is every plain `*.test.ts` — pure logic, node environment, exactly
  // what this project has always run.
  //
  // `runes` is `*.test.svelte.ts`, for tests that use `$state`/`$effect`
  // THEMSELVES to pin reactivity behaviour (issue #4: an effect that re-armed
  // on its own writes). Two things have to be true for such a test to mean
  // anything, and both are silent failures rather than errors when missing:
  // the file needs the `.svelte.ts` suffix, or the Svelte plugin never
  // rune-compiles it (`$effect is not defined`); and it needs a CLIENT
  // transform, or `$effect` compiles to nothing at all and the test passes
  // vacuously. `vitest-env-svelte-client.ts` buys the second one without a
  // jsdom dependency.
  // Under vitest ONLY: resolve `svelte` to its client build. Plain node
  // resolution picks the SERVER runtime, whose `flushSync` flushes nothing.
  // Guarded by `VITEST` so dev and build resolution are untouched.
  resolve: process.env.VITEST ? { conditions: ['browser'] } : undefined,
  test: {
    projects: [
      { extends: true, test: { name: 'unit', include: ['src/**/*.test.ts'] } },
      {
        extends: true,
        test: {
          name: 'runes',
          include: ['src/**/*.test.svelte.ts'],
          environment: './vitest-env-svelte-client.ts'
        }
      }
    ]
  }
});
