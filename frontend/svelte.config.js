import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		// SPA mode: every unknown path falls back to index.html (Tauri + Phoenix
		// catch-all both rely on this).
		adapter: adapter({ fallback: 'index.html' })
	}
};

export default config;
