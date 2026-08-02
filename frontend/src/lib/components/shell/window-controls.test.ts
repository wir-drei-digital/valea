import { describe, expect, it } from 'vitest';
import { CONTROL_METRICS, controlsInset, controlsLabel } from './window-controls';

// The pure half of the control cluster. There is no component render harness in
// this repo, so this is where the logic that can be checked lives.
describe('controlsLabel', () => {
  it('offers to maximise a restored window', () => {
    expect(controlsLabel(false)).toBe('Maximise');
  });

  it('offers to restore a maximised one', () => {
    expect(controlsLabel(true)).toBe('Restore');
  });
});

// THE test that earns its keep. The inset every route header reserves and the
// width the buttons actually occupy are two numbers that must agree, and
// nothing in the browser will complain when they stop agreeing — the window
// controls will simply sit on top of a route's own buttons. Deriving the inset
// from the same metrics the component lays itself out from is what keeps them
// in step; this asserts the derivation rather than a hand-copied total.
describe('controlsInset', () => {
  it('reserves exactly the cluster width on Windows: three buttons, no gaps', () => {
    const { button, gap, padding } = CONTROL_METRICS.windows;
    expect(controlsInset('windows')).toBe(`${button * 3 + gap * 2 + padding * 2}px`);
  });

  it('reserves the buttons plus gaps and padding on Linux', () => {
    const { button, gap, padding } = CONTROL_METRICS.linux;
    expect(controlsInset('linux')).toBe(`${button * 3 + gap * 2 + padding * 2}px`);
  });

  // The routes must pay nothing where the OS draws the controls, or every
  // header on macOS and in the browser gains padding for furniture that is not
  // there.
  it('reserves nothing where the app does not draw the controls', () => {
    expect(controlsInset('macos-overlay')).toBe('0px');
    expect(controlsInset('browser')).toBe('0px');
  });
});
