/**
 * Applies the theme before first paint.
 *
 * An EXTERNAL file, not an inline script: `svelte.config.js` sets a
 * hash-mode CSP with `script-src 'self'`, and SvelteKit hashes only the
 * scripts it generates — an inline one here is blocked in production
 * builds, which is where the launch flash would be. `'self'` allows this.
 *
 * It duplicates the key, the class and the branch from
 * `src/lib/stores/theme.ts`, because importing from the bundle would make
 * it render-blocking on the app chunk and defeat the point.
 * `theme-init.test.ts` evaluates THIS FILE and pins it to `resolveTheme`.
 *
 * Must never throw: a locked-down WebView with storage denied should get a
 * usable app, not a blank one. Every fallback here matches `readStored()`
 * and `systemPrefersDark()` in `theme.svelte.ts` — if the two disagreed,
 * hydration would repaint and produce exactly the flash this file prevents.
 */
(function () {
  var root = document.documentElement;
  var preference = 'system';

  try {
    var stored = localStorage.getItem('valea.theme');
    if (stored === 'light' || stored === 'dark' || stored === 'system') preference = stored;
  } catch (e) {
    preference = 'system';
  }

  var prefersDark = false;
  try {
    prefersDark = matchMedia('(prefers-color-scheme: dark)').matches;
  } catch (e) {
    prefersDark = false;
  }

  var resolved = preference === 'system' ? (prefersDark ? 'dark' : 'light') : preference;

  if (resolved === 'dark') root.classList.add('dark');
  else root.classList.remove('dark');

  root.style.colorScheme = resolved;
  // Covers first paint and overscroll before layout.css lands.
  root.style.background = resolved === 'dark' ? '#1e1a13' : '#fbf8f1';
})();
