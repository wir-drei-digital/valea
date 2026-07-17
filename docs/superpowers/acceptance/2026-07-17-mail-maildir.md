# Mail as maildir (Spec E) — live acceptance checklist

Manual checks against real servers, executed by the user AFTER merge. The
automated suite covers every contract against the model/fake transports;
this list is the part only a live IMAP server can prove. Spec:
`docs/superpowers/specs/2026-07-17-mail-maildir-design.md`.

Conventions: `WS` = the open workspace root. Fill every **Observed:** line;
a blank one means the check hasn't run. Grep-gate exemptions (documented,
not failures): `backend/test/valea/mail/settings_test.exs`'s v3-config
fixture (tests REJECTION of the old format) and `mail_rpc_test.exs`'s
`mail_inbox` 404 test (tests the action's removal).

## A. Dovecot (local, deterministic)

Start: `just mail-dev` (Dovecot on localhost:3993, TLS fixtures under
`backend/test/fixtures/tls` — see the justfile's SSL_CERT_FILE caveat).
Create two test users per `scripts/dovecot/dovecot.conf`.

### A1. Two accounts, full pull
- Steps: In Mail settings add accounts `demo1` and `demo2`
  (host `localhost`, port 3993, the two Dovecot users). Seed a few messages
  into each user's INBOX (e.g. `doveadm save` or an mail client). Sync now
  on each.
- Expected: `WS/sources/mail/demo1/maildir/INBOX/cur/` +
  `views/messages/*.md` populate per account; `.account` files written;
  the account switcher lists both; folder list shows counts;
  `backfill_complete` reaches true within the sync window; the two engines
  stay independent (bad password on demo2 must not pause demo1).
- Observed:

### A2. Declared ops file — move
- Steps: Hand-write `WS/sources/mail/demo1/ops/pending/cleanup.yaml`:
  ```yaml
  ops:
    - op: move
      msg_id: <an id from views/messages/>
      from: INBOX
      to: Archive
  ```
  Run Sync now.
- Expected: file claimed into `ops/done/<opid>.yaml` with `.result.yaml`
  `complete`; message present in Dovecot's Archive (verify with
  `doveadm mailbox status`), gone from INBOX after the ladder
  (copy→confirm→mark-deleted→targeted expunge — check Dovecot logs show NO
  bare EXPUNGE); the view's `folders:` frontmatter updates next pass.
- Observed:

### A3. UI archive/flag ops
- Steps: Open a message on `/mail`, click Archive; flag another.
- Expected: same executor path (per-op results surface errors); list
  refreshes; flags round-trip to the server (`doveadm fetch flags`).
- Observed:

### A4. Held folder on rename
- Steps: Rename a non-special Dovecot folder server-side
  (`doveadm mailbox rename`), Sync now.
- Expected: old folder HELD (badge in folder list, notice + typed-confirm
  Discard in Mail settings), local copy intact; renamed folder syncs as
  new; Discard (typed folder name) removes the held local copy only.
- Observed:

### A5. UIDVALIDITY reset drill
- Steps: Stop Dovecot; surgically reset one folder's maildir server-side
  (delete `dovecot-uidlist` in that folder / recreate the folder with the
  same messages); restart; Sync now. Then repeat for ALL folders at once.
- Expected: single folder → `folder_reset` reconciliation, no message
  loss, no duplicate views (fingerprint dedupe). All folders →
  `mailbox_replaced`, account BLOCKED (sticky across backend restart);
  Re-adopt (typed confirm) runs exactly one authorized reconciling pass;
  a second forced reset re-blocks.
- Observed:

### A6. Push a draft
- Steps: Write `WS/sources/mail/demo1/drafts/hello.md` (frontmatter
  to/subject + body). Open Drafts panel, Push to Drafts.
- Expected: state walks pushing→pushed; the MIME lands ONCE in Dovecot's
  Drafts (verify Message-ID `<valea.push.*@valea.invalid>`); editing the
  file mid-push → `content_changed`; pushing again after success is refused
  as a duplicate claim; killing the backend mid-push then restarting
  reconciles without a second copy.
- Observed:

### A7. Ops rejection surfaces
- Steps: Write an ops file with an unknown op, one with a stale msg_id
  (move something server-side first), and a symlinked ops file.
- Expected: per-op rejections with reasons in `.result.yaml`
  (`server_changed` for the stale one); the symlink is quarantined, target
  unread; nothing executed.
- Observed:

## B. Real provider (Gmail — Daniel's account)

Use an app password; sync window default 90d.

### B1. Gmail pull + archive
- Steps: Add the account with provider gmail. Sync. Archive one message
  from the UI.
- Expected: folder names are `[Gmail]/...` (archive = `[Gmail]/All Mail`,
  shown in the folders map); the archive op completes with the X-GM-MSGID
  postcondition (source label gone, message in All Mail); `[Gmail]`
  container itself never syncs as a folder.
- Observed:

### B2. Already-applied move + retry
- Steps: Archive the same message again via a hand-written ops file (it is
  already in All Mail). Then run an op while toggling networking off/on
  mid-pass.
- Expected: already-applied → op completes/rejects cleanly via
  postcondition proof, never a duplicate; the interrupted op parks and the
  next pass reconciles confirm-first (no duplicate copy, no wrong-message
  expunge).
- Observed:

### B3. Agent session boundary (spot-check)
- Steps: "Start a session about this message" on a Gmail message; in the
  session, ask the agent to read another account's mail dir and to write
  into `maildir/`.
- Expected: in-scope views readable; other account → DENIED (not asked);
  `maildir/` write → denied; `ops/pending/` write → ask/allow;
  `spool/` read → denied.
- Observed:

## C. Credential + restart drills (desktop build)

### C1. Keychain resupply
- Steps: Set up an account in the desktop app (password typed once).
  Quit + relaunch.
- Expected: keychain entry `"<workspace_id>" / "<slug>:imap"` exists;
  after relaunch the account returns to `credential: present` WITHOUT
  retyping (resupply is silent); browser dev mode instead requires
  `VALEA_MAIL_PASSWORD_<SLUG>`.
- Observed:

### C2. Restart recovery (state machine)
- Steps: With pending ops queued and one draft mid-push, kill the backend;
  relaunch; sync.
- Expected: ledger rows recover (claimed → rejected-provably-unsent or
  executed-once; executing → confirm-first reconcile); `mailbox_replaced`
  and held-folder states survive restart; no duplicate mailbox effects.
- Observed:

### C3. Non-ASCII password
- Steps: Set a password containing non-ASCII (e.g. `pässwörd£`) on a
  Dovecot user; connect through setup + keychain round-trip.
- Expected: login succeeds; resupply after restart still works (no
  encoding mangling anywhere in the chain).
- Observed:

## Known deferred items (tracked, not blockers)

- `pushed_revision_stale` advisory in the drafts list (needs an op-row
  snapshot hash retained past completion).
- Persistent push search failure parks silently (`pending` retried each
  pass) rather than escalating to a visible `needs_review`.
- `mailbox_replaced` mount degradation shares the tested
  `identity_mismatch` code path but is exercised end-to-end only by drill
  A5.
