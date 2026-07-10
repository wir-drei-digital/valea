import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		// SPA mode: every unknown path falls back to index.html (Tauri + Phoenix
		// catch-all both rely on this).
		adapter: adapter({ fallback: 'index.html' }),
		// Emit a <meta http-equiv="content-security-policy"> whose script-src
		// carries a per-build sha256 hash covering SvelteKit's own inline
		// hydration bootstrap. The served-response header (spa_controller.ex)
		// cannot express this per-build hash, so it stays permissive
		// ('unsafe-inline') and the browser enforces the INTERSECTION — the
		// effective script policy is still hash-gated by this meta tag.
		csp: {
			mode: 'hash',
			directives: {
				'script-src': ['self']
			}
		}
	}
};

export default config;
