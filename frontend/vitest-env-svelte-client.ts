/**
 * A vitest environment that is plain Node in every respect EXCEPT that Vite
 * transforms through it as the CLIENT environment.
 *
 * Why this exists: `vite-plugin-svelte` picks `generate: 'client' | 'server'`
 * from the transform's ssr flag, and vitest's default `node` environment is an
 * SSR transform. Under `generate: 'server'` a `.svelte.ts` module's `$state`
 * compiles to a plain value and `$effect` compiles away to NOTHING — so a test
 * about reactivity (an effect that re-arms on its own writes, issue #4) would
 * exercise no effects at all and pass no matter what the code does.
 *
 * A DOM environment (jsdom/happy-dom) would also flip the transform, but it
 * costs a dependency and hands every test a `localStorage`, `document` and
 * friends — the store tests here deliberately assert on their ABSENCE
 * (`tree-state.test.ts`, `recent-pages.test.ts`). This keeps globals exactly as
 * they are and changes only the compile.
 *
 * Opt in per file, not globally, so no existing test's compile mode moves:
 *
 *     // @vitest-environment ./vitest-env-svelte-client.ts
 */
import type { Environment } from 'vitest/environments';

export default <Environment>{
  name: 'svelte-client',
  viteEnvironment: 'client',
  transformMode: 'web',
  setup() {
    return {
      teardown() {
        // Nothing installed, nothing to tear down.
      }
    };
  }
};
