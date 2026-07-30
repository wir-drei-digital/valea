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
  test: { include: ['src/**/*.test.ts'] }
});
