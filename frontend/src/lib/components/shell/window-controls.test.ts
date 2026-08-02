import { describe, expect, it } from 'vitest';
import { controlsInset, controlsLabel } from './window-controls';

// A SMOKE TEST over a shared constant, and worth being honest about its limit:
// it cannot check the thing that actually matters, which is that the inset a
// route header reserves equals the width the rendered cluster occupies. That
// needs a rendered cluster, and this repo has no component render harness.
// What it does check is that the numbers do not move silently — hence hand-
// written literals below rather than the metrics re-multiplied. An earlier
// draft of this file computed the expected value from `CONTROL_METRICS`, which
// restated the implementation's formula over the implementation's own
// constants: it passed for any values and any formula, so long as both copies
// were edited together, which is the only way anyone would edit them.
describe('controlsLabel', () => {
  it('offers to maximise a restored window', () => {
    expect(controlsLabel(false)).toBe('Maximise');
  });

  it('offers to restore a maximised one', () => {
    expect(controlsLabel(true)).toBe('Restore');
  });
});

// Literals, deliberately. A changed metric has to FAIL here and be re-checked
// against the cluster by eye, because nothing else in the suite can catch a
// cluster and an inset that have drifted apart — and the symptom on a real
// window is silent: the controls simply sit on top of a route's own buttons.
describe('controlsInset', () => {
  it('reserves exactly the cluster width on Windows: three 46px buttons, no gaps', () => {
    expect(controlsInset('windows')).toBe('138px');
  });

  it('reserves the buttons plus gaps and padding on Linux: 3×24 + 2×8 + 2×8', () => {
    expect(controlsInset('linux')).toBe('104px');
  });

  // The routes must pay nothing where the OS draws the controls, or every
  // header on macOS and in the browser gains padding for furniture that is not
  // there.
  it('reserves nothing where the app does not draw the controls', () => {
    expect(controlsInset('macos-overlay')).toBe('0px');
    expect(controlsInset('browser')).toBe('0px');
  });
});
