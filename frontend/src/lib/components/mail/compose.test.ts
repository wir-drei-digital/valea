import { describe, it, expect } from 'vitest';
import {
  attachmentName,
  composeHref,
  composeValidationError,
  draftContent,
  draftDirty,
  emptyDraftFields,
  flushAction,
  formatAddressList,
  formatMailbox,
  forwardSubject,
  hasDraftContent,
  isWorkspaceRelativePath,
  loadDraftFields,
  parseAddressList,
  parseDraftFields,
  quoteBody,
  replyPrefill,
  replySubject,
  saveErrorMessage,
  setComposePrefill,
  takeComposePrefill,
  withAttachment,
  withoutAttachment,
  type DraftFields
} from './compose';

/** A landed message view's frontmatter, exactly as `Valea.Mail.MessageFile.render/2` writes it. */
function messageFrontmatter(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '2026-07-15-alex-4f2a91c3',
    message_id: '<m1@example.com>',
    account: 'mara',
    folders: ['INBOX'],
    flags: 'S',
    from: { name: 'Alex Kim', email: 'alex@example.com' },
    to: [
      { name: 'Mara Vance', email: 'mara@example.com' },
      { name: null, email: 'bo@example.com' }
    ],
    subject: 'Kickoff',
    date: null,
    in_reply_to: null,
    references: [],
    reply_to: null,
    attachments: [],
    ...overrides
  };
}

function fields(overrides: Partial<DraftFields> = {}): DraftFields {
  return { ...emptyDraftFields(), ...overrides };
}

describe('draftContent', () => {
  it('renders DraftFile frontmatter in its own key order, body verbatim', () => {
    const content = draftContent(
      fields({
        to: ['alex@example.com'],
        cc: ['Bo <bo@example.com>'],
        subject: 'Re: Kickoff',
        inReplyTo: '2026-07-15-alex-4f2a91c3',
        body: 'Hello Alex.\n\n--\nMara'
      })
    );

    expect(content).toBe(
      '---\n' +
        'to: ["alex@example.com"]\n' +
        'cc: ["Bo <bo@example.com>"]\n' +
        'bcc: []\n' +
        'subject: "Re: Kickoff"\n' +
        'in_reply_to: "2026-07-15-alex-4f2a91c3"\n' +
        '---\n' +
        'Hello Alex.\n\n--\nMara'
    );
  });

  it('omits in_reply_to when there is none, and never writes status or from', () => {
    const content = draftContent(fields({ to: ['a@x.com'], subject: 'Hi' }));

    expect(content).toBe('---\nto: ["a@x.com"]\ncc: []\nbcc: []\nsubject: "Hi"\n---\n');
    expect(content).not.toContain('in_reply_to');
    // `status:` is engine-owned and `from:` does not exist in the grammar —
    // writing either would be the composer asserting something it cannot know.
    expect(content).not.toContain('status:');
    expect(content).not.toContain('from:');
  });

  it('a body containing --- stays body (the FIRST terminator ends the block)', () => {
    const content = draftContent(fields({ to: ['a@x.com'], body: 'above\n---\nbelow' }));
    const parsed = parseDraftFields(content);

    expect(parsed.ok).toBe(true);
    expect(parsed.ok && parsed.fields.body).toBe('above\n---\nbelow');
  });
});

describe('draftContent — frontmatter injection safety', () => {
  it('a subject carrying newlines cannot forge a sibling key', () => {
    const content = draftContent(
      fields({ to: ['a@x.com'], subject: 'Hi\nbcc: [attacker@evil.example]\nsubject: owned' })
    );

    // One `subject:` line, one `bcc:` line — the injected text is inside the
    // quoted scalar with its newlines neutralized to spaces.
    expect(content.split('\n').filter((line) => line.startsWith('subject:'))).toHaveLength(1);
    expect(content.split('\n').filter((line) => line.startsWith('bcc:'))).toEqual(['bcc: []']);
    expect(content).toContain('subject: "Hi bcc: [attacker@evil.example] subject: owned"');
  });

  it('a subject carrying quotes and backslashes cannot close the scalar early', () => {
    const content = draftContent(fields({ to: ['a@x.com'], subject: 'say "hi"\\ now' }));

    expect(content).toContain('subject: "say \\"hi\\"\\\\ now"');
    const parsed = parseDraftFields(content);
    expect(parsed.ok && parsed.fields.subject).toBe('say "hi"\\ now');
  });

  it('a recipient carrying a newline cannot escape its flow sequence', () => {
    const content = draftContent(fields({ to: ['a@x.com\nbcc: [attacker@evil.example]'] }));

    expect(content.split('\n').filter((line) => line.startsWith('to:'))).toHaveLength(1);
    expect(content).toContain('to: ["a@x.com bcc: [attacker@evil.example]"]');
    // Not that it would be a valid mailbox — but the point is the shape:
    // the whole hostile string stays one quoted item of one key's value.
    expect(content.split('\n').filter((line) => line.startsWith('bcc:'))).toEqual(['bcc: []']);
  });

  it('a CR or NUL in a subject is neutralized, not escaped (DraftFile rejects the decoded control char)', () => {
    const content = draftContent(fields({ to: ['a@x.com'], subject: 'a\rb\u0000c' }));

    expect(content).toContain('subject: "a b c"');
    expect(content).not.toContain('\\r');
    expect(/[\r\u0000]/.test(content)).toBe(false);
  });
});

describe('parseDraftFields', () => {
  it('round-trips its own rendering', () => {
    const original = fields({
      to: ['alex@example.com', '"Public, John Q." <j@x.com>'],
      cc: ['bo@example.com'],
      bcc: ['secret@example.com'],
      subject: 'Re: Kickoff',
      inReplyTo: '2026-07-15-alex-4f2a91c3',
      body: 'Body text.\n'
    });

    const parsed = parseDraftFields(draftContent(original));
    expect(parsed).toEqual({ ok: true, fields: original });
  });

  it('reads the shapes an agent-written draft actually uses', () => {
    const parsed = parseDraftFields(
      '---\n' +
        'to: [alex@example.com, Bo <bo@example.com>]\n' +
        'cc:\n' +
        '  - carol@example.com\n' +
        'bcc: []\n' +
        "subject: 'Re: it''s time'\n" +
        'in_reply_to: 2026-07-15-alex-4f2a91c3\n' +
        'status: draft\n' +
        '---\n' +
        'Hello.\n'
    );

    expect(parsed).toEqual({
      ok: true,
      fields: {
        to: ['alex@example.com', 'Bo <bo@example.com>'],
        cc: ['carol@example.com'],
        bcc: [],
        subject: "Re: it's time",
        inReplyTo: '2026-07-15-alex-4f2a91c3',
        attachments: [],
        body: 'Hello.\n'
      }
    });
  });

  it('treats a bare string recipient as a one-element list (DraftFile.coerce_list)', () => {
    const parsed = parseDraftFields('---\nto: alex@example.com\n---\nHi');
    expect(parsed.ok && parsed.fields.to).toEqual(['alex@example.com']);
  });

  it('refuses frontmatter it cannot reproduce rather than dropping a field', () => {
    const cases = [
      ['unknown key', '---\nto: [a@x.com]\nfrom: mallory@evil.example\n---\nHi'],
      ['duplicate key', '---\nto: [a@x.com]\nto: [b@x.com]\n---\nHi'],
      ['a comment', '---\n# written by an agent\nto: [a@x.com]\n---\nHi'],
      ['a nested mapping', '---\nto: [a@x.com]\nsubject: Re: hi\n---\nHi'],
      ['an anchor', '---\nto: [a@x.com]\nsubject: &anchor hi\n---\nHi'],
      ['a block scalar', '---\nto: [a@x.com]\nsubject: |\n---\nHi'],
      ['an unterminated quote', '---\nto: ["a@x.com]\n---\nHi'],
      ['an unknown escape', '---\nto: [a@x.com]\nsubject: "a\\nb"\n---\nHi']
    ] as const;

    for (const [label, content] of cases) {
      expect({ label, ...parseDraftFields(content) }).toEqual({ label, ok: false, reason: 'unsupported' });
    }
  });

  it('refuses a file with no frontmatter block', () => {
    expect(parseDraftFields('Just a body.')).toEqual({ ok: false, reason: 'no_frontmatter' });
    expect(parseDraftFields('---\nto: [a@x.com]\n')).toEqual({ ok: false, reason: 'no_frontmatter' });
  });

  it('reads an empty/absent value as an empty field', () => {
    const parsed = parseDraftFields('---\nto: [a@x.com]\ncc:\nsubject:\nin_reply_to: null\n---\n');
    expect(parsed).toEqual({
      ok: true,
      fields: {
        to: ['a@x.com'],
        cc: [],
        bcc: [],
        subject: '',
        inReplyTo: null,
        attachments: [],
        body: ''
      }
    });
  });
});

describe('loadDraftFields', () => {
  // The draft an agent actually leaves behind: unquoted scalars, a block
  // sequence, an engine-stamped `status:` line (`DraftFile.stamp_status/2`
  // writes one and it survives a failed send returning the draft to `draft`),
  // and a key order of its own.
  const agentWritten =
    '---\n' +
    'subject: Kickoff notes\n' +
    'to:\n' +
    '  - alex@example.com\n' +
    '  - bo@example.com\n' +
    'status: draft\n' +
    'in_reply_to: 2026-07-15-alex-4f2a91c3\n' +
    '---\n' +
    'Here is the draft you asked for.\n';

  it('parses an agent-written draft AND gives it a clean baseline', () => {
    const loaded = loadDraftFields(agentWritten);

    expect(loaded.ok).toBe(true);
    if (!loaded.ok) return;
    expect(loaded.fields).toEqual({
      to: ['alex@example.com', 'bo@example.com'],
      cc: [],
      bcc: [],
      subject: 'Kickoff notes',
      inReplyTo: '2026-07-15-alex-4f2a91c3',
      attachments: [],
      body: 'Here is the draft you asked for.\n'
    });

    // THE point: the baseline is this module's rendering, not the disk bytes.
    // Comparing an untouched buffer against the file would report "unsaved
    // changes" for every draft not written in exactly this style — which is
    // most of them, since the composer drops the engine-owned `status:` line
    // and quotes what YAML lets you leave bare.
    expect(loaded.baseline).not.toBe(agentWritten);
    expect(loaded.baseline).toBe(draftContent(loaded.fields));
    expect(loaded.baseline).not.toContain('status:');
  });

  it('leaves its own rendering byte-identical, so a saved draft reopens clean', () => {
    const content = draftContent(
      fields({ to: ['a@x.com'], subject: 'Hi', body: 'Body.\n' })
    );
    const loaded = loadDraftFields(content);

    expect(loaded.ok && loaded.baseline).toBe(content);
  });

  it('keeps the raw bytes as the baseline for frontmatter it refuses', () => {
    const raw = '---\nto: [a@x.com]\nfrom: mallory@evil.example\n---\nHi';
    expect(loadDraftFields(raw)).toEqual({ ok: false, reason: 'unsupported', baseline: raw });
  });
});

describe('hasDraftContent', () => {
  it('is the "would the user mind losing this?" test for a draft with no file yet', () => {
    expect(hasDraftContent(emptyDraftFields())).toBe(false);
    expect(hasDraftContent(fields({ subject: '   ' }))).toBe(false);
    // Carried, never typed: a prefill emptied back out is nothing to keep.
    expect(hasDraftContent(fields({ inReplyTo: '2026-07-15-alex-4f2a91c3' }))).toBe(false);
    expect(hasDraftContent(fields({ to: ['a@x.com'] }))).toBe(true);
    expect(hasDraftContent(fields({ body: 'hi' }))).toBe(true);
  });
});

describe('draftDirty', () => {
  const saved = draftContent(fields({ to: ['a@x.com'], subject: 'Hi', body: 'Body.' }));

  it('compares against the saved baseline, and against "anything at all" before there is one', () => {
    expect(draftDirty(fields({ to: ['a@x.com'], subject: 'Hi', body: 'Body.' }), saved)).toBe(false);
    expect(draftDirty(fields({ to: ['a@x.com'], subject: 'Hi', body: 'Body!' }), saved)).toBe(true);
    expect(draftDirty(emptyDraftFields(), null)).toBe(false);
    expect(draftDirty(fields({ body: 'typed' }), null)).toBe(true);
  });
});

describe('flushAction', () => {
  const savedBaseline = draftContent(fields({ to: ['a@x.com'], body: 'On disk.' }));
  const edited = fields({ to: ['a@x.com'], body: 'Edited.' });

  const state = (overrides: Partial<Parameters<typeof flushAction>[0]> = {}) => ({
    discarded: false,
    readOnly: false,
    name: 'reply.md' as string | null,
    savedContent: savedBaseline as string | null,
    fields: edited,
    ...overrides
  });

  it('saves an edited draft that already has a file — CAS-bound, so it cannot clobber', () => {
    expect(flushAction(state())).toEqual({
      kind: 'save',
      name: 'reply.md',
      content: draftContent(edited)
    });
  });

  it('stashes a buffer with no file yet rather than minting a draft nobody asked for', () => {
    expect(flushAction(state({ name: null, savedContent: null }))).toEqual({ kind: 'stash', fields: edited });
  });

  it('does nothing for a discarded, read-only, clean, or empty buffer', () => {
    // The user said "Discard and leave" — the flush must not undo that.
    expect(flushAction(state({ discarded: true }))).toEqual({ kind: 'none' });
    // Locked by the ledger, or frontmatter this editor cannot rewrite.
    expect(flushAction(state({ readOnly: true }))).toEqual({ kind: 'none' });
    expect(
      flushAction(state({ fields: fields({ to: ['a@x.com'], body: 'On disk.' }) }))
    ).toEqual({ kind: 'none' });
    expect(flushAction(state({ name: null, savedContent: null, fields: emptyDraftFields() }))).toEqual({
      kind: 'none'
    });
  });
});

describe('parseAddressList / formatAddressList / formatMailbox', () => {
  it('splits on commas, semicolons and newlines, dropping blanks', () => {
    expect(parseAddressList(' a@x.com, b@x.com;\nc@x.com , ')).toEqual(['a@x.com', 'b@x.com', 'c@x.com']);
    expect(parseAddressList('   ')).toEqual([]);
  });

  it('does not split inside a quoted display name', () => {
    expect(parseAddressList('"Public, John Q." <j@x.com>, b@x.com')).toEqual([
      '"Public, John Q." <j@x.com>',
      'b@x.com'
    ]);
  });

  it('round-trips through the single-line field rendering', () => {
    const list = ['"Public, John Q." <j@x.com>', 'b@x.com'];
    expect(parseAddressList(formatAddressList(list))).toEqual(list);
  });

  it('quotes a display name only when RFC 5322 requires it', () => {
    expect(formatMailbox({ name: null, email: 'a@x.com' })).toBe('a@x.com');
    expect(formatMailbox({ name: 'Alex Kim', email: 'a@x.com' })).toBe('Alex Kim <a@x.com>');
    expect(formatMailbox({ name: "John Q. O'Brien", email: 'j@x.com' })).toBe("John Q. O'Brien <j@x.com>");
    expect(formatMailbox({ name: 'Public, John Q.', email: 'j@x.com' })).toBe('"Public, John Q." <j@x.com>');
    expect(formatMailbox({ name: 'say "hi"', email: 'j@x.com' })).toBe('"say \\"hi\\"" <j@x.com>');
    expect(formatMailbox({ name: 'Nobody', email: '' })).toBe('');
  });
});

describe('replySubject / forwardSubject', () => {
  it('prefixes once, whatever case or spacing the original used', () => {
    expect(replySubject('Kickoff')).toBe('Re: Kickoff');
    expect(replySubject('Re: Kickoff')).toBe('Re: Kickoff');
    expect(replySubject('re: Kickoff')).toBe('re: Kickoff');
    expect(replySubject('RE : Kickoff')).toBe('RE : Kickoff');
    expect(replySubject(replySubject('Kickoff'))).toBe('Re: Kickoff');
    // A forward being replied to is still a new reply.
    expect(replySubject('Fwd: Kickoff')).toBe('Re: Fwd: Kickoff');
  });

  it('accepts Fw:/Fwd:/Forward: as already forwarded', () => {
    expect(forwardSubject('Kickoff')).toBe('Fwd: Kickoff');
    expect(forwardSubject('Fwd: Kickoff')).toBe('Fwd: Kickoff');
    expect(forwardSubject('FW: Kickoff')).toBe('FW: Kickoff');
    expect(forwardSubject('Forward: Kickoff')).toBe('Forward: Kickoff');
    expect(forwardSubject(forwardSubject('Kickoff'))).toBe('Fwd: Kickoff');
    expect(forwardSubject('Re: Kickoff')).toBe('Fwd: Re: Kickoff');
  });

  it('leaves a blank subject blank rather than writing a bare prefix', () => {
    expect(replySubject('')).toBe('');
    expect(replySubject('   ')).toBe('');
    expect(forwardSubject('')).toBe('');
  });
});

describe('quoteBody', () => {
  it('prefixes every line, quotes blank lines bare, and drops the trailing blanks', () => {
    expect(quoteBody('one\n\ntwo\r\nthree\n\n\n')).toBe('> one\n>\n> two\n> three');
    expect(quoteBody('')).toBe('');
    expect(quoteBody('   \n')).toBe('');
  });
});

describe('replyPrefill — reply', () => {
  it('addresses the sender, prefixes the subject, threads on the msg_id and quotes the body', () => {
    const prefill = replyPrefill(
      { frontmatter: messageFrontmatter(), body: 'Can you review this?\n' },
      'mara@example.com',
      'reply'
    );

    expect(prefill.to).toEqual(['Alex Kim <alex@example.com>']);
    expect(prefill.cc).toEqual([]);
    expect(prefill.bcc).toEqual([]);
    expect(prefill.subject).toBe('Re: Kickoff');
    expect(prefill.inReplyTo).toBe('2026-07-15-alex-4f2a91c3');
    expect(prefill.body).toBe('\n\nAlex Kim <alex@example.com> wrote:\n\n> Can you review this?\n');
  });

  it('prefers reply_to over from when the message named one', () => {
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({ reply_to: { name: null, email: 'list@example.com' } }),
        body: ''
      },
      'mara@example.com',
      'reply'
    );

    expect(prefill.to).toEqual(['list@example.com']);
  });

  it('names the date in the attribution line when the message has one', () => {
    const prefill = replyPrefill(
      { frontmatter: messageFrontmatter({ date: '2026-07-15T09:30:00Z' }), body: 'hi' },
      null,
      'reply'
    );

    expect(prefill.body).toMatch(/^\n\nOn .+, Alex Kim <alex@example\.com> wrote:\n\n> hi\n$/);
  });

  it('drops a threading hint that is not a msg_id rather than poisoning the draft', () => {
    const prefill = replyPrefill(
      { frontmatter: messageFrontmatter({ id: '<raw-message-id@example.com>' }), body: '' },
      null,
      'reply'
    );

    expect(prefill.inReplyTo).toBeNull();
  });
});

describe('replyPrefill — reply-all', () => {
  it('keeps the sender in To, the rest in Cc, minus the account address', () => {
    const prefill = replyPrefill(
      { frontmatter: messageFrontmatter(), body: 'hi' },
      'MARA@example.com',
      'replyAll'
    );

    // `mara@example.com` was in `to:` and is gone — case-insensitively.
    expect(prefill.to).toEqual(['Alex Kim <alex@example.com>']);
    expect(prefill.cc).toEqual(['bo@example.com']);
  });

  it('de-dups across To and Cc, first occurrence wins', () => {
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({
          to: [
            { name: 'Alex (work)', email: 'ALEX@example.com' },
            { name: null, email: 'bo@example.com' },
            { name: null, email: 'bo@example.com' }
          ]
        }),
        body: 'hi'
      },
      'mara@example.com',
      'replyAll'
    );

    expect(prefill.to).toEqual(['Alex Kim <alex@example.com>']);
    expect(prefill.cc).toEqual(['bo@example.com']);
  });

  it('still addresses someone when replying to a message you sent yourself', () => {
    const own = 'mara@example.com';
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({
          from: { name: 'Mara Vance', email: own },
          to: [{ name: null, email: own }]
        }),
        body: 'note to self'
      },
      own,
      'replyAll'
    );

    expect(prefill.to).toEqual(['Mara Vance <mara@example.com>']);
    expect(prefill.cc).toEqual([]);
  });

  it('promotes the first remaining recipient when the sender is the account itself', () => {
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({ from: { name: 'Mara Vance', email: 'mara@example.com' } }),
        body: 'hi'
      },
      'mara@example.com',
      'replyAll'
    );

    expect(prefill.to).toEqual(['bo@example.com']);
    expect(prefill.cc).toEqual([]);
  });

  it('keeps every recipient when no account address is known', () => {
    const prefill = replyPrefill({ frontmatter: messageFrontmatter(), body: 'hi' }, null, 'replyAll');

    expect(prefill.to).toEqual(['Alex Kim <alex@example.com>']);
    expect(prefill.cc).toEqual(['Mara Vance <mara@example.com>', 'bo@example.com']);
  });
});

describe('replyPrefill — forward', () => {
  it('addresses nobody, does not thread, and carries the original unquoted under a separator', () => {
    const prefill = replyPrefill(
      { frontmatter: messageFrontmatter(), body: 'The original text.\n' },
      'mara@example.com',
      'forward'
    );

    expect(prefill.to).toEqual([]);
    expect(prefill.cc).toEqual([]);
    expect(prefill.subject).toBe('Fwd: Kickoff');
    expect(prefill.inReplyTo).toBeNull();
    expect(prefill.body).toBe(
      '\n\n---------- Forwarded message ----------\n' +
        'From: Alex Kim <alex@example.com>\n' +
        'Subject: Kickoff\n' +
        'To: Mara Vance <mara@example.com>, bo@example.com\n' +
        '\n' +
        'The original text.\n'
    );
    expect(prefill.body).not.toContain('> ');
  });

  it('omits header lines the message does not have', () => {
    const prefill = replyPrefill(
      { frontmatter: { from: { name: null, email: 'a@x.com' } }, body: 'body' },
      null,
      'forward'
    );

    expect(prefill.body).toBe('\n\n---------- Forwarded message ----------\nFrom: a@x.com\n\nbody\n');
  });

  it('survives a message with no frontmatter at all', () => {
    const prefill = replyPrefill({ frontmatter: null, body: '' }, null, 'forward');
    expect(prefill.subject).toBe('');
    expect(prefill.to).toEqual([]);
  });

  // A forward re-REFERENCES the original's landed attachment files — they are
  // already workspace files at exactly the address `attachments:` takes, so
  // nothing is copied and nothing is uploaded.
  it('re-references the original’s landed attachment paths', () => {
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({
          attachments: [
            {
              filename: 'deck.pdf',
              path: 'sources/mail/mara/views/attachments/2026-07-15-alex-4f2a91c3/deck.pdf',
              bytes: 2048
            },
            {
              filename: 'photo.png',
              path: 'sources/mail/mara/views/attachments/2026-07-15-alex-4f2a91c3/photo.png',
              bytes: 512
            }
          ]
        }),
        body: 'original'
      },
      'mara@example.com',
      'forward'
    );

    expect(prefill.attachments).toEqual([
      'sources/mail/mara/views/attachments/2026-07-15-alex-4f2a91c3/deck.pdf',
      'sources/mail/mara/views/attachments/2026-07-15-alex-4f2a91c3/photo.png'
    ]);
  });

  it('drops a landed path this composer cannot vouch for, rather than poisoning the draft', () => {
    const prefill = replyPrefill(
      {
        frontmatter: messageFrontmatter({
          attachments: [
            { filename: 'ok.pdf', path: 'sources/mail/mara/views/attachments/m1/ok.pdf', bytes: 1 },
            { filename: 'bad.pdf', path: '/absolute/bad.pdf', bytes: 1 },
            { filename: 'esc.pdf', path: '../../escape.pdf', bytes: 1 }
          ]
        }),
        body: 'original'
      },
      null,
      'forward'
    );

    expect(prefill.attachments).toEqual(['sources/mail/mara/views/attachments/m1/ok.pdf']);
  });

  it('a reply carries none, even off a message that had them', () => {
    const frontmatter = messageFrontmatter({
      attachments: [{ filename: 'deck.pdf', path: 'sources/mail/mara/x/deck.pdf', bytes: 1 }]
    });

    for (const mode of ['reply', 'replyAll'] as const) {
      expect(replyPrefill({ frontmatter, body: 'hi' }, null, mode).attachments).toEqual([]);
    }
  });
});

describe('attachments — the frontmatter key', () => {
  const DECK = 'sources/mail/mara/views/attachments/2026-07-15-alex-4f2a91c3/deck.pdf';

  it('renders after in_reply_to, as a flow sequence of quoted scalars', () => {
    const content = draftContent(
      fields({ to: ['a@x.com'], inReplyTo: '2026-07-15-alex-4f2a91c3', attachments: [DECK] })
    );

    expect(content).toBe(
      '---\n' +
        'to: ["a@x.com"]\n' +
        'cc: []\n' +
        'bcc: []\n' +
        'subject: ""\n' +
        'in_reply_to: "2026-07-15-alex-4f2a91c3"\n' +
        `attachments: ["${DECK}"]\n` +
        '---\n'
    );
  });

  // The whole existing corpus of drafts must render byte-identically, or every
  // reopen shows up dirty and every agent-written draft looks edited.
  it('is omitted entirely when there is none', () => {
    const content = draftContent(fields({ to: ['a@x.com'], subject: 'Hi' }));

    expect(content).toBe('---\nto: ["a@x.com"]\ncc: []\nbcc: []\nsubject: "Hi"\n---\n');
    expect(content).not.toContain('attachments');
  });

  it('round-trips through parseDraftFields, order and duplicates intact', () => {
    const original = fields({
      to: ['a@x.com'],
      attachments: [DECK, 'notes/second.txt', DECK]
    });

    const parsed = parseDraftFields(draftContent(original));
    expect(parsed.ok).toBe(true);
    expect(parsed.ok && parsed.fields).toEqual(original);
  });

  it('reads an agent-written draft: unquoted scalars, a block sequence, a `status:` line', () => {
    const parsed = parseDraftFields(
      '---\nto: a@x.com\nattachments:\n  - notes/deck.pdf\n  - notes/two.png\nstatus: draft\n---\nBody.\n'
    );

    expect(parsed.ok).toBe(true);
    expect(parsed.ok && parsed.fields.attachments).toEqual(['notes/deck.pdf', 'notes/two.png']);
  });

  it('an empty list parses as none, and re-renders without the key (clean baseline)', () => {
    const loaded = loadDraftFields('---\nto: [a@x.com]\nattachments: []\n---\nBody.\n');

    expect(loaded.ok).toBe(true);
    expect(loaded.ok && loaded.fields.attachments).toEqual([]);
    // The baseline is this module's own rendering, so a draft written with an
    // empty `attachments:` still opens CLEAN rather than pre-dirtied.
    expect(loaded.ok && draftDirty(loaded.fields, loaded.baseline)).toBe(false);
  });

  it('counts as content worth keeping', () => {
    expect(hasDraftContent(fields({ attachments: [DECK] }))).toBe(true);
    expect(hasDraftContent(emptyDraftFields())).toBe(false);
  });

  it('a path carrying newlines cannot forge a sibling key', () => {
    const content = draftContent(
      fields({ to: ['a@x.com'], attachments: ['ok.pdf"]\nbcc: [attacker@evil.example]\nx: ["y'] })
    );

    expect(content.split('\n').filter((line) => line.startsWith('attachments:'))).toHaveLength(1);
    expect(content.split('\n').filter((line) => line.startsWith('bcc:'))).toEqual(['bcc: []']);
    expect(content).not.toContain('attacker@evil.example]\n');
    // ...and it survives the round trip as the one hostile string it is.
    const parsed = parseDraftFields(content);
    expect(parsed.ok && parsed.fields.attachments).toEqual([
      'ok.pdf"] bcc: [attacker@evil.example] x: ["y'
    ]);
  });

  it('refuses to open a draft whose frontmatter carries a key it cannot re-render', () => {
    const loaded = loadDraftFields('---\nto: [a@x.com]\nattachment: notes/deck.pdf\n---\nBody.\n');
    expect(loaded.ok).toBe(false);
    expect(!loaded.ok && loaded.reason).toBe('unsupported');
  });
});

describe('isWorkspaceRelativePath / withAttachment / withoutAttachment / attachmentName', () => {
  it('accepts ordinary workspace-relative paths', () => {
    expect(isWorkspaceRelativePath('notes/deck.pdf')).toBe(true);
    expect(isWorkspaceRelativePath('a b/c (1).txt')).toBe(true);
    expect(isWorkspaceRelativePath('deck.pdf')).toBe(true);
  });

  // `DraftFile`'s rule, mirrored: one bad path refuses the WHOLE draft
  // backend-side, so nothing that would fail there is ever put in the buffer.
  it('refuses absolute paths, drive forms, traversals and control characters', () => {
    for (const bad of [
      '',
      '   ',
      '/etc/passwd',
      'C:/Windows/notes.txt',
      '../../etc/passwd',
      'notes/../../etc/passwd',
      '..\\..\\secrets',
      './deck.pdf',
      'notes//deck.pdf',
      'notes/',
      'notes/a\nb.pdf',
      'notes/a\u0000b.pdf'
    ]) {
      expect(isWorkspaceRelativePath(bad), bad).toBe(false);
    }
  });

  it('withAttachment appends valid paths, refuses invalid ones, and never duplicates', () => {
    expect(withAttachment([], 'notes/deck.pdf')).toEqual(['notes/deck.pdf']);
    expect(withAttachment(['notes/deck.pdf'], '  notes/two.txt ')).toEqual([
      'notes/deck.pdf',
      'notes/two.txt'
    ]);
    expect(withAttachment(['notes/deck.pdf'], 'notes/deck.pdf')).toEqual(['notes/deck.pdf']);
    expect(withAttachment([], '../escape.pdf')).toEqual([]);
  });

  it('withoutAttachment removes every occurrence', () => {
    expect(withoutAttachment(['a/x.pdf', 'b/y.pdf', 'a/x.pdf'], 'a/x.pdf')).toEqual(['b/y.pdf']);
  });

  it('attachmentName is the basename, either separator', () => {
    expect(attachmentName('sources/mail/mara/views/attachments/m1/deck.pdf')).toBe('deck.pdf');
    expect(attachmentName('deck.pdf')).toBe('deck.pdf');
  });
});

describe('composeHref', () => {
  it('account-qualifies both targets', () => {
    expect(composeHref('mara', null)).toBe('/mail?account=mara&compose=new');
    // Draft names carry their `.md` everywhere on this RPC surface
    // (`list_mail_drafts`/`get_mail_draft`/`write_mail_draft`), so the link does too.
    expect(composeHref('mara', '20260715T090000-re-kickoff.md')).toBe(
      '/mail?account=mara&compose=20260715T090000-re-kickoff.md'
    );
    expect(composeHref(null, null)).toBe('/mail?compose=new');
  });
});

describe('composeValidationError', () => {
  it('requires a recipient and nothing else', () => {
    expect(composeValidationError(emptyDraftFields())).toBe('Add at least one address in To.');
    // No subject and no body is a legitimate (if terse) draft — `DraftFile`
    // allows both, so the composer does not invent a rule it doesn't have.
    expect(composeValidationError(fields({ to: ['a@x.com'] }))).toBeNull();
  });
});

describe('saveErrorMessage', () => {
  it('explains what to do about a CAS conflict and a locked draft', () => {
    expect(saveErrorMessage('content_changed')).toContain('Reload');
    expect(saveErrorMessage('draft_busy')).toContain('already been sent');
    expect(saveErrorMessage('invalid_draft')).toContain('addresses');
    expect(saveErrorMessage('write_failed')).toContain("couldn't be written");
    expect(saveErrorMessage('nonsense_code')).toBe('Could not save the draft. Please try again.');
  });
});

describe('compose prefill handoff', () => {
  it('hands the prefill over exactly once', () => {
    const prefill = fields({ to: ['a@x.com'] });
    setComposePrefill('mara', prefill);

    expect(takeComposePrefill('mara')).toEqual(prefill);
    expect(takeComposePrefill('mara')).toBeNull();
  });

  it('never lands a prefill in another account’s composer, and leaves it for the one it named', () => {
    const prefill = fields({ to: ['a@x.com'] });
    setComposePrefill('mara', prefill);

    expect(takeComposePrefill('zoe')).toBeNull();
    // Left where it is, deliberately: the unmount this stash also serves IS an
    // account switch, so dropping it as the other account's composer mounts
    // would lose exactly the buffer it just rescued.
    expect(takeComposePrefill('mara')).toEqual(prefill);
    expect(takeComposePrefill('mara')).toBeNull();
  });

  it('holds one slot — a newer stash replaces an older one', () => {
    setComposePrefill('mara', fields({ subject: 'first' }));
    setComposePrefill('mara', fields({ subject: 'second' }));

    expect(takeComposePrefill('mara')?.subject).toBe('second');
  });
});
