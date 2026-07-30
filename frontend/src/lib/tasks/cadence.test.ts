import { describe, expect, it } from 'vitest';
import { humanizeCron } from './cadence';

// Table-driven, per the spec's own framing of this function: each row is a
// wire-realistic cron expression and the phrase the Schedules tab must show.
// The fallback rows matter most — `humanizeCron` is a RENDERER, and a
// confidently-wrong phrasing of an exotic expression is worse than the raw
// expression (see the module's header comment).
const VECTORS: Array<[string, string]> = [
  // The three vectors the spec/brief pin by name.
  ['30 7 * * 1-5', 'weekdays 07:30'],
  ['0 * * * *', 'hourly at :00'],
  ['0 9 * * 1', 'Mondays 09:00'],

  // Aliases the backend cron accepts.
  ['@hourly', 'hourly at :00'],
  ['@daily', 'daily 00:00'],
  ['@midnight', 'daily 00:00'],
  ['@weekly', 'Sundays 00:00'],
  ['@monthly', 'monthly on day 1, 00:00'],
  ['@HOURLY', 'hourly at :00'],

  // Daily / minute-step / named-day shapes.
  ['30 7 * * *', 'daily 07:30'],
  ['0 0 * * *', 'daily 00:00'],
  ['5 23 * * *', 'daily 23:05'],
  ['15 * * * *', 'hourly at :15'],
  ['*/15 * * * *', 'every 15 minutes'],
  ['*/1 * * * *', 'every minute'],
  ['0 9 * * 0', 'Sundays 09:00'],
  ['0 9 * * 7', 'Sundays 09:00'],
  ['0 9 * * 6', 'Saturdays 09:00'],
  ['0 9 * * 1,3,5', 'Mon, Wed, Fri 09:00'],
  ['0 9 * * 6,0', 'weekends 09:00'],
  ['0 9 * * 0,6', 'weekends 09:00'],
  ['0 6 1 * *', 'monthly on day 1, 06:00'],
  ['45 18 28 * *', 'monthly on day 28, 18:45'],

  // Leading zeros and extra whitespace are the same expression.
  ['30 07 * * 1-5', 'weekdays 07:30'],
  ['  0   9  *  *  1  ', 'Mondays 09:00'],

  // FALLBACK — everything the renderer refuses to phrase comes back verbatim.
  ['0 9 * 3 1-5', '0 9 * 3 1-5'],
  ['0 9 1 * 1', '0 9 1 * 1'],
  ['15,45 * * * *', '15,45 * * * *'],
  ['0 9-17 * * *', '0 9-17 * * *'],
  ['0 9 * * 2-6', '0 9 * * 2-6'],
  ['0 9 * * MON', '0 9 * * MON'],
  ['*/0 * * * *', '*/0 * * * *'],
  ['0 9 0 * *', '0 9 0 * *'],
  ['70 9 * * *', '70 9 * * *'],
  ['0 25 * * *', '0 25 * * *'],
  ['@yearly', '@yearly'],
  ['0 9 * *', '0 9 * *'],
  ['0 9 * * * *', '0 9 * * * *'],
  ['not a cron', 'not a cron'],
  ['', '']
];

describe('humanizeCron', () => {
  for (const [expr, expected] of VECTORS) {
    it(`renders ${JSON.stringify(expr)} as ${JSON.stringify(expected)}`, () => {
      expect(humanizeCron(expr)).toBe(expected);
    });
  }

  it('never invents a phrase for a shape it does not recognize', () => {
    // A property-ish backstop for the fallback contract: anything whose
    // rendered form differs from the input must be one of the phrasings above,
    // so a future rule can't quietly start guessing at ranges/lists.
    const exotic = ['0 9 3-5 * *', '*/7 9 * * *', '0 */2 * * *', '30 7 * * 1-5,0'];
    for (const expr of exotic) {
      expect(humanizeCron(expr)).toBe(expr);
    }
  });
});
