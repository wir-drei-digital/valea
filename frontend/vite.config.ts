import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [tailwindcss(), sveltekit()],
  server: {
    port: 4273,
    strictPort: true,
    proxy: {
      '/api': 'http://localhost:4200',
      '/rpc': 'http://localhost:4200',
      // Only the backend's two file ENDPOINTS — a bare `/files` prefix would
      // shadow the SPA's /files route on full-page loads (Phoenix answers
      // with its baked index.html and stale hashed assets → blank page).
      '/files/upload': 'http://localhost:4200',
      '/files/raw': 'http://localhost:4200',
      '/calendar/feed.ics': 'http://localhost:4200',
      '/socket': { target: 'ws://localhost:4200', ws: true }
    }
  },
  test: { include: ['src/**/*.test.ts'] }
});
