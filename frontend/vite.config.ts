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
      '/files': 'http://localhost:4200',
      '/socket': { target: 'ws://localhost:4200', ws: true }
    }
  },
  test: { include: ['src/**/*.test.ts'] }
});
