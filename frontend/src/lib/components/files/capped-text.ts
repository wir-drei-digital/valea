/**
 * Reads a `/files/raw` body as text with a hard byte cap, shared by every
 * text-shaped viewer (`PlainTextView`, `CsvView`).
 *
 * The cap is enforced on the WIRE, not after the fact: admission to
 * `/files/raw` is extension-free and the serve path has no size limit, so
 * `await res.text()` — read the whole body, then slice — meant one click on a
 * video or a rotated log buffered the entire file into the renderer before
 * anything was capped. The body is read chunk by chunk instead, and the
 * reader is cancelled the moment CAP bytes are in hand.
 */

/** Bytes off the wire, not characters — what the viewers' "500 KB" note promises. */
export const TEXT_CAP = 500_000;

export type CappedText = { text: string; truncated: boolean };

/**
 * Reads at most `TEXT_CAP` bytes of `body`, decoded incrementally. Whether
 * bytes were left unread is asked EXACTLY: a file whose size is a precise
 * multiple of the chunking is not reported truncated on a guess, it costs
 * one more `read()` to know.
 */
export async function readCapped(body: ReadableStream<Uint8Array>): Promise<CappedText> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let out = '';
  let received = 0;
  let more = false;

  try {
    while (received < TEXT_CAP) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;
      const room = TEXT_CAP - received;
      if (value.byteLength > room) {
        // A cut can land mid-codepoint; the flush below emits the
        // replacement char rather than a mojibake tail.
        out += decoder.decode(value.subarray(0, room), { stream: true });
        received = TEXT_CAP;
        more = true;
        break;
      }
      received += value.byteLength;
      out += decoder.decode(value, { stream: true });
    }
    if (received >= TEXT_CAP && !more) {
      more = !(await reader.read()).done;
    }
    out += decoder.decode();
    return { text: out, truncated: more };
  } finally {
    // Releases the connection: without this a capped read would leave the
    // rest of a multi-gigabyte body streaming into a reader nobody holds.
    void reader.cancel().catch(() => {});
  }
}

/**
 * `readCapped` for a whole response: falls back to a plain body read where
 * streams are unavailable (`res.body` is null only there, and on a 204 —
 * which this route never sends), so a readable file is never reported as an
 * error just because the stream API is missing.
 */
export async function cappedResponseText(res: Response): Promise<CappedText> {
  if (res.body) return readCapped(res.body);
  const whole = await res.text();
  return { text: whole.slice(0, TEXT_CAP), truncated: whole.length > TEXT_CAP };
}
