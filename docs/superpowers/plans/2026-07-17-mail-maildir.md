# Mail as Maildir (Spec E) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Valea mail around a canonical local Maildir per account: full-account windowed mirror, declared-ops two-way sync (moves + flags, never expunge), per-account opt-in mounts, derived markdown views + SQLite index, agent drafts with user-only Push-to-Drafts.

**Architecture:** One `Valea.Mail.Engine` per configured account (Registry-keyed, under a new `Valea.Mail.Supervisor`), each running push-then-pull `SyncPass`es against `sources/mail/<account>/maildir/` (raw RFC822, engine-owned). Mutations are declared (ops files / RPC) and executed through a durable `mail_pending_ops` ledger with spool manifests and execution-time verification. Views/index are derived and rebuildable; `mail_pending_ops` is durable state. Mail areas are synthetic mounts with deny-not-ask policy for unmounted accounts.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 + AshSqlite (hand-migrated mail tables, `migrate? false`), ash_typescript codegen, SvelteKit + Svelte 5 runes + Bun/vitest, gen_smtp's `:mimemail` for MIME.

**Spec:** `docs/superpowers/specs/2026-07-17-mail-maildir-design.md` (approved @ b552af2). Where this plan and the spec disagree, the spec governs — flag it, don't improvise.

## Global Constraints

- **Never weaken containment**: every path decision through `Valea.Paths.resolve_real/2` (segment-boundary membership). No new path logic outside it.
- **No credentials on disk, ever**: keychain (FE) + RAM closures (BE). Keychain account key format: `<workspace_id>:<account>:imap` (passed as the existing `username` arg of `mail_secret_set/get/delete` — no Rust changes).
- **Moves only, never expunge**: `\Deleted` is stored ONLY via `Transport.uid_mark_deleted/2`, called ONLY from the executor's confirmed ladder; bare `EXPUNGE` appears nowhere (`uid_expunge/2` is always targeted); `T`/`D` flags are pull-only; pushable flags are exactly `S`/`R`/`F`.
- **Valea cannot send mail**: no SMTP anywhere. Outbound = user-only `push_draft_to_mailbox`.
- **Agent-writable mail surface is exactly** `ops/pending/` **and** `drafts/`; `spool/` is deny-all (read+write); everything else in a mail mount is read-only to agents. Deny matching casefolds (APFS).
- **Account slug grammar**: `^[a-z0-9][a-z0-9-]{0,31}$`, casefold-unique, validated at RPC, config load, mount creation, purge. Never path-interpolated unvalidated.
- **TLS mandatory + verified** (existing `ImapClient` posture; only trust-root overridable, tests only).
- **No backwards compatibility**: `config/mail.yaml` v3 and the old `sources/mail` layout are replaced. Delete old machinery outright; no shims.
- **Falsy-field rule**: any RPC typed-map field that can be `false`/`0` at the top level uses a STRING key in the return map (ash_typescript 0.17.3 falsy bug — see `Valea.Api.Mail` current code for the pattern).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Never push to origin.
- Suite gate: `just test` (backend → codegen freshness → `bun run check` → `bun run test`). Any task that touches an `Api.*` rpc_action MUST run `cd backend && mix ash_typescript.codegen` and commit the regenerated `frontend/src/lib/api/` in the same commit.
- Backend tests that open workspaces use `Valea.AgentCase.open_workspace!/1` (async: false). Mail unit tests follow existing patterns in `backend/test/valea/mail/` (tmp dirs + `start_supervised!({Valea.Repo, database: <dir>/app.sqlite, pool_size: 1})`).

## File Structure (end state)

```
backend/lib/valea/mail/
  maildir.ex           # NEW  pure: filename codec, flags, folder<->dir mapping, delivery
  settings.ex          # REWRITE  v4 multi-account (+ slug validation, provider detection)
  account.ex           # NEW  .account identity file read/write/verify
  store.ex + store/    # REWRITE  sync_state.ex, uid_map.ex (NEW), message_index.ex, pending_op.ex (NEW)
                       # DELETE   uid_outcome.ex, inbox_header.ex
  transport.ex         # EXTEND   new callbacks (flags, store, qresync, copyuid)
  imap_client.ex       # EXTEND   implement new callbacks (+ X-GM-MSGID)
  views.ex             # NEW  derived md views + attachments + GC
  index.ex             # REWRITE  rebuild from maildir/ scan
  sync_pass.ex         # REWRITE  push(ops)-then-pull per account
  reconcile.ex         # NEW  reset/replacement/folder-lifecycle reconciliation
  ops_file.ex          # NEW  ops YAML parse + occurrence validation + claim/result files
  ops_executor.ex      # NEW  ledger executor (moves/appends/flags, manifests, verification)
  draft_file.ex        # NEW  draft frontmatter validation (RFC 5322 parse, CR/LF/NUL rejection)
  draft_mime.ex        # RESURRECT+REWORK  compose from validated draft (plain-text MIME)
  engine.ex            # REWRITE  per-account (Registry-named), identity binding, held/replaced states
  supervisor.ex        # NEW  one Engine child per configured account
  doctor.ex            # EXTEND   per-account ctx + maildir_writable
  redact.ex            # KEEP
  normalizer.ex        # KEEP (message_file.ex msg_id/render change only)
backend/lib/valea/api/mail.ex          # REWRITE  account-scoped RPC surface
backend/lib/valea/mounts.ex            # EXTEND   synthetic mail mounts in list/1
backend/lib/valea/mounts/context.ex    # EXTEND   bare-string "mail-<slug>" related entries
backend/lib/valea/agents/session_scope.ex       # EXTEND  include_mounts opt
backend/lib/valea/agents/permission_policy.ex   # EXTEND  mail deny-not-ask + write-surface rules
backend/lib/valea/agents/session_settings.ex    # EXTEND  managedSettings mail mirror
backend/lib/valea/api/agents.ex        # EXTEND  create_agent_session include_mounts arg
backend/lib/valea/cockpit.ex           # EXTEND  per-account mail summary
backend/lib/valea/workspace/runtime.ex # MODIFY  Mail.Supervisor child
backend/priv/workspace_template/       # MODIFY  mail.yaml v4 skeleton; drop seed msg + inbox.md
backend/priv/repo/migrations/          # REPLACE 20260717000001_create_mail_tables.exs
backend/test/support/fake_mail_transport.ex  # EXTEND new callbacks
backend/test/support/model_mail_transport.ex # NEW stateful mailbox model (+ gmail label mode, faults)
frontend/src/lib/stores/mail.svelte.ts       # REWRITE  accounts/folders/drafts
frontend/src/lib/components/mail/*           # REWRITE/ADD  AccountSwitcher, FolderList, DraftsPanel
frontend/src/routes/mail/+page.svelte        # REWRITE
docs/ARCHITECTURE.md                          # REWRITE mail section
docs/superpowers/acceptance/2026-07-17-mail-maildir.md  # NEW checklist
```

**Deleted symbols (grep gates in T17):** `Valea.Mail.Store.UidOutcome`, `Valea.Mail.Store.InboxHeader`, `MessageFile.flip_status`, `mail_inbox` RPC, `inbox.md` generation, `sources/mail/messages` flat layout, bare `VALEA_MAIL_PASSWORD` (unsuffixed), `sync.inbox_index_limit`, `folders.review`/`folders.processed` (v3 keys).

---

### Task 1: `Valea.Mail.Maildir` — pure maildir/folder codec

**Files:**
- Create: `backend/lib/valea/mail/maildir.ex`
- Test: `backend/test/valea/mail/maildir_test.exs`

**Interfaces (Produces):**
```elixir
@type flags :: MapSet.t(String.t())   # letters: "S","R","F","T","D"
encode_filename(msg_id :: String.t(), uid :: pos_integer() | nil, flags) :: String.t()
  # "<msg_id>,U=<uid>:2,<sorted letters>"; uid nil → "<msg_id>:2,<letters>" (pre-confirmation)
parse_filename(String.t()) :: {:ok, %{msg_id: String.t(), uid: pos_integer() | nil, flags: flags}} | :error
flags_to_imap(flags) :: [String.t()]           # "S"->"\\Seen","R"->"\\Answered","F"->"\\Flagged","T"->"\\Deleted","D"->"\\Draft"
flags_from_imap([String.t()]) :: flags
pushable_flags() :: MapSet.t()                  # MapSet.new(["S","R","F"])
encode_segment(String.t()) :: String.t()        # %-escape: %, leading ".", exact "cur"/"new"/"tmp"
decode_segment(String.t()) :: String.t()
folder_to_dir(imap_name :: String.t(), taken :: MapSet.t(String.t())) :: String.t()
  # split on "/", encode each segment, join. Candidate loop until unused: base, then
  # base-<first 6 hex of sha256(imap_name)>, then -<12 hex>, -<18 hex>, … up to the full digest —
  # EVERY candidate (including suffixed ones) is checked against `taken` under casefold+NFC, so a
  # pre-existing literal dir that happens to equal a suffixed candidate cannot be reused. The caller
  # (SyncPass folder-set step) adds each assigned dir to `taken` as it walks the LIST result.
mailbox_dirs(folder_dir_abs :: String.t()) :: :ok       # mkdir -p cur/new/tmp
write_folder_identity!(folder_dir_abs, imap_name) :: :ok  # <dir>/.folder, atomic
read_folder_identity(folder_dir_abs) :: {:ok, String.t()} | :error
deliver!(folder_dir_abs, filename, bytes) :: :ok         # write <dir>/tmp/<filename>, fsync, rename to cur/
list_occurrences(folder_dir_abs) :: [%{filename: String.t(), msg_id: ..., uid: ..., flags: ...}]
```

- [ ] **Step 1: Write the failing tests** — `backend/test/valea/mail/maildir_test.exs`:

```elixir
defmodule Valea.Mail.MaildirTest do
  use ExUnit.Case, async: true
  alias Valea.Mail.Maildir

  describe "filename codec" do
    test "round-trips msg_id, uid and sorted flags" do
      name = Maildir.encode_filename("2026-07-15-alex-4f2a91c3", 42, MapSet.new(["S", "F"]))
      assert name == "2026-07-15-alex-4f2a91c3,U=42:2,FS"
      assert {:ok, %{msg_id: "2026-07-15-alex-4f2a91c3", uid: 42, flags: flags}} =
               Maildir.parse_filename(name)
      assert MapSet.equal?(flags, MapSet.new(["S", "F"]))
    end

    test "uid-less filename (pre-confirmation) round-trips" do
      name = Maildir.encode_filename("2026-07-15-alex-4f2a91c3", nil, MapSet.new())
      assert name == "2026-07-15-alex-4f2a91c3:2,"
      assert {:ok, %{uid: nil, flags: flags}} = Maildir.parse_filename(name)
      assert MapSet.size(flags) == 0
    end

    test "rejects garbage" do
      assert :error = Maildir.parse_filename("no-flags-part")
      assert :error = Maildir.parse_filename("id,U=notanum:2,S")
    end
  end

  describe "flag mapping" do
    test "letters <-> IMAP system flags, unknown IMAP flags dropped" do
      assert Maildir.flags_to_imap(MapSet.new(["S", "T"])) |> Enum.sort() ==
               ["\\Deleted", "\\Seen"]
      assert MapSet.equal?(
               Maildir.flags_from_imap(["\\Seen", "\\Answered", "$Forwarded"]),
               MapSet.new(["S", "R"])
             )
    end

    test "pushable set is exactly S/R/F" do
      assert MapSet.equal?(Maildir.pushable_flags(), MapSet.new(["S", "R", "F"]))
    end
  end

  describe "folder mapping" do
    test "escapes reserved segments, %, and leading dots reversibly" do
      for raw <- ["cur", "new", "tmp", ".hidden", "50%off", "Work/Clients"] do
        encoded = raw |> String.split("/") |> Enum.map(&Maildir.encode_segment/1)
        assert raw == encoded |> Enum.map(&Maildir.decode_segment/1) |> Enum.join("/")
        refute Enum.any?(encoded, &(&1 in ["cur", "new", "tmp"]))
      end
    end

    test "case-colliding IMAP names get distinct dirs (APFS injectivity)" do
      a = Maildir.folder_to_dir("Clients", MapSet.new())
      taken = MapSet.new([a |> String.downcase() |> :unicode.characters_to_nfc_binary()])
      b = Maildir.folder_to_dir("clients", taken)
      refute String.downcase(a) == String.downcase(b)
      assert b =~ ~r/-[0-9a-f]{6}$/
    end

    test "suffixed candidate colliding with a pre-existing literal dir extends the digest" do
      norm = fn s -> s |> String.downcase() |> :unicode.characters_to_nfc_binary() end
      first_suffix = Maildir.folder_to_dir("clients", MapSet.new([norm.("clients")]))
      taken = MapSet.new([norm.("clients"), norm.(first_suffix)])
      c = Maildir.folder_to_dir("clients", taken)
      refute norm.(c) in taken
      assert c =~ ~r/-[0-9a-f]{12}$/
    end

    test ".folder identity file is authoritative and atomic" do
      dir = Path.join(System.tmp_dir!(), "maildir-#{System.unique_integer([:positive])}")
      :ok = Maildir.mailbox_dirs(dir)
      :ok = Maildir.write_folder_identity!(dir, "Work/Clients")
      assert {:ok, "Work/Clients"} = Maildir.read_folder_identity(dir)
      assert File.dir?(Path.join(dir, "cur")) and File.dir?(Path.join(dir, "tmp"))
    end
  end

  describe "delivery" do
    test "deliver! lands via tmp/ then cur/, listable" do
      dir = Path.join(System.tmp_dir!(), "maildir-#{System.unique_integer([:positive])}")
      :ok = Maildir.mailbox_dirs(dir)
      name = Maildir.encode_filename("2026-01-01-a-deadbeef", 7, MapSet.new(["S"]))
      :ok = Maildir.deliver!(dir, name, "raw bytes")
      assert File.read!(Path.join([dir, "cur", name])) == "raw bytes"
      assert [] = Path.wildcard(Path.join([dir, "tmp", "*"]))
      assert [%{msg_id: "2026-01-01-a-deadbeef", uid: 7}] = Maildir.list_occurrences(dir)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure** — `cd backend && mix test test/valea/mail/maildir_test.exs` → FAIL (module undefined).
- [ ] **Step 3: Implement `backend/lib/valea/mail/maildir.ex`.** Notes that are contracts, not suggestions:
  - Filename regex: `~r/^(?<id>[^,:]+)(,U=(?<uid>\d+))?:2,(?<flags>[A-Za-z]*)$/`; flags sorted ascending on encode; only known letters parsed, unknown letters → `:error`.
  - `encode_segment/1`: escape `%` → `%25` FIRST, then a leading `.` → `%2E`, then whole-segment `cur|new|tmp` → escape first char (`c`→`%63`, `n`→`%6E`, `t`→`%74`). `decode_segment/1` is plain `%XX` decoding.
  - `folder_to_dir/2` collision key: `String.downcase/1` + `:unicode.characters_to_nfc_binary/1` of the encoded path. Suffix: `"-" <> (:crypto.hash(:sha256, imap_name) |> Base.encode16(case: :lower) |> binary_part(0, 6))`.
  - `deliver!/3`: write to `tmp/<filename>`, `:file.sync` via `File.open!(..., [:write, :binary])` + `:file.datasync`, then `File.rename!` into `cur/`.
  - `write_folder_identity!/2`: atomic write (tmp + rename) of the exact IMAP name, single line.
- [ ] **Step 4: Run to verify pass** — same command → all green.
- [ ] **Step 5: Commit** — `git add backend/lib/valea/mail/maildir.ex backend/test/valea/mail/maildir_test.exs && git commit -m "feat(mail): maildir filename/folder codec with APFS-injective mapping"`.

---

### Task 2: `Valea.Mail.Settings` v4 — multi-account config

**Files:**
- Rewrite: `backend/lib/valea/mail/settings.ex`
- Rewrite tests: `backend/test/valea/mail/settings_test.exs`
- Modify: `backend/priv/workspace_template/config/mail.yaml` (v4 skeleton, `accounts: {}`), delete `backend/priv/workspace_template/sources/mail/inbox.md` and `.../messages/2026-07-09-priya-nair-seed0001.md`; keep `sources/mail/` with a single `.gitkeep`.

**Interfaces (Produces):**
```elixir
defstruct slug: nil, provider: :generic,           # :generic | :gmail
          imap: %{host: nil, port: 993, username: nil},
          folders: %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"},
          sync: %{window_days: 90, interval_minutes: 15, max_message_bytes: 26_214_400, exclude_folders: []}
@type t  # one account
load(root) :: {:ok, %{String.t() => t}} | {:error, :not_configured} | {:error, {:invalid, String.t()}}
  # per-account invalidity: account omitted from the ok-map, collected under {:invalid_accounts, %{slug => reason}}
  # → concretely: {:ok, %{accounts: %{slug => t}, invalid: %{slug => String.t()}}}
valid_slug?(String.t()) :: boolean()               # ^[a-z0-9][a-z0-9-]{0,31}$
detect_provider(host :: String.t()) :: :gmail | :generic   # gmail: "imap.gmail.com", "imap.googlemail.com"
gmail_excludes() :: ["[Gmail]/All Mail", "[Gmail]/Important", "[Gmail]/Starred"]
gmail_folders() :: %{drafts: "[Gmail]/Drafts", sent: "[Gmail]/Sent Mail", archive: "[Gmail]/All Mail", trash: "[Gmail]/Trash"}
  # upsert_account! applies gmail_folders() as the folder defaults when provider == :gmail —
  # WITHOUT this the executor's Gmail archive contract (All Mail postcondition) never composes
  # for a plain imap.gmail.com setup. Test: default gmail upsert → folders.archive == "[Gmail]/All Mail".
upsert_account!(root, slug, %{host:, port:, username:, folders: map|nil, sync: map|nil}) :: :ok | {:error, term}
  # validates slug (grammar + casefold-uniqueness vs existing), detects provider, seeds gmail excludes
remove_account!(root, slug) :: :ok
render(%{String.t() => t}) :: binary()             # v4 file, safety block fixed:
  # safety:\n  never_expunge: true\n  outbound: push_drafts_only
env_credential(slug) :: String.t() | nil           # VALEA_MAIL_PASSWORD_<SLUG upcased, "-"→"_">
```

- [ ] **Step 1: Write failing tests.** Rewrite `settings_test.exs` around v4. Write one `test` block per case below — each bullet names the exact call and the exact expected value; follow the existing file's tmp-dir conventions:
  - `load/1` on template file (`accounts: {}`) → `{:ok, %{accounts: %{}, invalid: %{}}}`.
  - round-trip: `upsert_account!(root, "wirdrei", %{host: "mail.example.com", port: 993, username: "d@w.d"})` then `load` → one account, `provider: :generic`, default folders/sync, `exclude_folders: []`.
  - gmail detection: host `imap.gmail.com` → `provider: :gmail`, `sync.exclude_folders == Settings.gmail_excludes()`, `folders == Settings.gmail_folders()` (archive = `"[Gmail]/All Mail"`, never `"Archive"`).
  - slug grammar: `"../secrets"`, `"a/b"`, `"%2e%2e"`, `"A"`, `""`, 33 chars → `{:error, :invalid_slug}` from `upsert_account!`; `valid_slug?/1` false for each; true for `"personal"`, `"a"`, `"a-1"`.
  - casefold-uniqueness: with `"personal"` present, `upsert_account!(root, "Personal", ...)` is invalid by grammar already (uppercase); uniqueness is asserted via a hand-written YAML containing keys `personal` and `personaL` → `load` marks the second `invalid: %{"personaL" => reason}`.
  - hand-edited YAML with invalid slug `"../x"` → that account under `invalid`, others load; nothing raises.
  - v3-shaped file (fixture: old `account:`/`imap:` top-level keys) → `{:error, {:invalid, _}}` (no compatibility).
  - `env_credential("my-acct")` reads `VALEA_MAIL_PASSWORD_MY_ACCT`.
  - `render/1` output contains `never_expunge: true` and `outbound: push_drafts_only`; port defaults applied.
- [ ] **Step 2: Run** `mix test test/valea/mail/settings_test.exs` → FAIL.
- [ ] **Step 3: Implement.** Keep the existing atomic-write + `merge_typed` style. `load` parses `accounts:` map; each entry validated independently. Store slugs as given (already lowercase by grammar).
- [ ] **Step 4: Run to green.**
- [ ] **Step 5: Update workspace template**: new `config/mail.yaml`:

```yaml
version: 4
accounts: {}
safety:
  never_expunge: true
  outbound: push_drafts_only
```

  Remove seed message + `inbox.md`; `sources/mail/.gitkeep`. Fix `backend/test/valea/workspace/scaffold_test.exs` expectations if they reference the seed files.
- [ ] **Step 6: Run** `mix test test/valea/mail/settings_test.exs test/valea/workspace/scaffold_test.exs` → green. **Commit** `feat(mail): settings v4 — multi-account, slug grammar, provider detection`.

---

### Task 3: Store v2 — occurrence-based tables + durable ops ledger

**Files:**
- Rewrite: `backend/lib/valea/mail/store.ex`
- Rewrite: `backend/lib/valea/mail/store/sync_state.ex`, `backend/lib/valea/mail/store/message_index.ex`
- Create: `backend/lib/valea/mail/store/uid_map.ex`, `backend/lib/valea/mail/store/pending_op.ex`
- Delete: `backend/lib/valea/mail/store/uid_outcome.ex`, `backend/lib/valea/mail/store/inbox_header.ex`
- Replace migration: delete `backend/priv/repo/migrations/20260711000001_create_mail_tables.exs`, create `backend/priv/repo/migrations/20260717000001_create_mail_tables.exs`
- Rewrite tests: `backend/test/valea/mail/store_test.exs`

**Resources (all `migrate? false`, `primary_key: false` hand-migrated — copy the existing sqlite-block pattern):**

- `SyncState` (table `mail_sync_state`): `account :string pk`, `folder :string pk` (exact IMAP name), `dir :string` (local dir rel to maildir/), `uidvalidity :integer`, `high_water_uid :integer`, `highestmodseq :integer`, `backfill_complete :boolean default false`, `held :boolean default false`, `last_pass_at :string`, `last_error :string`. Actions: `:read`, `:destroy`, `create :upsert` (upsert_fields = all non-pk).
- `UidMap` (table `mail_uid_map`): `account :string pk`, `folder :string pk`, `uid :integer pk`, `uidvalidity :integer`, `msg_id :string`, `last_synced_flags :string` (sorted letters, e.g. `"FS"`). Actions `:read`, `:destroy`, `create :upsert` (upsert_fields `[:uidvalidity, :msg_id, :last_synced_flags]`).
- `MessageIndex` (table `mail_messages`) — ONE ROW PER OCCURRENCE: `account :string pk`, `folder :string pk`, `uid :integer pk`, `msg_id :string` (NOT unique), `message_id :string`, `from_name/from_email/subject/date :string`, `flags :string`, `has_attachments :boolean default false`, `path :string` (maildir file rel to workspace root), `in_reply_to :string`, `references :string`. Actions `:read`, `:destroy`, `create :upsert` (upsert_fields = all non-pk), `update :set_flags` accept `[:flags, :path]`.
- `PendingOp` (table `mail_pending_ops`): `id :string pk` (opaque, `Ash.UUID`-generated by caller), `kind :string` ("move" | "append"), `account :string`, `source_folder :string`, `target_folder :string`, `uid :integer`, `source_uidvalidity :integer`, `dest_watermark :integer`, `dest_uidvalidity :integer`, `message_id :string`, `msg_id :string`, `origin :string` (ops-file op-id ref `"ops:<opid>:<index>"` or `"rpc"` or draft rel path), `spool_path :string`, `payload_sha256 :string`, `state :string` ("claimed"|"pending"|"executing"|"rejected"|"needs_review"|"complete"), `error :string`, `inserted_at/updated_at :string`. Actions `:read`, `:destroy`, `create :create`, `update :transition` accept `[:state, :error, :uid, :dest_watermark, :dest_uidvalidity, :updated_at]`.

**Migration** — `up/0` FIRST drops the v1 leftovers so existing dev-workspace databases (which have
`20260711000001` recorded in schema_migrations and its tables present, and re-run `Ecto.Migrator.run`
on every open) boot cleanly: `drop_if_exists index(:mail_messages, [:message_id])` then
`drop_if_exists table(...)` for `mail_sync_state`, `mail_uid_outcomes`, `mail_messages`,
`mail_inbox_headers` — old cache data is worthless under the new layout, and `drop_if_exists` no-ops
on fresh DBs. Test: in the tmp-Repo setup, pre-create an old-shape `mail_sync_state` table by hand,
run the migrator, assert the new schema exists and inserts succeed. `up/0` then additionally creates: `create index(:mail_messages, [:account, :msg_id])`, `create index(:mail_uid_map, [:account, :msg_id])`, and the **atomic push claim**: `create index(:mail_pending_ops, [:account, :origin], unique: true, where: "kind = 'append' AND state NOT IN ('rejected','complete')", name: :mail_pending_ops_active_append)` (SQLite partial unique index — this is the one-non-terminal-push-per-draft constraint).

**Store API (Produces — exact signatures the engine consumes):**
```elixir
get_sync_state(account, folder) :: {:ok, map} | {:error, :not_found}
put_sync_state(account, folder, attrs :: map) :: :ok
folders(account) :: [map]                         # all sync_state rows
mark_held(account, folder, held :: boolean) :: :ok
clear_folder(account, folder) :: :ok              # sync_state + uid_map + index rows for folder
put_occurrence(account, folder, %{uid:, uidvalidity:, msg_id:, flags: MapSet}) :: :ok
delete_occurrence(account, folder, uid) :: :ok
occurrences(account, folder) :: [map]
occurrences_by_msg_id(account, msg_id) :: [map]
upsert_index_row(attrs :: map) :: :ok
delete_index_rows(account, folder) :: :ok
delete_index_row(account, folder, uid) :: :ok
list_messages(account, folder, limit \\ 100, before :: String.t() | nil) :: [map]  # date desc
message_rows_by_msg_id(account, msg_id) :: [map]
create_pending_op(attrs) :: {:ok, map} | {:error, :duplicate_active}   # rescues the unique-index violation
transition_op(id, state, extra :: map \\ %{}) :: :ok
pending_ops(account) :: [map]                     # state in claimed/pending/executing/needs_review
op_by_id(id) :: {:ok, map} | {:error, :not_found}
```

- [ ] **Step 1: Write failing tests** (rewrite `store_test.exs`; follow its existing tmp-Repo setup). Contract cases: sync-state round-trip incl. `backfill_complete`/`held`; occurrence CRUD + `occurrences_by_msg_id` across folders; index rows per occurrence with same `msg_id` in two folders both listed; `list_messages` pagination (`limit`, `before` date, desc order); `create_pending_op` twice with same `(account, origin)` kind=append non-terminal → second `{:error, :duplicate_active}`; after `transition_op(id, "complete")` a new create with same origin succeeds; `clear_folder` leaves other folders/accounts untouched.
- [ ] **Step 2: Run** `mix test test/valea/mail/store_test.exs` → FAIL. Also delete the two dead resource files + old migration now (compile forces the rewrite).
- [ ] **Step 3: Implement** resources + migration + API.
- [ ] **Step 4: Run to green** (`mix test test/valea/mail/store_test.exs`).
- [ ] **Step 5: Commit** `feat(mail): occurrence-based store + durable pending-ops ledger (hand-migrated)`.

---

### Task 4: Transport behaviour + `ImapClient` extensions

**Files:**
- Modify: `backend/lib/valea/mail/transport.ex`
- Modify: `backend/lib/valea/mail/imap_client.ex` (+ `backend/lib/valea/mail/imap/wire.ex` if FETCH attr parsing needs FLAGS/MODSEQ/X-GM-MSGID)
- Modify: `backend/test/support/fake_mail_transport.ex` (add the new callbacks — same script/log pattern)
- Test: `backend/test/valea/mail/imap_client_test.exs` (extend, uses `FakeImapServer`), `backend/test/valea/mail/fake_mail_transport_test.exs`

**Interfaces (Produces — new/changed behaviour callbacks):**
```elixir
select(conn, folder) :: {:ok, %{uidvalidity: integer, uidnext: integer | nil, highestmodseq: integer | nil}} | {:error, term}
uid_fetch_flags(conn, uid_set :: String.t()) ::
  {:ok, [%{uid: pos_integer, flags: [String.t()], modseq: integer | nil, gm_msgid: String.t() | nil}]} | {:error, term}
  # uid_set is an IMAP set string: "1:*" or "5,9,12". gm_msgid populated only when X-GM-EXT-1 capable.
uid_store_flags(conn, uid, add :: [String.t()], remove :: [String.t()], opts :: keyword) ::
  {:ok, :applied} | {:ok, :modified} | {:error, term}
  # opts[:unchangedsince] :: integer | nil → issues "UID STORE <uid> (UNCHANGEDSINCE <m>) ±FLAGS (...)";
  # a MODIFIED untagged response → {:ok, :modified} (caller treats as moved baseline)
uid_move(conn, uid, dest) :: {:ok, %{dest_uid: pos_integer | nil}} | {:error, term} | {:unsupported, String.t()}
  # NARROWED: native "UID MOVE" ONLY (COPYUID parsed from the tagged OK); servers without MOVE →
  # {:unsupported, _}. The COPY+STORE+EXPUNGE fallback ladder MOVES OUT of the client and into the
  # ops executor (Task 13), which needs per-step control to confirm-before-expunge. New primitives:
uid_copy(conn, uid, dest) :: {:ok, %{dest_uid: pos_integer | nil}} | {:error, term}
uid_mark_deleted(conn, uid) :: :ok | {:error, term}
  # the ONE sanctioned "\Deleted" STORE in the codebase — callable only by the executor's ladder
uid_expunge(conn, uid) :: :ok | {:error, term}   # targeted "UID EXPUNGE <uid>" (UIDPLUS), never bare EXPUNGE
append(conn, folder, flags, rfc822) :: {:ok, %{dest_uid: pos_integer | nil}} | {:error, term}
  # CHANGED return: APPENDUID when UIDPLUS, else nil
examine(conn, folder) :: {:ok, %{uidvalidity: integer, uidnext: integer | nil, highestmodseq: integer | nil}} | {:error, term}
  # READ-ONLY selection (IMAP EXAMINE) — required by Task 13 for write-through destination watermarks
  # and Gmail membership proofs; never alters \Recent or any server state. Implemented in ImapClient,
  # FakeMailTransport (scripted), and ModelMailTransport (Task 5).
supports?(conn, cap :: :condstore | :qresync | :move | :uidplus | :gmail) :: boolean()
```
No QRESYNC `SELECT ... (QRESYNC ...)` parameter support in this task — deletion detection uses `VANISHED` only if trivially available; the pull engine's portable path is full enumeration (`uid_search(conn, "ALL")`). QRESYNC fast-resync is an optimization the executor/pull may add later; `supports?/2` already reports it. (Spec compliance: the deletion protocol's authoritative path — complete enumeration with remove-only-on-success — is fully implemented in Task 7; `VANISHED` is the optional fast path.)

- [ ] **Step 1: Write failing wire-level tests** in `imap_client_test.exs` using `FakeImapServer` scripts: SELECT response carrying `HIGHESTMODSEQ`; `EXAMINE` issued (not SELECT) by `examine/2`; `UID FETCH 1:* (UID FLAGS MODSEQ)` parsed; `UID FETCH` with `X-GM-MSGID`; `UID STORE 5 (UNCHANGEDSINCE 99) +FLAGS (\Seen)` → tagged OK vs `[MODIFIED 5]`; `UID MOVE` tagged `OK [COPYUID 9 5 77]` → `{:ok, %{dest_uid: 77}}` and `{:unsupported, _}` without MOVE capability (no COPY fallback inside the client — assert the fake server saw no `UID COPY`); `uid_copy` → `OK [COPYUID ...]` parsed; `uid_mark_deleted` issues exactly `UID STORE <uid> +FLAGS (\Deleted)`; `uid_expunge` issues `UID EXPUNGE <uid>`; `APPEND` `OK [APPENDUID 9 101]` → `{:ok, %{dest_uid: 101}}`; capability probing.
- [ ] **Step 2: Run** `mix test test/valea/mail/imap_client_test.exs` → FAIL.
- [ ] **Step 3: Implement** client + wire parsing (extend `Wire`'s fetch-attr parser for `FLAGS`, `MODSEQ`, `X-GM-MSGID`; COPYUID/APPENDUID regex on tagged OK text). Update the two existing `uid_move` call sites' pattern matches. Update `FakeMailTransport` with pass-through scripted callbacks for every new function.
- [ ] **Step 4: Run to green** — `mix test test/valea/mail/imap_client_test.exs test/valea/mail/fake_mail_transport_test.exs`. Fix any `sync_pass_test`/`doctor_test` compile fallout from the changed returns (they still script old-shape `uid_move`/`append` — update scripts).
- [ ] **Step 5: Commit** `feat(mail): transport flags/store/copyuid/gmail extensions`.

---

### Task 5: `ModelMailTransport` — stateful fake server model

**Files:**
- Create: `backend/test/support/model_mail_transport.ex`
- Test: `backend/test/valea/mail/model_mail_transport_test.exs`

**Purpose:** the scenario suite (Tasks 7, 8, 13, 15) needs multi-pass, stateful behavior that `FakeMailTransport` scripting can't express. `ModelMailTransport` implements `Valea.Mail.Transport` over an in-memory account model in an Agent.

**Interfaces (Produces):**
```elixir
start_link(opts) # name: required per-test; model: initial_model()
# Model manipulation (test-side):
put_folder(name, folder :: String.t(), opts \\ [])           # uidvalidity: default 1
put_message(name, folder, raw :: binary, opts \\ [])          # flags: [], uid: auto (uidnext++); returns uid
delete_message(name, folder, uid)                              # server-side expunge
set_flags(name, folder, uid, flags :: [String.t()])
rename_folder(name, from, to)                                  # delete+create semantics at LIST level
reset_uidvalidity(name, folder)                                # bumps uidvalidity, re-uids all messages
messages(name, folder) :: [%{uid:, flags:, raw:}]
# Fault injection:
inject(name, fault)  # {:lost_response, fun_name} — perform the mutation, then return {:error, :closed} once
                     # {:fail, fun_name, reason}  — don't mutate, return {:error, reason} once
                     # :drop_connection            — next call errors
# Modes:
# gmail: true → LIST includes "[Gmail]/All Mail" containing EVERY message (label model);
#   uid_move INTO "[Gmail]/All Mail" removes the message from source only (no new All Mail uid);
#   uid_fetch_flags returns gm_msgid (stable per message); moves between label folders keep All Mail membership.
```
Implements all Transport callbacks incl. Task 4's. `uid_search` supports criteria: `"ALL"`, `"UID n:*"`, `"SINCE <date>"` (compares against a per-message `internal_date` opt, default now), `"HEADER Message-ID <id>"`, `"X-GM-MSGID <id>"`.

- [ ] **Step 1: Write failing tests** — model round-trip (put/select/search/fetch), uid auto-assignment + uidnext, `reset_uidvalidity` re-uids, `{:lost_response, :uid_move}` mutates-then-errors exactly once, gmail mode: All Mail lists every message, move to All Mail yields no new uid, gm_msgid stable across folders.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (single Agent holding `%{folders: %{name => %{uidvalidity:, uidnext:, messages: %{uid => msg}}}, faults: [], gmail: bool}`).
- [ ] **Step 4: Run to green.** **Step 5: Commit** `test(mail): stateful model transport with gmail label mode + fault injection`.

---

### Task 6: Fingerprint identity + derived views

**Files:**
- Modify: `backend/lib/valea/mail/message_file.ex` (msg_id from raw fingerprint; render meta changes; DELETE `flip_status/2` + `@status_re`)
- Create: `backend/lib/valea/mail/views.ex`
- Rewrite: `backend/lib/valea/mail/index.ex`
- Tests: `backend/test/valea/mail/message_file_test.exs` (adjust), `backend/test/valea/mail/views_test.exs` (new), `backend/test/valea/mail/index_test.exs` (rewrite)

**Interfaces (Produces):**
```elixir
# MessageFile changes:
fingerprint(raw :: binary) :: String.t()                    # sha256 hex lowercase of raw RFC822 bytes
msg_id(message :: Message.t(), raw :: binary) :: String.t() # "<date>-<from-slug>-<hash8>"; hash8 = first 8 of fingerprint/1
  # collision-extension stays in the caller (Views.land) trying 8/16/64 against DIFFERENT fingerprints
render(message, meta) # meta: %{msg_id:, account:, folders: [String.t()], flags: String.t(), attachments: [...]}
  # frontmatter fields: id, message_id, account, folders (yaml list), flags, from, to, subject, date,
  # in_reply_to, references, reply_to, attachments (+ notes). NO status, NO uid, NO source/source_ref.

# Valea.Mail.Views — all paths under <root>/sources/mail/<account>/
land(root, account, raw, %{msg_id_hint: nil | String.t()}) ::
  {:ok, %{msg_id: String.t(), fingerprint: String.t(), has_attachments: boolean}}
  # normalizes, computes fingerprint + msg_id (collision-extend vs stored fingerprints via a
  # sidecar map file views/.fingerprints/<msg_id> containing the fingerprint — or compare the
  # raw maildir candidate file when present), writes views/messages/<msg_id>.md +
  # views/attachments/<msg_id>/* — idempotent per msg_id (second land of same fingerprint is a no-op)
refresh_folders(root, account, msg_id, folders :: [String.t()], flags_union :: String.t()) :: :ok
  # rewrites the view frontmatter folders/flags lines (full re-render from the canonical raw is fine)
remove_occurrence(root, account, msg_id, remaining :: non_neg_integer) :: :ok
  # remaining == 0 → delete view file + attachments dir; else refresh only
view_rel_path(account, msg_id) :: String.t()                 # "sources/mail/<account>/views/messages/<msg_id>.md"

# Valea.Mail.Index (rewrite):
rebuild(root, account) :: {:ok, non_neg_integer}
  # walks maildir/ dirs; for EACH directory with a .folder identity file, reconstructs the
  # sync_state folder→dir binding FIRST (`Store.put_sync_state(account, imap_name, %{dir: ...})` with
  # backfill_complete: false, watermark nil — the next pass re-establishes them from the server),
  # then re-parses each raw file and repopulates uid_map + message index rows. The on-disk .folder
  # identities are AUTHORITATIVE for folder→dir after database loss — SyncPass consults these
  # bindings before allocating any directory, so a wiped SQLite DB with case-colliding folders and
  # a reversed LIST order reuses the existing dirs instead of minting duplicates (test exactly that).
  # Cache-only reconstruction, never touches the server.
```

- [ ] **Step 1: Write failing tests.** `message_file_test.exs`: msg_id of two DIFFERENT raw messages sharing the same `Message-ID` header differ (fingerprint identity); same bytes → same msg_id; render contains `account:`/`folders:`/`flags:` and no `status:`; `flip_status` gone (delete its tests). `views_test.exs`: land writes view + attachments; second land same bytes → no duplicate, same msg_id; two accounts isolated; `remove_occurrence` with remaining 0 deletes view+attachments, remaining 1 keeps them; `refresh_folders` updates the folders list. `index_test.exs`: seed a maildir tree (two folders, one shared-fingerprint message in both) → rebuild produces per-occurrence index rows + uid_map rows and one view.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Green** (also `mix test test/valea/mail` for fallout — `sync_pass.ex` still references old APIs; it is rewritten in Task 7, so if compile breaks, gut `sync_pass.ex` to a stub returning `{:ok, %{new_messages: 0, errors: []}}` NOW and note it in the report — Task 7 rewrites it; delete `sync_pass_test.exs` old cases in the same breath).
- [ ] **Step 5: Commit** `feat(mail): raw-fingerprint identity + derived views/index`.

---

### Task 7: Pull engine — `SyncPass` rewrite (discovery, flags, deletions)

**Files:**
- Rewrite: `backend/lib/valea/mail/sync_pass.ex`
- Create: `backend/lib/valea/mail/reconcile.ex` — **safe stub only** (Task 8 fills it):
  `folder_reset(_ctx, _folder), do: {:error, :not_implemented}` (SyncPass treats it as "remove nothing,
  emit a notice, retry next pass"); `detect_replacement/2` implemented FOR REAL here (pure:
  `:mailbox_replaced` when `"INBOX" in reset_folders or length(reset_folders) * 2 > length(mirrored)`,
  else `:ok`); `folder_lifecycle(_ctx, _listed), do: {:ok, []}` (no holds yet);
  `discard_held!(_root, _acct, _folder), do: {:error, :not_held}`
- Test: `backend/test/valea/mail/sync_pass_test.exs` (rewrite, uses `ModelMailTransport`; reset/lifecycle
  scenario tests live in Task 8 — this task tests only that a reset folder produces a notice and removes
  nothing while the stub is in place, plus `detect_replacement` unit cases)

**Interfaces:**
- Consumes: Tasks 1–6 APIs verbatim.
- Produces: `run(args) :: {:ok, %{new_messages: n, errors: [String.t()], notices: [String.t()]}} | {:error, :auth_failed} | {:error, :mailbox_replaced} | {:error, term}` where `args :: %{root:, account: String.t(), settings: Settings.t(), credential:, transport:, ops_enabled: boolean}` (`ops_enabled: false` until Task 13 wires push — pull-only pass). Internal per-folder pipeline as private functions; `notices` carries held-folder/conflict/quarantine strings for status.

**Behavior contract (each item = at least one test):**
1. **Folder set**: `list_folders` minus `settings.sync.exclude_folders` minus `\Noselect`; existing folders resolve to their directories via sync_state bindings AND the on-disk `.folder` identities (identities win — a dir whose `.folder` matches the IMAP name is reused even when sync_state is empty, i.e. after DB loss); only genuinely new folders allocate via `Maildir.folder_to_dir` (taken-set = union of sync_state `dir`s and every existing maildir directory name), `.folder` identity written before first delivery; sync_state row created.
2. **First sync of a folder**: watermark := `uidnext - 1` from SELECT (when uidnext nil: `max(uids)` from a full `uid_search("ALL")`); backfill = `uid_search("SINCE <date horizon>")` → land bodies (below); `backfill_complete` set ONLY after every windowed UID landed; a folder failing mid-backfill keeps `backfill_complete: false` and the next pass re-runs the windowed search, landing only missing UIDs.
3. **Incremental**: `uid_search("UID <hw+1>:*")` (guard the `n:*` quirk exactly like the old `above?/2`); every returned UID > watermark lands regardless of date; watermark advances to max seen.
4. **Landing an occurrence**: `uid_fetch_full` → `Views.land` (fingerprint dedupe) → `Maildir.deliver!` raw into the folder dir as `encode_filename(msg_id, uid, flags_from_imap(fetched flags))` → `Store.put_occurrence` + `upsert_index_row` + `Views.refresh_folders`. Oversized (`size > max_message_bytes` via `uid_fetch_meta`) → skipped + counted in `errors`, never retried hot (record in uid_map with msg_id `"__oversize__"` so it is not re-fetched; excluded from index).
5. **Flags pull**: when `supports?(:condstore)` and stored `highestmodseq` → `uid_fetch_flags(conn, "1:*")` filtered by `modseq > stored` (client-side filter is acceptable; CHANGEDSINCE server-side is an optimization); else full `uid_fetch_flags(conn, "<uid set of known occurrences>")`. Diff vs `last_synced_flags`: rename the maildir file to the new flag suffix, update uid_map + index row + `Views.refresh_folders`.
6. **Deletions**: authoritative path = full `uid_search("ALL")` per pass; a known uid absent from a SUCCESSFUL result → remove occurrence (file, uid_map, index row) + `Views.remove_occurrence(remaining: count of other occurrences)`. A failed/short search → remove NOTHING that pass. `highestmodseq` persisted only after deletion reconciliation.
7. **UIDVALIDITY reset (single folder)**: snapshot local occurrence list BEFORE wiping; full enumeration of the folder; candidates matched by Message-ID shortcut then fingerprint (fetch candidate bodies); matched → re-bind (new uid, file renamed to new `U=`); unmatched local after COMPLETE reconciliation → removed; reconciliation failure mid-way → nothing removed, notice, retry next pass. Then watermark/backfill re-init. (Implemented in `reconcile.ex`, Task 8 — this task calls a stub `Valea.Mail.Reconcile.folder_reset/…` that Task 8 fills; the single-folder-reset TEST lands in Task 8.)
8. **Account-wide reset**: INBOX or a majority of mirrored folders reset in one pass → `{:error, :mailbox_replaced}` before any mutation (Task 8 implements detection in `Reconcile`; this task returns it upward).
9. **Damage repair**: local occurrence file missing/renamed out-of-band (uid_map says X, `Maildir.list_occurrences` disagrees) → re-fetch from server by uid (fingerprint-verified) and restore; unknown files in `maildir/` (unparseable name or no uid_map row) → moved to `quarantine/<original name>-<unique>` + notice. Nothing inferred, nothing pushed.

- [ ] **Step 1: Write failing tests** with `ModelMailTransport` — one test per numbered contract item above, plus: multi-folder membership (same raw in INBOX + `Work`) → two occurrences, one view; two accounts isolated (distinct roots/model names); Gmail exclusion (model gmail mode + settings excludes → All Mail never mirrored); watermark-init test (folder with only old mail → second pass fetches nothing).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (pull only; `push/1` no-op behind `ops_enabled: false`).
- [ ] **Step 4: Green** — `mix test test/valea/mail/sync_pass_test.exs`. **Step 5: Commit** `feat(mail): pull mirror — UID-watermark discovery, flags, authoritative deletions`.

---

### Task 8: `Valea.Mail.Reconcile` — resets, replacement, folder lifecycle

**Files:**
- Fill: `backend/lib/valea/mail/reconcile.ex` (created as a safe stub in Task 7)
- Modify: `backend/lib/valea/mail/sync_pass.ex` (wire the real calls)
- Test: `backend/test/valea/mail/reconcile_test.exs`

**Interfaces (Produces):**
```elixir
folder_reset(ctx, folder) :: {:ok, %{rebound: n, removed: n}} | {:error, term}
  # ctx: %{conn:, transport:, root:, account:, settings:}
  # horizon-INDEPENDENT: full uid_search("ALL"), Message-ID shortcut + fingerprint confirm,
  # snapshot-first, nothing removed unless the complete reconciliation succeeded
detect_replacement(reset_folders :: [String.t()], mirrored :: [String.t()]) :: :ok | :mailbox_replaced
  # :mailbox_replaced when "INBOX" in reset_folders or length(reset) * 2 > length(mirrored)
folder_lifecycle(ctx, listed :: [String.t()]) :: {:ok, notices :: [String.t()]}
  # persisted known set = Store.folders(account) where held == false;
  # disappeared (incl. newly-excluded) → mark_held + reject that folder's pending ops + notice;
  # reappeared held folder (same IMAP name) → unheld, normal reconcile next pass;
  # NEVER deletes local data — discard is a user RPC (Task 10)
discard_held!(root, account, folder) :: :ok | {:error, :not_held}
  # removes folder dir under maildir/, uid_map + index rows, Views.remove_occurrence per msg_id
```

- [ ] **Step 1: Write failing tests** with `ModelMailTransport`: (a) reset with mail deleted server-side pre-reset → stale local occurrence removed after complete reconciliation, view GC'd when last; (b) reset with >window-old Message-ID-less still-present message (model: raw without Message-ID header, `internal_date` older than horizon) → re-bound, NOT deleted, file renamed to new uid; (c) reconciliation interrupted (`{:fail, :uid_fetch_full, :closed}` mid-way) → nothing removed, retried next pass; (d) `detect_replacement`: INBOX reset → replaced; 2 of 3 folders → replaced; 1 of 4 non-INBOX → ok; (e) mailbox_replaced pass: engine-visible error, NO local deletion happened; (f) folder disappears from LIST → held, files intact, notice; partial LIST (`{:fail, :list_folders, :closed}`) → nothing held; folder rename in model → old held + new pulls independently; (g) `discard_held!` removes exactly that folder's data.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement + wire into `SyncPass` (replace Task 7's stubs; move the folder-set/lifecycle step to call `folder_lifecycle` after a successful complete LIST).**
- [ ] **Step 4: Green** — `mix test test/valea/mail/reconcile_test.exs test/valea/mail/sync_pass_test.exs`. **Step 5: Commit** `feat(mail): reset/replacement/lifecycle reconciliation — hold, don't guess`.

---

### Task 9: Per-account `Engine` + `Valea.Mail.Supervisor` + identity binding

**Files:**
- Create: `backend/lib/valea/mail/supervisor.ex`, `backend/lib/valea/mail/account.ex`
- Rewrite: `backend/lib/valea/mail/engine.ex`
- Modify: `backend/lib/valea/workspace/runtime.ex` (swap `{Valea.Mail.Engine, cfg}` child for `{Valea.Mail.Supervisor, cfg}`), `backend/lib/valea/cockpit.ex` (per-account mail summary), `backend/lib/valea_web/channels/workspace_events_channel.ex` (events carry `account`)
- Modify: `backend/lib/valea/mail/doctor.ex` (ctx gains `account`; new `maildir_writable` check after `credential_present`: mkdir-p + touch/rm a probe file under `sources/mail/<account>/maildir/`)
- Tests: rewrite `backend/test/valea/mail/engine_test.exs`, extend `doctor_test.exs`, adjust `backend/test/valea/cockpit_test.exs`

**Interfaces (Produces):**
```elixir
# Valea.Mail.Account (.account identity file at sources/mail/<account>/.account)
write_if_absent!(root, slug, %{host:, username:}) :: :ok
verify(root, slug, %{host:, username:}) :: :ok | {:error, :identity_mismatch} | :absent
# Valea.Mail.Supervisor (Supervisor): child per valid account from Settings.load/1;
#   invalid accounts get NO engine (surfaced via status)
# Valea.Mail.Engine — Registry-named:
via(slug) :: {:via, Registry, {Valea.Mail.Registry, slug}}     # Registry started in application.ex
start_link(%{root:, generation:, account: slug, settings: Settings.t()})
status(slug) :: status_map | nil                                # nil when engine absent
statuses() :: %{slug => status_map}                             # Registry enumeration
set_credential(slug, secret) :: :ok | {:error, :not_found}
sync_now(slug) :: :ok | {:error, :not_configured | :no_credential | :inactive | :not_found | :blocked}
readopt(slug) :: :ok | {:error, :not_found | :not_blocked}
  # persists a ONE-SHOT authorization marker (engine-owned file sources/mail/<slug>/.readopt, fsynced —
  # survives DB loss) and clears the sticky state. SyncPass args gain `readopt_authorized: boolean`;
  # when true, Reconcile.detect_replacement is SKIPPED for that pass and every reset folder runs the
  # full reset reconciliation; the engine deletes .readopt only after the pass completes successfully.
  # A later, new replacement re-blocks normally. End-to-end test: INBOX reset → mailbox_replaced →
  # readopt → next pass reconciles + clears marker → forced second replacement blocks again.
reload_settings_all(root) :: :ok                                # Supervisor rehash: start/stop engines to match config
# status_map adds: account: slug, state ∈ "inactive|idle|syncing|auth_failed|identity_mismatch|mailbox_replaced",
#   pending_ops: n, held_folders: [String.t()], backfill: %{folder => boolean} | nil, notices: [String.t()]
```
**Behavior contract:**
1. Activation (per engine, on `{:workspace_opened, _, generation}`): `Account.verify` — `:absent` → `write_if_absent!` then proceed; `:identity_mismatch` → state `identity_mismatch`, NO sync, NO index rebuild, engine stays up for status only.
2. `mailbox_replaced` from a pass → sticky state; `sync_now` returns `{:error, :blocked}` until `readopt` (Task 10 RPC calls `Engine.readopt(slug)` → clears state, next pass runs reset reconciliation normally) or purge.
3. Env fallback: `Settings.env_credential(slug)` at activation only.
4. PubSub events gain account: `{:mail_status_changed, slug, status}`, `{:mail_sync_started, slug}`, `{:mail_sync_finished, slug, summary}`, `{:mail_message_upserted, slug, %{path:}}`; channel pushes add `"account" => slug` to each payload (frontend adapts in Task 11).
5. Cockpit `mail_summary/0` → list: `[%{"account" => slug, "configured" => true, "state" => s, "pending_ops" => n, "notices" => [...]}]`; `Process.whereis` guard replaced by Registry lookup; today.json `mail` key becomes this list (update `cockpit.ex` + its test; frontend cockpit.ts adapts in Task 11).
6. Single-flight + poll timer + auth_failed pause: per engine, same mechanics as today.

- [ ] **Step 1: Write failing tests** (engine_test rewrite, `open_workspace!` pattern + `Application.put_env(:valea, :mail_transport, ModelMailTransport)` with per-test named models — engine args must thread `transport` config exactly as today): two accounts → two engines, isolated statuses; `set_credential` routes by slug; identity mismatch (pre-write a different `.account`) → `identity_mismatch`, no maildir writes; `mailbox_replaced` stickiness + `readopt` clears; supervisor rehash on `reload_settings_all` after `upsert_account!`; doctor `maildir_writable` ok/failed branches; cockpit list shape.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (Registry `Valea.Mail.Registry` added to `application.ex` children — check `backend/lib/valea/application.ex`).
- [ ] **Step 4: Green** — `mix test test/valea/mail/engine_test.exs test/valea/mail/doctor_test.exs test/valea/cockpit_test.exs`. **Step 5: Commit** `feat(mail): per-account engines with identity binding + supervisor rehash`.

---

### Task 10: RPC surface rework (`Valea.Api.Mail`) + codegen

**Files:**
- Rewrite: `backend/lib/valea/api/mail.ex`
- Rewrite test: `backend/test/valea_web/mail_rpc_test.exs`
- Regenerate: `frontend/src/lib/api/ash_rpc.ts` + `ash_types.ts`; extend `frontend/src/lib/api/client.ts` wrappers (types only — store rework is Task 11; keep old wrapper names compiling by updating their signatures in the same commit)

**Actions (Produces — external snake_case names; every mutating action keeps the `generation` + `Manager.check_generation/1` guard; falsy-field STRING-key rule applies):**

| action | args | returns (typed) |
|---|---|---|
| `mail_status` | — | `accounts: {:array, :map}` (stringified per-account status incl. state/pending_ops/held_folders/notices/invalid-config reasons) |
| `setup_mail_account` | `account, host, port, username, generation` | `"saved" => true` — validates slug; `Settings.upsert_account!` + `Supervisor.reload_settings_all`; on existing subtree with mismatched `.account` → error `"identity_mismatch"` (purge first) |
| `remove_mail_account` | `account, generation` | `"removed" => true` — config removal + engine stop; files stay |
| `purge_mail_account_files` | `account, confirmation, generation` | `"purged" => true` — requires `confirmation == account`; refuses while engine running for slug unless in identity_mismatch/mailbox_replaced/removed state; `File.rm_rf!` of `sources/mail/<account>` (path built ONLY via validated slug + `Paths.resolve_real` containment assert) |
| `readopt_mail_account` | `account, confirmation, generation` | `"readopted" => true` — `confirmation == account`; `Engine.readopt(slug)` |
| `discard_held_folder` | `account, folder, confirmation, generation` | `"discarded" => true` — `confirmation == folder`; `Reconcile.discard_held!` |
| `set_mail_credential` | `account, secret (sensitive), generation` | `"accepted" => true` |
| `mail_sync_now` | `account, generation` | `"started" => true` (maps `{:error, :blocked}` → `"mailbox_replaced"`) |
| `mail_doctor` | `account, generation` | `"ok" =>, checks:` |
| `create_mail_folders` | `account, generation` | `created:` |
| `list_mail_messages` | `account, folder, limit (default 100), before (string date, optional)` | `messages: {:array, :map}` items: msg_id/from_name/from_email/subject/date/flags/has_attachments/uid/path/view_path |
| `list_mail_folders` | `account` | `folders: {:array, :map}` items: name/dir/held/message_count/backfill_complete |
| `get_mail_message` | `account, msg_id` | `"message" => %{frontmatter, body, path}` — `msg_id` MUST match `^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$` (reject otherwise), and the derived view path is contained via `Paths.resolve_real` under `sources/mail/<account>/views/messages/` before reading (tests: traversal `../`, absolute path, and a symlinked view file → all rejected) |
| `mail_apply_ops` | `account, ops (array of maps), generation` | `results: {:array, :map}` — stub in this task: returns per-op `%{"op" => i, "result" => "rejected", "reason" => "ops_executor_not_wired"}`; Task 13 replaces the body with the real executor call. Declared now so codegen churns once. |
| `push_draft_to_mailbox` | `account, draft_name, content_hash, generation` | `"state" =>` — stub: error `"not_implemented"`; Task 15 fills. |
| `list_mail_drafts` | — | `drafts: {:array, :map}` — stub: `[]`; Task 15 fills. |

DELETED: `mail_inbox`. `error_for/1` gains `:invalid_slug`, `:identity_mismatch`, `:not_held`, `:blocked` mappings.

- [ ] **Step 1: Write failing RPC tests** (rewrite `mail_rpc_test.exs` on the existing `POST /rpc/run` + token pattern; `ModelMailTransport` via app env): status lists accounts incl. an invalid-slug config entry; setup→credential→sync_now happy path per account; purge requires exact confirmation + refuses on active healthy engine; slug `../x` on setup → `"invalid_slug"`; `list_mail_messages` pagination; `get_mail_message` returns view content; removed `mail_inbox` action 404s (assert error).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.**
- [ ] **Step 4: Regenerate + wire types**: `cd backend && mix ash_typescript.codegen`; update `frontend/src/lib/api/client.ts` mail wrappers to the new signatures/field lists (mechanical; `mail.svelte.ts` may need minimal type-level patching to keep `bun run check` green — full rework is Task 11).
- [ ] **Step 5: Full gate** `just test` → green. **Commit** `feat(mail): account-scoped RPC surface + regenerated client`.

---

### Task 11: Frontend read path — accounts, folders, messages

**Files:**
- Rewrite: `frontend/src/lib/stores/mail.svelte.ts` + `frontend/src/lib/stores/mail.test.ts`
- Create: `frontend/src/lib/components/mail/AccountSwitcher.svelte`, `FolderList.svelte`
- Rewrite: `MessageList.svelte`, `MessageView.svelte` (read side only — session entry stays as-is until Task 14), `SyncStatusLine.svelte`, `SetupPanel.svelte`, `MailDoctorPanel.svelte`, `mail-shapes.ts` (+ tests), `frontend/src/routes/mail/+page.svelte`
- Modify: `frontend/src/lib/today/cockpit.ts` + `cockpit.test.ts` (mail key = per-account array; `mailSummaryLine` → per-account "state · N pending"), `frontend/src/routes/+page.svelte` mail card
- Modify: `frontend/src/lib/socket.ts` push types (payloads gain `account`)

**Contract:**
- `MailStore` state: `accounts: MailAccountStatus[]` (from `mail_status`), `selectedAccount: string | null` (defaults to first configured), `folders: MailFolder[]`, `selectedFolder: string | null` (defaults `"INBOX"`), `messages`, `selected` detail, `loading`. Methods: `refreshStatus()`, `selectAccount(slug)`, `refreshFolders()`, `selectFolder(name)`, `refreshMessages()` (uses account+folder+limit), `select(msgId)`, `syncNow(account, generation)`. Channel handlers filter by `payload.account === selectedAccount` for refreshes; status pushes upsert into `accounts` by slug. `resupplyCredential` iterates configured accounts with `credential === 'missing'`, keychain key `keychainGet(workspaceId, `${slug}:imap`)`, calls `setMailCredential(slug, secret, generation)`; self-terminating per account.
- Setup panel: account list + add/edit form with slug field (client-side regex mirror `^[a-z0-9][a-z0-9-]{0,31}$`), keychain write via `keychainSet(workspaceId, `${slug}:imap`, secret)`; per-account doctor button; surfaces `identity_mismatch` (purge CTA w/ typed confirm), `mailbox_replaced` (re-adopt/purge CTAs), held folders (per-folder discard w/ typed confirm), invalid-config accounts read-only with reason.
- Mail route: ListPane header hosts `AccountSwitcher` (select) + `FolderList` (from `list_mail_folders`, held folders badged "held"); message list per folder; view unchanged rendering (frontmatter `folders`/`flags` shown in the meta line instead of the dead `status`).
- Keep the pure-helper + injected-fake-api test conventions; every new pure helper (`accountLabel`, `folderBadge`, per-account summary line) lands in `mail-shapes.ts` with vitest cases; store tests cover account switching, event filtering by account, and multi-account resupply.

- [ ] **Step 1: Write failing vitest cases** (store + shapes + cockpit). **Step 2: Run** `cd frontend && bun run test` → FAIL.
- [ ] **Step 3: Implement** components/store/route. **Step 4:** `cd frontend && bun run check && bun run test` → green; then `just test`.
- [ ] **Step 5: Commit** `feat(mail-fe): multi-account read path — switcher, folders, per-account status`.

---

### Task 12: Ops files — parse, validate, claim, results, replay

**Files:**
- Create: `backend/lib/valea/mail/ops_file.ex`
- Test: `backend/test/valea/mail/ops_file_test.exs`

**Interfaces (Produces):**
```elixir
@type op ::
  %{op: :move, msg_id: String.t(), from: String.t(), to: String.t()} |
  %{op: :flag, msg_id: String.t(), folder: String.t(), add: [String.t()], remove: [String.t()]}
parse(yaml :: binary) :: {:ok, [op]} | {:error, String.t()}
  # closed vocabulary; unknown op/keys/flags (outside S/R/F for add+remove) → error; empty list → error
validate(op, ctx) :: :ok | {:rejected, String.t()}
  # ctx: %{account:, occurrences_by_msg_id: (msg_id -> [occ]), known_folders: MapSet, write_through: MapSet}
  # move: msg_id resolves to EXACTLY ONE occurrence in `from`; `to` ∈ known_folders ∪ write_through; to != from
  # flag: exactly one occurrence in `folder`; add/remove ⊆ pushable
claim_next(root, account) :: {:ok, %{opid: String.t(), bytes: binary(), original_name: String.t()}} | :none | {:quarantined, String.t()}
  # RETURNS THE BYTES, NOT A PATH: after the rename + re-verify, the file is OPENED no-follow
  # (`:file.open(path, [:read, :binary, :raw])`), `read_link_info` re-verified (regular, links: 1),
  # ALL bytes read from that descriptor, then closed. Parsing consumes these bytes — a hardlink
  # minted into an agent-writable dir after the check cannot swap what the executor sees.
  # `unresolved/2` replay uses the same open-verify-read helper (`read_claimed!/1`) on done-files.
  # scans ops/pending/ (oldest mtime first); LINK-SAFETY: :file.read_link_info(path) must be
  # {:ok, #file_info{type: :regular, links: 1}} — anything else → move to quarantine/, return {:quarantined, name};
  # claim = File.rename to ops/done/<opid>.yaml where opid = 26-char lowercase base32 of :crypto.strong_rand_bytes(16);
  # destination existence re-checked before rename (File.exists? → regenerate opid; rename overwrite window
  # acceptable because opid is random and ops/done is engine-owned/agent-write-denied)
write_results!(root, account, opid, original_name, results :: [map]) :: :ok
  # ops/done/<opid>.result.yaml — %{"file" => original_name, "results" => [%{"op" => i, "result" => "ok"|"rejected"|"needs_review", "reason" => _}]}
write_op_state!(root, account, opid, index :: non_neg_integer, state :: map) :: :ok
read_op_states(root, account, opid) :: %{non_neg_integer => map}
  # engine-owned, FSYNCED per-op recovery sidecar ops/done/<opid>.state.yaml, appended BEFORE each
  # flag op's remote I/O: %{folder:, uid:, uidvalidity:, baseline_flags:, modseq: int | nil,
  # postcondition: %{add:, remove:}}. This is the durable flag baseline the spec requires — recovery
  # after a lost STORE consumes it (postcondition already present → ok; baseline moved → needs_review,
  # never an overwriting STORE; untouched → one UNCHANGEDSINCE-guarded retry).
unresolved(root, account) :: [%{opid:, path:}]     # done/*.yaml lacking sibling *.result.yaml → boot replay set
```

- [ ] **Step 1: Write failing tests**: parse happy/closed-vocabulary rejections (unknown op, `delete` op, flag `T`, extra keys); validate each rule incl. multi-occurrence ambiguity → rejected; claim: regular file claimed under fresh opid + original name preserved + bytes returned; symlink in pending → quarantined, never parsed (create with `File.ln_s`); hard-linked file (`File.ln`) → quarantined; **post-claim hardlink swap** (claim, then hardlink the done-file into a writable dir and overwrite through the link AFTER claim returns → the returned bytes are the pre-swap content, and `read_claimed!/1` on replay detects links > 1 and refuses with a notice); pending file named identically to an existing done file → fresh opid, nothing overwritten; results file round-trip; `unresolved/2` finds claimed-without-result only.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Green.** **Step 5: Commit** `feat(mail): declared-ops files — closed vocabulary, link-safe opaque claiming`.

---

### Task 13: Ops executor — ledger, manifests, verification, push wiring

**Files:**
- Create: `backend/lib/valea/mail/ops_executor.ex`
- Modify: `backend/lib/valea/mail/sync_pass.ex` (push phase: claim ops files → validate → ledger → execute, before pull; `ops_enabled` flag removed), `backend/lib/valea/mail/engine.ex` (boot replay: `OpsFile.unresolved` + ledger recovery before first pass), `backend/lib/valea/api/mail.ex` (`mail_apply_ops` real body)
- Test: `backend/test/valea/mail/ops_executor_test.exs` (+ extend `sync_pass_test.exs`, `mail_rpc_test.exs`)

**Interfaces (Produces):**
```elixir
enqueue_move(ctx, op, origin) :: {:ok, op_row} | {:rejected, reason}
  # writes spool/<id>.manifest.yaml (kind, folders, uid, uidvalidity, msg_id fingerprint ref, dest watermark
  # + dest uidvalidity — recorded via transient read-only SELECT of the destination, origin, state) FSYNCED,
  # + Store.create_pending_op — BEFORE any mutating I/O
execute(ctx, op_row) :: :ok | {:needs_review, reason} | {:rejected, reason}
recover(ctx) :: :ok    # boot: manifests without completed ledger rows + ledger rows in claimed/executing
                       # → reconcile (below) before any new op executes for the affected origins
apply_ops(root, account, ops :: [map], origin) :: [result_map]   # shared by ops-files and RPC
```
**Execution contract (each = test):**
1. **Execution-time verification** (every move): `SELECT` source → `uidvalidity == op.source_uidvalidity` else reject-for-revalidation; `uid_fetch_full(uid)` → fingerprint must equal the occurrence's msg_id fingerprint else reject. Only then the ladder.
2. **Move ladder + confirmation — the executor OWNS the ladder** (each step a durable manifest transition): when `supports?(:move)` → `uid_move` (native), COPYUID as dest_uid when present, else destination confirmation below. Without MOVE: `uid_copy` → **destination confirmation** → only then `uid_mark_deleted` → `uid_expunge`, each step recorded in the manifest before it runs; a crash or lost response between any two steps recovers by reconciliation, and the source is NEVER expunged before a confirmed destination exists. Destination confirmation = COPYUID when supplied; else `uid_search` in dest for `HEADER Message-ID` (when the message has one), else candidate scan `UID <dest_watermark+1>:*` + fingerprint-confirm each candidate (dest UIDVALIDITY changed vs manifest → full-folder fingerprint scan). Exactly one confirmed match → persist dest_uid → THEN relocate the local file (`Maildir` rename into dest dir, new `U=`), update uid_map/index/views. Zero or several → `needs_review`, local file untouched, no destructive step taken. The per-step fault matrix (lost response after COPY / after STORE / after EXPUNGE) is testable because each step is a separate transport call.
3. **Write-through destination** (`to` ∈ folders.{archive,trash} ∧ excluded): transient `examine/2` (read-only) for watermark + uidvalidity at enqueue; after confirmation the local occurrence is REMOVED (file + rows + view GC) — message left the mirrored set.
4. **Gmail profile**: move executes only when `supports?(:move)`; postcondition for EVERY gmail move = source `uid_search("UID <uid>")` empty AND dest (or All Mail for archive, via `examine/2` — read-only) `uid_search("X-GM-MSGID <gm_msgid>")` non-empty (gm_msgid captured at landing into uid_map — add column? NO: fetch at enqueue via `uid_fetch_flags(conn, "<uid>")`). Pre-existing membership counts. Local relocation only after proof; archive-to-All-Mail removes the local occurrence (excluded dest).
5. **Flags**: baseline = uid_map `last_synced_flags` (+ modseq via `uid_fetch_flags` at enqueue when condstore); `OpsFile.write_op_state!` persists the baseline + postcondition **+ the source UIDVALIDITY and the occurrence's msg_id fingerprint reference** (fsync) BEFORE the STORE; **execution-time verification applies to flags exactly as to moves** (contract 1): `SELECT` the folder, require live UIDVALIDITY == recorded, `uid_fetch_full(uid)` + fingerprint match — any mismatch (reset, recycled UID, altered content) → rejected `"server_changed"`, no STORE issued (test: UIDVALIDITY reset between enqueue and execution with push-before-pull → flag op rejected, unrelated recycled-UID message untouched); execute `uid_store_flags(..., unchangedsince: modseq)`; `{:ok, :modified}` → `needs_review` (baseline moved); recovery path (boot, via `read_op_states`): refetch flags — postcondition already present → ok; flags differ from the recorded baseline in any other way → `needs_review`, never an overwriting STORE; exactly the recorded baseline → one guarded retry. Test: reboot after a `{:lost_response, :uid_store_flags}` fault + concurrent model `set_flags` change → `needs_review`, server flags untouched. Flag ops do NOT create ledger rows; their durable record is the claimed ops file + its `.state.yaml` sidecar.
6. **Uncertain results** (`{:lost_response, _}` faults): op stays `executing`; `recover/1` reconciles per contract 2 before any retry; append recovery searches target folder for the Valea Message-ID, and after an unknown outcome widens to ALL known folders — exactly one fingerprint-confirmed match → complete; zero/several → `needs_review`. Never a second APPEND after an unproven unknown outcome.
7. **Conflict**: op targets a uid the server moved/removed since last pull → verification fails → rejected `"server_changed"` (server wins), notice.
8. **mail_apply_ops RPC** shares `apply_ops/4` (origin `"rpc"`), returns per-op results synchronously (executor runs inline in the engine call for RPC ops; ops-file ops run in the pass).
- [ ] **Step 1: Write failing executor tests** with `ModelMailTransport` — one per contract item + ladder-disconnect-after-each-request matrix (`{:lost_response, :uid_move}`, and for the UIDPLUS fallback each of COPY/STORE/EXPUNGE steps via scripted `FakeMailTransport` where step-level control is needed) proving: no duplicate destination copy, no premature source delete, no local relocation without confirmed dest.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** executor + push wiring + boot recovery + RPC body.
- [ ] **Step 4: Green** — `mix test test/valea/mail` then `just test` (codegen unchanged — `mail_apply_ops` signature already declared in Task 10).
- [ ] **Step 5: Commit** `feat(mail): durable ops executor — verification, confirmation, recovery`.

---

### Task 14: Mail mounts, related grammar, sessions, permission policy

**SECURITY-CRITICAL — opus review.**

**Files:**
- Modify: `backend/lib/valea/mounts.ex` (synthetic mail mounts), `backend/lib/valea/mounts/context.ex` (bare-string `mail-<slug>` related entries), `backend/lib/valea/agents/session_scope.ex` (+ `include_mounts`), `backend/lib/valea/api/agents.ex` (`create_agent_session` gains `include_mounts` arg, default `[]`), `backend/lib/valea/agents/permission_policy.ex`, `backend/lib/valea/agents/session_settings.ex`
- Tests: `backend/test/valea/agents/permission_policy_test.exs` (extend), `session_read_roots_test.exs` (extend), `backend/test/valea/mounts/mounts_mutation_test.exs` + new `backend/test/valea/mounts/mail_mounts_test.exs`, `backend/test/valea_web/agents_rpc_test.exs` (extend)

**Design pins:**
- **Synthetic mounts**: `Mounts.list/1` appends, for each VALID configured account with a healthy identity, `%{name: "mail-" <> slug, root: <ws>/sources/mail/<slug>, manifest: nil, enabled: account_active?, degraded: nil | "identity_mismatch" | "mailbox_replaced", kind: :mail}` (regular mounts get `kind: :icm`; add the key everywhere the map literal is built). Mail mounts are NEVER writable targets for ICM mutations (`mount/create/adopt/unmount` reject `mail-*` keys and roots under `sources/mail`), and are excluded from the Knowledge tree grouping (check `Valea.Icm` tree listing entry point — filter `kind: :mail`).
- **Related grammar**: a `related_icms` LIST ENTRY that is a bare string matching `"mail-" <> slug` resolves via `Mounts.mount_by_key/2` (must be `kind: :mail`, enabled, non-degraded) → `%{mount_key:, id: nil, root:, entrypoint: nil, manifest: nil, kind: :mail}`; map entries keep the existing ICM id semantics untouched. Issues: `:mail_unavailable` when configured-but-degraded/absent.
- **`include_mounts`**: `create_agent_session(mount_key, generation, context_doc, input, include_mounts :: [String.t()] \\ [])` — each entry must be an existing enabled non-degraded `kind: :mail` mount (ICM keys rejected `"include_not_mail"`); resolved mounts append to `scope.related_icms` (same shape as grammar-resolved mail entries). Session meta records them.
- **PermissionPolicy** (ctx gains `mail_roots_all :: [String.t()]` — every `sources/mail/<slug>` root — and `mail_roots_in_scope :: [String.t()]`; both threaded from SessionScope like `icm_roots`):
  1. **Unmounted deny**: any candidate path under a `mail_roots_all` root NOT in `mail_roots_in_scope` → `{:deny, "reject_once"}`, before the ask fallback. Matching casefolds: compare `String.downcase` + NFC of resolved paths (the roots are pre-resolved via `split_real/1`; add a `casefold/1` helper applied to BOTH sides of the segment-membership check for mail rules only — do not change the global `split_under_root?/2`).
  2. **Write-surface**: within an in-scope mail root, WRITE kinds allowed (grant/ask flow) ONLY when every candidate is under `<mailroot>/ops/pending` or `<mailroot>/drafts`; writes anywhere else in the mail root → deny. READ kinds: `<mailroot>/spool` → deny; everything else in-scope readable.
  3. Existing protected/secrets denies keep precedence order: denied tool → protected → icm_secret → **mail rules** → escaped → ask/allow.
- **SessionSettings** mirror: for each in-scope mail root, deny globs `spool/**` (Read+Edit+Write) and `maildir/**`, `views/**`, `quarantine/**`, `.account`, `ops/done/**` (Edit+Write only); for each NOT-in-scope mail root: `**` over Read+Edit+Write. Case-sensitive globs documented as defense-in-depth (same note as secrets mirror).

- [ ] **Step 1: Write failing tests.** Policy (pure `decide/2` tests, follow the split-suite style): unmounted mail read → deny (not ask), incl. `sources/MAIL/...` and NFD-variant spellings resolved to the same root; in-scope read of `maildir/**` → allow; write `ops/pending/x.yaml` in scope → ask (no grant) / allow (granted write root); write `maildir/cur/f` in scope → deny; read `spool/m.eml` in scope → deny; ICM-secrets deny still wins inside a mail root (`drafts/.env` → deny). Scope: `include_mounts` threads the mail root into `read_roots`+`mail_roots_in_scope` (session_read_roots_test); `related_icms: ["mail-personal"]` string entry resolves; ICM key in include_mounts → error. Mounts: `mail-*` excluded from knowledge tree + mutation guards. RPC: create_agent_session with include_mounts recorded in meta. **Agent RPC isolation** (spec's safety invariant): a test asserting the launched session's tool/transport surface contains no RPC access — concretely, assert the managed-settings/ACP launch directives contain no RPC endpoint or token, and grep-assert `session_server.ex`/harness adapter expose no `/rpc/run` path to the child process env (extend the existing session_settings/agents test files with this).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Green** — `mix test test/valea/agents test/valea/mounts test/valea_web/agents_rpc_test.exs`; `just test` (codegen: `create_agent_session` input changed → regenerate + update `client.ts` wrapper signature).
- [ ] **Step 5: Commit** `feat(agents): mail mounts — opt-in scope, deny-not-ask, narrowed write surface`.

---

### Task 15: Drafts + Push-to-Drafts

**Files:**
- Create: `backend/lib/valea/mail/draft_file.ex`; Resurrect+rework: `backend/lib/valea/mail/draft_mime.ex` (start from `git show f668811^:backend/lib/valea/mail/draft_mime.ex`)
- Modify: `backend/lib/valea/api/mail.ex` (`push_draft_to_mailbox` + `list_mail_drafts` real bodies), `backend/lib/valea/mail/ops_executor.ex` (append kind execution — mostly exists from T13 contract 6), `backend/lib/valea/mail/engine.ex` (push claim serialization via engine call)
- Tests: `backend/test/valea/mail/draft_file_test.exs`, `backend/test/valea/mail/draft_mime_test.exs` (resurrect golden tests from `git show f668811^:backend/test/valea/mail/draft_mime_test.exs`, adapted), extend `mail_rpc_test.exs` + `ops_executor_test.exs`

**Interfaces (Produces):**
```elixir
# Valea.Mail.DraftFile
parse_and_validate(bytes :: binary) ::
  {:ok, %{to: [addr], cc: [addr], bcc: [addr], subject: String.t(), in_reply_to: String.t() | nil,
          status: String.t(), body: String.t()}}
  | {:error, String.t()}
  # addr :: %{name: String.t() | nil, email: String.t()}
  # RULES (each a test): unknown frontmatter fields reject (allowed: to/cc/bcc/subject/in_reply_to/status);
  # status ∈ "draft" | "pushing" | "pushed" | absent (defaults "draft") — any OTHER value rejects.
  # The anti-forgery rule is NOT here: the PUSH flow rejects status != "draft" unless a ledger op for
  # this draft corroborates the stamp (engine wrote it); LISTING parses all three values and derives
  # the displayed state from the ledger (frontmatter never authoritative). This keeps engine-stamped
  # drafts parseable and re-pushable after edits.
  # ANY CR/LF/NUL inside any field value rejects;
  # to/cc/bcc parsed with an RFC 5322 mailbox parser — implement `parse_mailbox/1` (name-addr + addr-spec,
  # quoted display names; reject anything else — no groups, no route addrs); at least one `to`;
  # in_reply_to must match msg_id shape ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+-[0-9a-f]{8,64}$
content_hash(bytes) :: String.t()   # sha256 hex

# Valea.Mail.DraftMime (reworked compose)
compose(validated :: map, threading :: %{in_reply_to: String.t() | nil, references: [String.t()]}, message_id :: String.t(), from :: String.t() | nil) :: {:ok, binary}
  # headers serialized FROM PARSED VALUES ONLY (never raw strings); RFC 2047 for non-ASCII names/subject;
  # text/plain quoted-printable exactly like the historical module; Date; MIME-Version
push_message_id(account, draft_name, content_hash) :: String.t()
  # "<valea.push.<first 16 of sha256(account <> "/" <> draft_name <> "/" <> content_hash)>@valea.invalid>" — stable per claim
```
**Push flow (in `Api.Mail` + engine; each numbered item = test):**
1. `draft_name` validated basename (no `/`, no `..`, must end `.md`); path derived `sources/mail/<account>/drafts/<name>`; `Paths.resolve_real` under the account's drafts dir; open via `:file.read_link_info` no-follow check (regular, links: 1) then read ONCE into a buffer.
2. Atomic claim FIRST: `Store.create_pending_op(kind: "append", origin: "drafts/" <> name, state: "claimed", message_id: push_message_id(...))` — `{:error, :duplicate_active}` → return the existing op's state (no second attempt). Serialized through the account Engine (`GenServer.call`).
3. Snapshot verify: `content_hash` vs buffer → mismatch: op → `rejected`, error `"content_changed"`. Then `DraftFile.parse_and_validate(buffer)` → reject on failure; parsed `status != "draft"` with NO corroborating ledger op for this draft (any state) → reject `"status_forged"`; with a corroborating completed op → allowed (re-push of an edited, previously-pushed draft). Threading: `in_reply_to` msg_id → find any occurrence via `Store.occurrences_by_msg_id` → read raw canonical file → extract Message-ID/References for compose; absent → compose without + notice in result.
4. Compose from the SAME buffer's validated fields; write `spool/<opid>.eml` + manifest (fsync); record `payload_sha256`; op → `pending`. Draft stamp `status: pushing` via CAS (re-hash file; only rewrite when hash == snapshot; stamped copy derived from the snapshot buffer).
5. Executor (next engine cycle or inline for the RPC): re-verify spool hash, idempotent APPEND to `folders.drafts` (search-first by push Message-ID), on proven success op → `complete`, draft CAS-stamped `status: pushed`, spool cleaned, audit entry. Refusal → op `rejected`, CAS revert to `status: draft`.
6. Crash orderings: `claimed` row without spool file at boot → `rejected` + CAS revert (provably un-transmitted); manifest without ledger row → blocked origin until reconciled. Draft edited mid-push → CAS leaves the file, ledger/`list_mail_drafts` reports `pushed_revision_stale: true`.
7. `list_mail_drafts` returns per draft: `account, name, path, status_display` (derived from LEDGER: active op state ⊃ frontmatter; frontmatter `pushed/pushing` with no ledger op → `"draft"` + `"status_forged" => true` notice), `parsed_recipients` (from validate; parse errors → `"invalid" => reason`).
8. Symlinked draft (cross-account or arbitrary target) → rejected at the no-follow check.
- [ ] **Step 1: Write failing tests** — DraftFile rule matrix incl. CRLF header injection in subject + recipient (`"a@b.c>\r\nBcc: evil@x"`), malformed mailbox, group syntax rejected; DraftMime golden tests (resurrected: deterministic Message-ID now `push_message_id` shape, quoting/2047/QP assertions kept); push flow 1–8 (RPC + executor with `ModelMailTransport`, faults for the append-crash + filed-away-before-reconciliation cases: model moves the pushed draft to another folder between fault and recovery → widened search resolves; model deletes it → `needs_review`).
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Green** + `just test` (codegen for the two real action bodies — shapes declared in T10, verify no drift).
- [ ] **Step 5: Commit** `feat(mail): drafts — validated compose, hash-bound serialized push`.

---

### Task 16: Frontend — ops UI, entry points, drafts panel

**Files:**
- Modify: `frontend/src/lib/components/mail/MessageView.svelte` (archive/flag actions via `mail_apply_ops`; session entry → `createAgentSession(mountKey, gen, { input: { kind: 'workspace', path: viewPath } }, ['mail-<account>'])` with the account's mount key; prompt updated to mention the mail mount + ops files), `mail-shapes.ts` (+ `opResultMessage`, `heldFolderBadge`, drafts helpers)
- Create: `frontend/src/lib/components/mail/DraftsPanel.svelte`
- Modify: `frontend/src/routes/mail/+page.svelte` (Drafts pill + panel; "Clean up inbox" action → `createAgentSession(primary mount, gen, {}, ['mail-<slug>'])` + `setInitialPrompt(cleanupPrompt(slug))`), `frontend/src/lib/api/client.ts` (`applyMailOps`, `pushDraftToMailbox`, `listMailDrafts`, `discardHeldFolder`, `readoptMailAccount`, `purgeMailAccountFiles` wrappers), stores as needed
- Tests: vitest for new pure helpers + store methods (`mail.test.ts`, `mail-components.test.ts`)

**Contract:** `cleanupPrompt(slug)` text: "You have the mail account '<slug>' mounted read-only at its mail mount. Review INBOX via the views/ folder, then declare cleanup as a YAML ops file in ops/pending/ (vocabulary: move, flag) — the engine validates and executes them. Never modify maildir/ directly. Propose, don't over-file: when unsure, leave a message where it is." Archive button = `mail_apply_ops` with `[{op:'move', msg_id, from: currentFolder, to: archiveFolderName}]` (folder names from `list_mail_folders` config echo — add `archive`/`trash` names to `mail_status` account map in T10 if not already there; verify and patch backend + regen in this task if missing). DraftsPanel: parsed-recipient display, status badges (ledger-derived), Push button w/ `content_hash` = sha256 of the exact fetched draft body (use Web Crypto `crypto.subtle.digest`), typed-confirm dialogs for purge/discard/readopt reuse the existing dialog pattern (`DeleteDialog.svelte` style).

- [ ] **Step 1: Failing vitest** for helpers/store. **Step 2:** `bun run test` FAIL. **Step 3: Implement.** **Step 4:** `bun run check && bun run test` green → `just test` green. **Step 5: Commit** `feat(mail-fe): cleanup entry, apply-ops actions, drafts panel`.

---

### Task 17: Docs, deletion gates, acceptance checklist, final sweep

**Files:**
- Modify: `docs/ARCHITECTURE.md` (rewrite `## Mail` section for Spec E: module map, storage layout, sync/ops/push contracts, mounts+policy, credential path — mirror the spec's final state; delete the "Mail interim (Spec D §E)" subsection), `docs/VISION.md` (mail paragraph if it references handoff pipeline)
- Create: `docs/superpowers/acceptance/2026-07-17-mail-maildir.md` — manual live checklist: dovecot (`just mail-dev`, two accounts, full pull, ops move via hand-written ops file, held-folder on rename, UIDVALIDITY reset drill via dovecot maildir surgery, push draft) + one real provider account (Daniel's; gmail archive + already-applied-label move + retries) + keychain resupply + restart recovery. Each item: steps, expected, observed-blank.
- Modify: `justfile` `mail-dev` comment block if the dovecot workflow changed (it didn't — verify only).

- [ ] **Step 1: Grep gates** (all must return ZERO in `backend/lib backend/test frontend/src`, excluding this plan/spec):
  `rg -n "UidOutcome|InboxHeader|flip_status|mail_inbox\b|inbox_index_limit|inbox\.md" backend/lib backend/test frontend/src`
  `rg -n "VALEA_MAIL_PASSWORD\"" backend/lib` (bare unsuffixed env)
  `rg -n "sources/mail/messages" backend frontend` (old flat layout)
  `rg -n "folders\.review|folders\.processed|:review\b.*folders|AI/Review" backend/lib frontend/src` (v3 folder vocabulary; test fixtures exempt only where testing rejection)
  `rg -n "smtp|Smtp|SMTP" backend/lib frontend/src` (must be zero — no SMTP anywhere)
- [ ] **Step 2: Docs rewrite** (ARCHITECTURE Mail section replaced wholesale; keep the surrounding doc structure).
- [ ] **Step 3: Acceptance doc** written with concrete commands.
- [ ] **Step 4: Full gate** `just test` → green; `cd backend && mix format --check-formatted`.
- [ ] **Step 5: Commit** `docs(mail): architecture rewrite + live-acceptance checklist + deletion gates`.

---

## Execution notes for the SDD controller

- **Model selection**: T1/T2/T5/T12 are self-contained with near-complete specs → cheap tier OK (sonnet floor for T5). T3/T4/T6/T9/T10/T11/T16 → standard tier. T7/T8/T13/T15 (sync/executor correctness) and T14 (security) → most capable tier for implementation AND opus for review. Final whole-branch review: opus.
- **Security-critical reviews (opus)**: T13, T14, T15; plus T7/T8 (data-loss surface).
- **Every dispatch forbids spawning sub-agents.** Record BASE before dispatch; `review-package BASE HEAD`.
- **Sequencing is strict**: T1→T2→T3→T4→T5→T6→T7→T8→T9→T10→T11→T12→T13→T14→T15→T16→T17. The suite must be green after every task (stub allowances called out inline in T6/T7/T10).
- The spec (docs/superpowers/specs/2026-07-17-mail-maildir-design.md) is the tie-breaker for any ambiguity; implementers get the relevant spec sections quoted in their briefs, not the whole file.
- Live acceptance (checklist doc) is EXECUTED BY THE USER after merge — the SDD run ends at the finishing gate with the checklist written, not performed.
