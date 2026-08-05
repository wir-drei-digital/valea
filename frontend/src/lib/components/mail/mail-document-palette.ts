/**
 * The white sheet a mail message is rendered on, in both branches.
 *
 * Email HTML assumes a white background — dark inline text on a dark canvas
 * is invisible, and rewriting sender styles to fix it breaks inline styles,
 * background images and logos unpredictably. So the message stays a white
 * sheet of paper inside a dark app, which is coherent in a paper & ink
 * system rather than accidental.
 *
 * These are LITERALS, not `var(--…)`, and they are shared through TypeScript
 * rather than CSS: `HtmlMailView` renders into an iframe, a separate
 * document that "can't reach the app's CSS variables" (its own comment) and
 * whose CSP allows no external stylesheet. The plain-text branch feeds these
 * same values to scoped custom properties, so
 * `MessageView.svelte`'s promise — "the same white reading card the HTML
 * view's iframe provides" — is enforced by one definition instead of two
 * that happen to match today.
 *
 * Every ink the sheet carries lives here, the link's hover underline
 * included: anything left on an app token would follow the theme onto a
 * surface that does not, and in dark that means near-white on white.
 */
export const MAIL_DOCUMENT_PALETTE = {
  background: '#ffffff',
  ink: '#1c1c1c',
  link: '#1a4d8f',
  linkUnderline: '#9db8d6',
  linkUnderlineHover: '#1a4d8f',
  chipBorder: '#d8cfb9',
  chipBackground: '#fbf8f1',
  // Not `--ink-meta`'s value (#948a75): at the chips' 12.5px that measured
  // 3.22:1 on the chip fill, under AA. Same warm hue, darkened to 4.9:1 —
  // the sheet is white-locked, so this is theme-independent and the palette
  // test holds it to the 4.5:1 floor like every other ink here.
  chipInk: '#756c58'
} as const;
