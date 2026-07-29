/**
 * Composer logic (mail full-client design §M2 §Compose UI) — everything
 * `ComposeView.svelte` would otherwise do inline, kept here because this
 * codebase has no component render harness: a rule about draft bytes that
 * lives in a `.svelte` file is a rule nothing can test.
 *
 * Three jobs:
 *
 *  1. **Rendering draft bytes** (`draftContent`) — the frontmatter grammar of
 *     `Valea.Mail.DraftFile`, mirrored field for field, with every value
 *     injection-hardened. What this function returns is what
 *     `write_mail_draft` parses with the real thing; a disagreement here is
 *     an `invalid_draft` refusal at best and a forged frontmatter key at
 *     worst.
 *  2. **Reading them back** (`parseDraftFields`) — deliberately conservative.
 *     Draft files are also written by agents through their mount, in whatever
 *     YAML they please; anything this parser cannot round-trip with certainty
 *     is REFUSED (`unsupported`) so the composer can fall back to a read-only
 *     view, rather than silently dropping a field on the next save.
 *  3. **Prefilling a reply/forward** (`replyPrefill`) — recipient math,
 *     idempotent `Re:`/`Fwd:` prefixes, `> ` quoting, forward separator.
 *
 * Plus the in-memory handoff (`setComposePrefill`/`takeComposePrefill`) that
 * carries a prefill from the read pane to the composer: the same one-shot
 * module-level stash as `stores/initial-prompt.ts`, for the same reason —
 * a quoted message body has no business in a URL.
 */
import {
  addressEmail,
  addressLabel,
  addressListLabel,
  addressName,
  attachmentsFromFrontmatter,
  formatDateTime,
  type RawAddress
} from './mail-shapes';

/** One recipient, as both the message frontmatter and the drafts list carry it. */
export type Mailbox = { name: string | null; email: string };

/** Which prefill the read pane asked for. */
export type ComposeMode = 'reply' | 'replyAll' | 'forward';

/**
 * The composer's editable state, in draft-file terms. Recipients are RFC 5322
 * mailbox STRINGS (`"a@x.com"`, `"Alex Kim <a@x.com>"`) rather than parsed
 * pairs: that is what the user types, what the file carries, and what
 * `DraftFile.parse_mailbox/1` is the authority on — parsing them here would
 * only create a second, weaker grammar to disagree with.
 */
export type DraftFields = {
  to: string[];
  cc: string[];
  bcc: string[];
  subject: string;
  /** A msg_id (`DraftFile`'s shape), never a raw `Message-ID` header — threading resolves backend-side at review time. */
  inReplyTo: string | null;
  /**
   * Workspace-relative paths, in the order they become MIME parts.
   * Addresses, not files: nothing here is read, sized or hashed frontend-side
   * — `OpsExecutor` resolves each one against the workspace root at review
   * and at send, and the review snapshot is what tells the human what will
   * actually leave (name + size, hash-bound).
   */
  attachments: string[];
  body: string;
};

/** A blank composer. A function, not a shared const — the caller mutates its copy. */
export function emptyDraftFields(): DraftFields {
  return { to: [], cc: [], bcc: [], subject: '', inReplyTo: null, attachments: [], body: '' };
}

/**
 * Whether a buffer holds anything a user would mind losing — the "is a
 * not-yet-created draft dirty?" question, for which there is no saved
 * revision to compare against. `inReplyTo` deliberately does not count: it is
 * carried, never typed, so a prefill reduced back to nothing is nothing.
 */
export function hasDraftContent(fields: DraftFields): boolean {
  return (
    fields.to.length > 0 ||
    fields.cc.length > 0 ||
    fields.bcc.length > 0 ||
    fields.subject.trim() !== '' ||
    fields.attachments.length > 0 ||
    fields.body.trim() !== ''
  );
}

// -- rendering ----------------------------------------------------------------

/**
 * The msg_id shape, mirroring `DraftFile`'s `@msg_id_re`. A prefill whose
 * source message carries something else in `id` drops the threading hint
 * instead of writing a value the backend would refuse the whole draft over.
 */
const MSG_ID_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$/;

/**
 * Neutralizes C0/DEL control characters to a plain space — the same
 * substitution (not deletion, so nothing shifts) `Valea.Mail.MessageFile`'s
 * `yaml_string/1` applies to header text it writes into a view file.
 *
 * Escaping the newline instead would be worse than useless: `\n` inside a
 * double-quoted YAML scalar decodes BACK to a real newline, and
 * `DraftFile.parse_and_validate/1` rejects any CR/LF/NUL in any field
 * ("header-injection defense"). A subject pasted out of another client
 * therefore saves as a one-line subject rather than failing the grammar.
 */
function neutralizeControl(value: string): string {
  let out = '';
  for (const ch of value) {
    const code = ch.codePointAt(0) ?? 0;
    out += code < 0x20 || code === 0x7f ? ' ' : ch;
  }
  return out;
}

/**
 * A double-quoted YAML scalar — control characters neutralized, then `\` and
 * `"` escaped. This is the ONLY way a caller-supplied string reaches the
 * frontmatter block: a subject of `x"\nto: [attacker@evil.example]` renders
 * as one quoted scalar on one line, so it can neither close the string early
 * nor forge a sibling key.
 */
function yamlString(value: string): string {
  return `"${neutralizeControl(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/** A YAML flow sequence of quoted scalars — `[]` when empty, matching `DraftFile`'s documented shape. */
function yamlList(values: string[]): string {
  if (values.length === 0) return '[]';
  return `[${values.map(yamlString).join(', ')}]`;
}

/**
 * A workspace-relative path, by `DraftFile`'s rule and no other: relative
 * (no leading `/`, no `X:` drive form), and no empty, `.` or `..` segment —
 * checked against BOTH separators, because the backend does and a draft file
 * is portable. Control characters are handled by `yamlString` on the way out;
 * they are refused here too, so a path that could never survive validation is
 * never put in the buffer in the first place.
 *
 * The point of mirroring the rule is that a single bad path REFUSES THE WHOLE
 * DRAFT backend-side (`invalid_draft`) — so a forward that hoovered up one
 * malformed frontmatter path would make the message unsendable, with an error
 * naming neither the file nor the fix.
 */
export function isWorkspaceRelativePath(path: string): boolean {
  if (path.trim() === '') return false;
  // eslint-disable-next-line no-control-regex -- refusing control characters IS the rule
  if (/[\u0000-\u001f\u007f]/.test(path)) return false;
  if (path.startsWith('/') || /^[A-Za-z]:/.test(path)) return false;
  return path
    .split(/[/\\]/)
    .every((segment) => segment !== '' && segment !== '.' && segment !== '..');
}

/** The name a human recognizes an attachment by: its basename, either separator. */
export function attachmentName(path: string): string {
  const segments = path.split(/[/\\]/);
  return segments[segments.length - 1] || path;
}

/**
 * `path` appended to `list` — refused when it is not a workspace-relative
 * path, and idempotent, so the same file cannot be attached twice by
 * clicking twice. (The BACKEND deliberately keeps duplicates a draft file
 * actually lists; this is the picker declining to create one.)
 */
export function withAttachment(list: string[], path: string): string[] {
  const trimmed = path.trim();
  if (!isWorkspaceRelativePath(trimmed) || list.includes(trimmed)) return list;
  return [...list, trimmed];
}

/** `path` removed from `list` — every occurrence, so a hand-written duplicate detaches in one click. */
export function withoutAttachment(list: string[], path: string): string[] {
  return list.filter((entry) => entry !== path);
}

/**
 * The draft file bytes for `fields` — `DraftFile`'s frontmatter grammar in
 * its own key order (`to`, `cc`, `bcc`, `subject`, `in_reply_to`,
 * `attachments`), the `---` terminator, then the body VERBATIM.
 *
 * `attachments:` is omitted entirely when there is none, so a draft with no
 * attachments renders exactly the bytes this function has always rendered —
 * nothing about the existing corpus of drafts moves.
 *
 * Two deliberate omissions:
 *
 *   * **No `status:`.** It is engine-owned (`stamp_status/2` writes it, the
 *     push/send flows corroborate it against the ledger); absent means
 *     `draft`, which is the only state `write_mail_draft` accepts anyway. A
 *     composer that re-stamped it would be asserting an engine fact it has no
 *     standing to assert.
 *   * **No `from:`.** There is no such field — the sending identity is
 *     config-owned (`Settings.smtp.from`), and a `from:` key rejects like any
 *     other unknown one.
 *
 * The body is not normalized in any way (no trailing newline added, no
 * trimming): `parseDraftFields(draftContent(f))` must return `f` unchanged,
 * or every reopen of a draft would show up as an unsaved change.
 */
export function draftContent(fields: DraftFields): string {
  const lines = [
    '---',
    `to: ${yamlList(fields.to)}`,
    `cc: ${yamlList(fields.cc)}`,
    `bcc: ${yamlList(fields.bcc)}`,
    `subject: ${yamlString(fields.subject)}`
  ];

  const inReplyTo = fields.inReplyTo?.trim();
  if (inReplyTo) lines.push(`in_reply_to: ${yamlString(inReplyTo)}`);
  if (fields.attachments.length > 0) {
    lines.push(`attachments: ${yamlList(fields.attachments)}`);
  }
  lines.push('---');

  return `${lines.join('\n')}\n${fields.body}`;
}

// -- reading a draft file back ------------------------------------------------

/**
 * Why a draft could not be loaded into the FORM (it can still be shown
 * read-only):
 *
 *   * `no_frontmatter` — no leading `---` block at all (`DraftFile` refuses
 *     it too, so the file is not a valid draft in the first place).
 *   * `unsupported` — frontmatter this parser will not claim to understand:
 *     an unknown key, a duplicate key, a comment, a nested mapping, an
 *     ambiguous unquoted scalar. Editing it would mean re-rendering it from a
 *     guess.
 */
export type DraftParseRefusal = 'no_frontmatter' | 'unsupported';

export type DraftParse = { ok: true; fields: DraftFields } | { ok: false; reason: DraftParseRefusal };

const ALLOWED_KEYS = new Set([
  'to',
  'cc',
  'bcc',
  'subject',
  'in_reply_to',
  'attachments',
  'status'
]);

/**
 * YAML indicators that change what a plain scalar MEANS when they lead it
 * (anchors, aliases, tags, block scalars, directives, flow collections,
 * reserved). An unquoted value starting with one of these is refused rather
 * than read literally — `@` is in here too, which costs nothing: an address
 * never starts with it.
 */
const RESERVED_FIRST = new Set(['&', '*', '!', '|', '>', '%', '@', '`', '{', '}', '[', ']', ',', '#', '"', "'"]);

type Scalar = { ok: true; value: string | null } | { ok: false };

const REFUSED: Scalar = { ok: false };

/**
 * Parses ONE plain/quoted YAML scalar. `null` is the YAML null (an empty
 * value, `null`, `~`) — the caller decides what absence means for its key.
 *
 * Double-quoted strings accept only the two escapes this module's own
 * renderer emits (`\\`, `\"`); anything else (`\n`, `é`, a dangling
 * backslash) is refused rather than decoded by a second, subtly different
 * implementation of YAML's escape table.
 */
function parseScalar(raw: string): Scalar {
  const text = raw.trim();
  if (text === '' || text === 'null' || text === '~') return { ok: true, value: null };

  if (text.startsWith('"')) {
    if (text.length < 2 || !text.endsWith('"')) return REFUSED;
    const inner = text.slice(1, -1);
    let out = '';
    for (let i = 0; i < inner.length; i++) {
      const ch = inner[i];
      if (ch === '"') return REFUSED; // an unescaped quote closed the scalar early
      if (ch !== '\\') {
        out += ch;
        continue;
      }
      const next = inner[i + 1];
      if (next !== '\\' && next !== '"') return REFUSED;
      out += next;
      i++;
    }
    return { ok: true, value: out };
  }

  if (text.startsWith("'")) {
    if (text.length < 2 || !text.endsWith("'")) return REFUSED;
    const inner = text.slice(1, -1);
    // YAML's single-quote escape is a doubled quote; a lone one closed early.
    if (/(^|[^'])'($|[^'])/.test(inner)) return REFUSED;
    return { ok: true, value: inner.replace(/''/g, "'") };
  }

  if (RESERVED_FIRST.has(text[0])) return REFUSED;
  // A trailing comment, or a nested mapping ("subject: Re: hi" — which YAML
  // itself rejects). Either way this is not a value we can re-render.
  if (text.includes(' #') || text.includes(': ') || text.endsWith(':')) return REFUSED;
  return { ok: true, value: text };
}

/** Splits a flow sequence's interior at top-level commas — quotes hold. */
function splitFlowItems(inner: string): string[] | null {
  const items: string[] = [];
  let current = '';
  let quote: '"' | "'" | null = null;

  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (quote === '"' && ch === '\\') {
      current += ch + (inner[i + 1] ?? '');
      i++;
      continue;
    }
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === ',') {
      items.push(current);
      current = '';
      continue;
    }
    if (ch === '[' || ch === ']' || ch === '{' || ch === '}') return null; // nested collection
    current += ch;
  }
  if (quote) return null;
  items.push(current);
  return items;
}

type Value = { ok: true; value: string | string[] | null } | { ok: false };

function parseValue(raw: string): Value {
  const text = raw.trim();
  if (!text.startsWith('[')) return parseScalar(text);
  if (!text.endsWith(']')) return REFUSED;

  const inner = text.slice(1, -1).trim();
  if (inner === '') return { ok: true, value: [] };

  const items = splitFlowItems(inner);
  if (!items) return REFUSED;

  const out: string[] = [];
  for (const item of items) {
    const scalar = parseScalar(item);
    if (!scalar.ok || scalar.value === null) return REFUSED;
    out.push(scalar.value);
  }
  return { ok: true, value: out };
}

/** `DraftFile.coerce_list/2`'s rule: absent is `[]`, a bare string is a one-element list. */
function asList(value: string | string[] | null | undefined): string[] {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

function asScalar(value: string | string[] | null | undefined): string | null {
  if (typeof value === 'string') return value;
  return null;
}

/**
 * Loads a draft FILE into composer fields, or refuses (see
 * `DraftParseRefusal`). Conservative by construction — the composer rewrites
 * the whole file on save, so any frontmatter this cannot reproduce faithfully
 * must not be opened for editing at all.
 *
 * The frontmatter split mirrors `DraftFile.split_frontmatter/1` exactly
 * (leading `---\n`, first `\n---\n` terminates), so a body containing `---`
 * is body, here as there.
 */
export function parseDraftFields(content: string): DraftParse {
  if (!content.startsWith('---\n')) return { ok: false, reason: 'no_frontmatter' };

  const rest = content.slice(4);
  const end = rest.indexOf('\n---\n');
  if (end === -1) return { ok: false, reason: 'no_frontmatter' };

  const block = rest.slice(0, end);
  const body = rest.slice(end + 5);
  const found = new Map<string, string | string[] | null>();
  const lines = block.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '') continue;

    const match = /^([A-Za-z_][A-Za-z0-9_]*):(.*)$/.exec(line);
    if (!match) return { ok: false, reason: 'unsupported' };

    const key = match[1];
    // An unknown key is not merely unreadable — `DraftFile.check_known_keys/1`
    // refuses the whole file over it, so this draft is invalid on disk today.
    if (!ALLOWED_KEYS.has(key) || found.has(key)) return { ok: false, reason: 'unsupported' };

    // A block sequence under the key ("to:\n  - a@x.com"), if any.
    const items: string[] = [];
    while (i + 1 < lines.length && /^\s*-\s+\S/.test(lines[i + 1])) {
      items.push(lines[++i].replace(/^\s*-\s+/, ''));
    }

    if (items.length > 0) {
      if (match[2].trim() !== '') return { ok: false, reason: 'unsupported' };
      const parsed: string[] = [];
      for (const item of items) {
        const scalar = parseScalar(item);
        if (!scalar.ok || scalar.value === null) return { ok: false, reason: 'unsupported' };
        parsed.push(scalar.value);
      }
      found.set(key, parsed);
      continue;
    }

    const value = parseValue(match[2]);
    if (!value.ok) return { ok: false, reason: 'unsupported' };
    found.set(key, value.value);
  }

  const inReplyTo = asScalar(found.get('in_reply_to'))?.trim() ?? '';

  return {
    ok: true,
    fields: {
      to: asList(found.get('to')),
      cc: asList(found.get('cc')),
      bcc: asList(found.get('bcc')),
      subject: asScalar(found.get('subject')) ?? '',
      // `status` is deliberately dropped: it is engine-owned, `draftContent`
      // never writes it, and only a `draft`-state file is editable anyway.
      inReplyTo: inReplyTo === '' ? null : inReplyTo,
      // Kept verbatim, duplicates and all — `DraftFile` validates these paths
      // and re-resolves them at every use, and an editor that quietly dropped
      // one would be detaching a file the user never detached.
      attachments: asList(found.get('attachments')),
      body
    }
  };
}

/**
 * One draft file, as an editor needs it: the parsed fields (or the refusal)
 * AND the **baseline** its unsaved-changes comparison must use.
 *
 * The baseline is `draftContent(fields)`, NOT the bytes on disk, and the
 * difference is the whole point of this function. Draft files are mostly
 * agent-written: `to: [a@x.com]` unquoted, a block sequence, another key
 * order, a `status:` line the engine stamped (`DraftFile.stamp_status/2`
 * leaves one behind after a failed send returns the draft to `draft` — the
 * exact state the composer offers to edit). All of those parse cleanly and
 * re-render to something byte-DIFFERENT, so comparing the buffer against the
 * disk bytes would open every such draft already "dirty": Save armed, an
 * unsaved-changes warning, and a leave dialog claiming work would be lost
 * when nothing was typed.
 *
 * Comparing against this module's own rendering asks the question the editor
 * actually means — "has the user changed anything?" — and re-rendering a
 * draft with no edits is a no-op the user never sees. The CAS is unaffected:
 * `base_hash` is bound to the DISK bytes by the caller, which is what
 * `write_mail_draft` compares against.
 *
 * A refused draft keeps the raw bytes as its baseline: it opens read-only, so
 * nothing can make it dirty either way.
 */
export type LoadedDraft =
  | { ok: true; fields: DraftFields; baseline: string }
  | { ok: false; reason: DraftParseRefusal; baseline: string };

export function loadDraftFields(content: string): LoadedDraft {
  const parsed = parseDraftFields(content);
  if (!parsed.ok) return { ok: false, reason: parsed.reason, baseline: content };
  return { ok: true, fields: parsed.fields, baseline: draftContent(parsed.fields) };
}

// -- the recipient text fields ------------------------------------------------

/**
 * Splits what the user typed into one To/Cc/Bcc field into mailbox strings.
 * Commas and newlines separate — except inside a quoted display name, so
 * `"Public, John Q." <j@x.com>` survives the round trip through a text input
 * that a naive `split(',')` would cut in half.
 */
export function parseAddressList(input: string): string[] {
  const out: string[] = [];
  let current = '';
  let quoted = false;

  for (let i = 0; i < input.length; i++) {
    const ch = input[i];
    if (quoted && ch === '\\') {
      current += ch + (input[i + 1] ?? '');
      i++;
      continue;
    }
    if (ch === '"') {
      quoted = !quoted;
      current += ch;
      continue;
    }
    if (!quoted && (ch === ',' || ch === '\n' || ch === ';')) {
      out.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  out.push(current);

  return out.map((entry) => entry.trim()).filter((entry) => entry !== '');
}

/** The single-line rendering of a mailbox list for a To/Cc/Bcc input. */
export function formatAddressList(list: string[]): string {
  return list.join(', ');
}

/** RFC 5322 specials that force a display name to be quoted — `DraftFile`'s `@display_specials`. */
const DISPLAY_SPECIALS = ['(', ')', '<', '>', '[', ']', ':', ';', '@', '\\', ',', '"'];

/**
 * One mailbox as a draft-file string: `email` when there is no display name,
 * `Name <email>` otherwise, with the name quoted (and `\`/`"` escaped) when
 * it carries a special — exactly the two forms `DraftFile.parse_mailbox/1`
 * accepts.
 */
export function formatMailbox(addr: Mailbox): string {
  const email = addr.email.trim();
  const name = addr.name?.trim() ?? '';
  if (email === '') return '';
  if (name === '') return email;

  const needsQuotes = DISPLAY_SPECIALS.some((special) => name.includes(special));
  const display = needsQuotes ? `"${name.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"` : name;
  return `${display} <${email}>`;
}

// -- reply / reply-all / forward prefill --------------------------------------

/** The open message, as the read pane holds it (`MailMessageDetail`). */
export type ComposeSource = {
  frontmatter: Record<string, unknown> | null | undefined;
  body: string;
};

const RE_PREFIX = /^\s*re\s*:/i;
// `Fw:`, `Fwd:` and `Forward:` all count as already-prefixed — other clients
// write all three, and stacking `Fwd: Fw: …` helps nobody.
const FWD_PREFIX = /^\s*(fwd?|forward)\s*:/i;

/**
 * `Re: <subject>`, idempotently: an existing `Re:` (in any case, with or
 * without a space) is left alone. A blank subject stays blank — a lone `Re:`
 * is not a subject, and the composer's field should invite one rather than
 * pretend it has one.
 */
export function replySubject(subject: string): string {
  const text = subject.trim();
  if (text === '') return '';
  return RE_PREFIX.test(text) ? text : `Re: ${text}`;
}

/** `Fwd: <subject>`, idempotently (see `replySubject`). */
export function forwardSubject(subject: string): string {
  const text = subject.trim();
  if (text === '') return '';
  return FWD_PREFIX.test(text) ? text : `Fwd: ${text}`;
}

/**
 * The `> `-quoted form of a plain-text body. Empty lines quote as a bare `>`
 * (no trailing space), CRLF normalizes to LF, and trailing blank lines are
 * dropped so a reply doesn't open with a column of empty quote markers.
 */
export function quoteBody(body: string): string {
  const text = body.replace(/\r\n/g, '\n').replace(/\s+$/, '');
  if (text === '') return '';
  return text
    .split('\n')
    .map((line) => (line.trim() === '' ? '>' : `> ${line}`))
    .join('\n');
}

function toMailbox(raw: RawAddress): Mailbox | null {
  const email = addressEmail(raw);
  if (email === '') return null;
  const name = addressName(raw);
  return { name: name === '' ? null : name, email };
}

function mailboxList(raw: unknown): Mailbox[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry) => {
    const mailbox = toMailbox(entry as RawAddress);
    return mailbox ? [mailbox] : [];
  });
}

/** Case-insensitive de-dup by address, first occurrence wins (so To beats Cc). */
function dedupe(list: Mailbox[], seen: Set<string>): Mailbox[] {
  const out: Mailbox[] = [];
  for (const mailbox of list) {
    const key = mailbox.email.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(mailbox);
  }
  return out;
}

function withoutOwn(list: Mailbox[], ownAddress: string | null): Mailbox[] {
  const own = ownAddress?.trim().toLowerCase();
  if (!own) return list;
  return list.filter((mailbox) => mailbox.email.toLowerCase() !== own);
}

function attribution(from: Mailbox | null, date: string | null): string {
  const who = from ? formatMailbox(from) : 'someone';
  const when = formatDateTime(date);
  return when ? `On ${when}, ${who} wrote:` : `${who} wrote:`;
}

/**
 * The forwarded message's own LANDED attachment paths, re-referenced rather
 * than copied: they are already workspace files
 * (`sources/mail/<account>/views/attachments/<msg_id>/<file>`, written by
 * `Valea.Mail.Views`), which is exactly the address a draft's `attachments:`
 * takes. Forwarding therefore costs no bytes on disk and no upload.
 *
 * Filtered through `isWorkspaceRelativePath` even though these paths come
 * from Valea's own view files: one path this composer cannot vouch for would
 * refuse the WHOLE draft backend-side, and losing an attachment from a
 * forward is a smaller failure than a draft that will not save.
 */
function forwardAttachments(frontmatter: Record<string, unknown>): string[] {
  const paths = attachmentsFromFrontmatter(frontmatter).map((entry) => entry.path);
  return paths.filter(isWorkspaceRelativePath);
}

const FORWARD_SEPARATOR = '---------- Forwarded message ----------';

function forwardBody(frontmatter: Record<string, unknown>, body: string): string {
  const from = addressLabel(frontmatter.from as RawAddress);
  const date = formatDateTime(typeof frontmatter.date === 'string' ? frontmatter.date : null);
  const subject = typeof frontmatter.subject === 'string' ? frontmatter.subject.trim() : '';
  const to = addressListLabel(frontmatter.to);

  const headers = [
    from ? `From: ${from}` : '',
    date ? `Date: ${date}` : '',
    subject ? `Subject: ${subject}` : '',
    to ? `To: ${to}` : ''
  ].filter((line) => line !== '');

  // Forwarded text is NOT quoted (design spec §Compose UI) — it is the
  // message being handed on, not something being replied to.
  const original = body.replace(/\r\n/g, '\n').replace(/\s+$/, '');
  return `\n\n${FORWARD_SEPARATOR}\n${headers.join('\n')}\n\n${original}\n`;
}

/**
 * The composer's starting fields for a reply / reply-all / forward off the
 * open message.
 *
 * Recipients (design spec §Compose UI: "reply → `reply_to || from`;
 * reply-all → from + to minus the account's own address"):
 *
 *   * **reply** — the sender alone (`reply_to` when the message named one).
 *   * **reply-all** — the sender in To, everyone the message was addressed to
 *     in Cc, minus your own address and minus anyone already in To. Splitting
 *     them that way (rather than one flat To) keeps the answer pointed at the
 *     person who wrote, with the room merely kept in the loop.
 *   * **forward** — nobody; the user picks.
 *
 * There is deliberately no Cc source beyond the message's `to`: a landed
 * message view carries no `cc:` field at all (`Valea.Mail.MessageFile`'s
 * field order is the whole grammar), so reply-all is `from + to` because
 * that is everything the file knows.
 *
 * `ownAddress` removal has one exception, which is the point of the fallback
 * at the end: replying to a message you sent yourself would otherwise address
 * nobody. When the filter empties the whole set, the sender goes back in.
 */
export function replyPrefill(source: ComposeSource, ownAddress: string | null, mode: ComposeMode): DraftFields {
  const frontmatter = source.frontmatter ?? {};
  const from = toMailbox(frontmatter.from as RawAddress);
  const replyTo = toMailbox(frontmatter.reply_to as RawAddress);
  const primary = replyTo ?? from;
  const subject = typeof frontmatter.subject === 'string' ? frontmatter.subject : '';
  const date = typeof frontmatter.date === 'string' ? frontmatter.date : null;
  const msgId = typeof frontmatter.id === 'string' && MSG_ID_RE.test(frontmatter.id) ? frontmatter.id : null;

  if (mode === 'forward') {
    return {
      to: [],
      cc: [],
      bcc: [],
      subject: forwardSubject(subject),
      // A forward starts a new conversation with a new audience; threading it
      // into the original would file it under a thread its recipients cannot see.
      inReplyTo: null,
      attachments: forwardAttachments(frontmatter),
      body: forwardBody(frontmatter, source.body)
    };
  }

  const seen = new Set<string>();
  const to = dedupe(withoutOwn(primary ? [primary] : [], ownAddress), seen);
  const cc =
    mode === 'replyAll' ? dedupe(withoutOwn(mailboxList(frontmatter.to), ownAddress), seen) : [];

  if (to.length === 0 && cc.length > 0) to.push(cc.shift() as Mailbox);
  if (to.length === 0 && primary) to.push(primary);

  return {
    to: to.map(formatMailbox),
    cc: cc.map(formatMailbox),
    bcc: [],
    subject: replySubject(subject),
    inReplyTo: msgId,
    // A reply carries none: the person you are answering already has their own
    // files, and re-sending them is noise. Forward is the mode that hands
    // material on, and it is the only one that re-references it.
    attachments: [],
    body: `\n\n${attribution(from, date)}\n\n${quoteBody(source.body)}\n`
  };
}

// -- the leave contract -------------------------------------------------------

/**
 * Whether a composer buffer differs from what was last written. The saved
 * baseline is `loadDraftFields`' rendering, never the raw disk bytes (see
 * there); `null` means the draft has no file yet, so "changed" is simply
 * "holds anything".
 *
 * Shared by the editor's own `dirty` and by `flushAction` below, because a
 * flush that disagreed with the UI about what counts as unsaved work is
 * exactly how a buffer gets dropped without anyone noticing.
 */
export function draftDirty(fields: DraftFields, savedContent: string | null): boolean {
  return savedContent === null ? hasDraftContent(fields) : draftContent(fields) !== savedContent;
}

/**
 * What to do with a buffer whose editor is going away — the pure half of the
 * leave contract, so the rule is testable even though its two triggers (an
 * effect cleanup, an unmount) are not.
 *
 * `stash` and `save` are deliberately different answers to the same event:
 * an existing draft is a file the user already committed to, so it is written
 * (CAS-bound — a base hash the disk has moved past is refused); a buffer with
 * no file yet is kept in memory, because minting a draft out of an event the
 * user did not cause is a side effect that outlives the session.
 */
export type FlushAction =
  | { kind: 'none' }
  | { kind: 'stash'; fields: DraftFields }
  | { kind: 'save'; name: string; content: string };

export function flushAction(state: {
  /** The user answered "Discard and leave" — their decision, not to be undone. */
  discarded: boolean;
  /** Locked by the ledger, or frontmatter this editor cannot rewrite: not ours to write. */
  readOnly: boolean;
  name: string | null;
  savedContent: string | null;
  fields: DraftFields;
}): FlushAction {
  if (state.discarded || state.readOnly) return { kind: 'none' };
  if (!draftDirty(state.fields, state.savedContent)) return { kind: 'none' };
  if (state.name === null) return { kind: 'stash', fields: state.fields };
  return { kind: 'save', name: state.name, content: draftContent(state.fields) };
}

// -- composer plumbing --------------------------------------------------------

/**
 * Where the composer lives: `?compose=new` for a fresh draft, `?compose=<name>`
 * to reopen an existing one. Account-qualified for the same reason
 * `messageHref` is — a draft name is only unique within its account, so a
 * bare `?compose=` link means "this name, in whichever account happens to be
 * selected".
 */
export function composeHref(account: string | null, draftName: string | null): string {
  const params = new URLSearchParams();
  if (account) params.set('account', account);
  params.set('compose', draftName ?? 'new');
  return `/mail?${params.toString()}`;
}

/**
 * What stops a Save before it is attempted. Only the rule whose refusal the
 * backend cannot explain usefully in situ (`invalid_draft` covers everything
 * from a missing recipient to a malformed address); everything else is left
 * to `DraftFile`, which is the authority.
 */
export function composeValidationError(fields: DraftFields): string | null {
  if (fields.to.length === 0) return 'Add at least one address in To.';
  return null;
}

/** Error copy for `write_mail_draft`. */
export function saveErrorMessage(code: string): string {
  switch (code) {
    case 'content_changed':
      return 'This draft changed on disk since you opened it — your assistant may have edited it. Reload it, then save again.';
    case 'draft_busy':
      return "This draft can't be edited: it has already been sent, or a push or send is in flight.";
    case 'invalid_draft':
      return "The draft couldn't be validated. Check the addresses in To, Cc and Bcc.";
    case 'link_unsafe':
      return 'This draft file is not a regular file and cannot be written.';
    case 'write_failed':
      return "The draft couldn't be written to disk.";
    case 'not_found':
      return 'This draft no longer exists.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    default:
      return 'Could not save the draft. Please try again.';
  }
}

/**
 * One-shot handoff of composer fields — `stores/initial-prompt.ts`'s pattern,
 * and its reasoning: module-level state survives SPA navigation, intentionally
 * does NOT survive a reload (a reloaded `?compose=new` is simply an empty
 * composer, which is safe), and a quoted message body never touches the URL.
 *
 * Two producers, both handing over fields that exist only in memory:
 *
 *   * the read pane's Reply/Reply-all/Forward, before navigating;
 *   * `ComposeView`'s unmount flush, for a buffer that has no draft FILE yet
 *     (`?compose=new`) — stashing it costs nothing and mints nothing, where
 *     saving it would create a draft the user never asked to exist.
 *
 * Account-keyed, and a mismatch takes NOTHING and leaves the stash alone: the
 * unmount this exists for is an account switch, and dropping the buffer as the
 * other account's composer mounts would lose exactly what was just rescued.
 * One slot — a newer stash replaces an older one, and everything dies on
 * reload.
 */
let pendingPrefill: { account: string; fields: DraftFields } | null = null;

export function setComposePrefill(account: string, fields: DraftFields): void {
  pendingPrefill = { account, fields };
}

/** Takes the pending prefill for `account` — once. Another account's stash is left where it is. */
export function takeComposePrefill(account: string): DraftFields | null {
  if (pendingPrefill?.account !== account) return null;
  const { fields } = pendingPrefill;
  pendingPrefill = null;
  return fields;
}
