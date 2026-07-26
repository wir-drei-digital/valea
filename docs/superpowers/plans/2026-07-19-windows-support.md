# Windows Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows x86_64 a first-class desktop target — bootable Burrito sidecar, agent runtime via a Job-Object spawn shim, NTFS-safe maildir, platform-aware path containment (incl. UNC shares), NSIS + auto-update CI lane.

**Architecture:** Spec: `docs/superpowers/specs/2026-07-19-windows-support-design.md` (v3 — READ IT FIRST; section letters below refer to it). Native builds only — the Windows release is built ON Windows; `mix.exs` may branch on build-host OS. Erlang `Port` + a Rust `valea-spawn` shim replace erlexec on Windows; one platform-aware `Valea.Paths` API replaces 16 scattered `"/"`-prefix decisions; the maildir separator becomes per-store state in `.account`.

**Tech Stack:** Elixir/Phoenix backend (Burrito sidecar), Tauri v2 + Rust desktop shell, GitHub Actions (`windows-latest`), NSIS via tauri-action.

**Revision:** v4 — Codex rounds 1–3 folded in. Round 1: BEAM-on-Windows release gap, watcher_live integration, SessionServer stderr-path wiring, adapter boot-time selection seam, zig cache fix, native-Windows CI gates on Tasks 3/5/6/7. Round 2: Task 3 gate ordering, retained sidecar Job handle, platform-branched selection test, `mix deps.get` in bring-up, `.cmd`/COMSPEC shim route, ClaudeCode-owned Windows discovery, `process_runtime_test.exs` fixture migration.

## Global Constraints

- **Never weaken containment** (`Valea.Paths.resolve_real` + PermissionPolicy) — ambiguous path forms fail closed (`:invalid`/`:outside`), never open.
- **Native builds only**: no cross-compilation anywhere; `BURRITO_TARGET` always matches the build host (release spec invariant).
- **Suite stays green on macOS/Linux after every task** — Windows behavior is added behind `:os.type()` / platform args; the Windows CI lane does not gate merges until Task 8.
- Maildir separator on existing/Unix stores stays `:`; absent `.account` field ⇒ `:` **always** (never OS-defaulted) — spec §C1.
- Agent child env is a **fixed allowlist** per platform — never inherit-all, secrets never pass (spec §B4).
- Windows adapter with no shim ⇒ **fail fast, doctor-visible** — never a silent Port-only fallback (spec §B2).
- Rejected path kinds on Windows: drive-relative (`C:foo`), device (`\\.\…`), bare `//host`; `\\?\` forms are normalized away; UNC `//host/share` is a supported absolute root (spec §D1).
- Commit style: `feat(backend):` / `feat(desktop):` / `ci:` / `test(backend):` prefixes, as in recent history.
- **Native-Windows CI gate**: Tasks 3, 5, 6, 7 each end by dispatching `windows-bringup.yml` and are NOT complete until their gating segment is green on the Windows runner (run URL recorded in the SDD ledger). Local macOS green is necessary, never sufficient, for those tasks.

---

### Task 1: Build bring-up — conditional erlexec, Windows packaging, LOCALAPPDATA pin, bring-up CI (spec A1, A2, A3, A6, F)

**Files:**
- Modify: `backend/mix.exs`
- Modify: `backend/scripts/build-release.sh`
- Modify: `Justfile` (`package-backend` recipe)
- Modify: `backend/lib/valea/app/config.ex:18-23`
- Test: `backend/test/valea/app/config_test.exs` (create if absent)
- Modify: `desktop/src-tauri/src/main.rs:76` (`app_data_dir` → `app_local_data_dir`)
- Create: `.github/workflows/windows-bringup.yml`

**Interfaces:**
- Consumes: existing `releases()` config, `build-release.sh` zig bootstrap, `Valea.App.Config.dir/0`.
- Produces: `Valea.App.Config.default_dir/2` (`(os_type_tuple, localappdata_env_or_nil) :: String.t()`); Burrito target `windows_x64`; sidecar name `binaries/valea-server-x86_64-pc-windows-msvc.exe`. Task 8 folds this workflow into `release.yml`.

- [ ] **Step 1: Failing test for the LOCALAPPDATA pin (pure seam)**

```elixir
# backend/test/valea/app/config_test.exs
defmodule Valea.App.ConfigTest do
  use ExUnit.Case, async: true

  describe "default_dir/2 (spec A6 — profile must be local, non-roaming)" do
    test "windows pins to LOCALAPPDATA, not roaming basedir" do
      assert Valea.App.Config.default_dir({:win32, :nt}, "C:/Users/mara/AppData/Local") ==
               "C:/Users/mara/AppData/Local/valea"
    end

    test "windows without LOCALAPPDATA falls back to OTP basedir" do
      assert Valea.App.Config.default_dir({:win32, :nt}, nil) ==
               :filename.basedir(:user_data, "valea")
    end

    test "unix keeps the OTP basedir" do
      assert Valea.App.Config.default_dir({:unix, :darwin}, nil) ==
               :filename.basedir(:user_data, "valea")
    end
  end
end
```

- [ ] **Step 2: Run it — expect failure**

Run: `cd backend && mix test test/valea/app/config_test.exs`
Expected: FAIL — `default_dir/2 undefined`

- [ ] **Step 3: Implement in `config.ex`**

Replace `dir/0` (lines 18-23) with:

```elixir
  def dir do
    case System.get_env("VALEA_APP_DIR") do
      nil -> default_dir(:os.type(), System.get_env("LOCALAPPDATA"))
      override -> override
    end
  end

  # Spec A6 (windows-support): OTP's `:user_data` basedir is ROAMING AppData
  # on Windows; corporate folder redirection can put Roaming on an SMB share,
  # and SQLite-in-WAL is documented-unsafe over network filesystems. The
  # workspace profile therefore pins to %LOCALAPPDATA%. Decided before the
  # first Windows release so there is never a roaming→local migration.
  def default_dir({:win32, _}, local_appdata) when is_binary(local_appdata),
    do: Path.join(local_appdata, "valea")

  def default_dir(_os, _local_appdata), do: :filename.basedir(:user_data, "valea")
```

- [ ] **Step 4: Run the test — expect PASS**, then run the touched-module suite: `mix test test/valea/app` — all green.

- [ ] **Step 5: Conditional erlexec in `mix.exs`**

In `deps()`, replace `{:erlexec, "~> 2.0"}` with nothing, and append `++ platform_deps()` to the list. Add:

```elixir
  # erlexec is Unix-only — its C++ port program does not COMPILE on Windows
  # (windows-support spec A1), so on a Windows build host the dependency
  # must not exist at all. Native-per-platform builds make this branch safe:
  # the host IS the target.
  defp platform_deps do
    case :os.type() do
      {:win32, _} -> []
      _ -> [{:erlexec, "~> 2.0"}]
    end
  end
```

In `application/0`, replace the `extra_applications` line with:

```elixir
      extra_applications: [:logger, :runtime_tools, :inets] ++ platform_extra_applications()
```

and add:

```elixir
  defp platform_extra_applications do
    case :os.type() do
      {:win32, _} -> []
      _ -> [:erlexec]
    end
  end
```

Verify: `cd backend && mix compile --warnings-as-errors` — green; `mix test` — green (macOS host: erlexec still present, behavior unchanged).

- [ ] **Step 6: Windows host mapping in `build-release.sh`**

Extend the `BURRITO_TARGET` case with a Windows arm (Git Bash reports `MINGW64_NT-…`/`MSYS_NT-…`):

```bash
      Darwin-arm64) BURRITO_TARGET="macos_arm" ;;
      Linux-x86_64) BURRITO_TARGET="linux_x64" ;;
      Windows_NT-x86_64 | MINGW*-x86_64 | MSYS*-x86_64) BURRITO_TARGET="windows_x64" ;;
```

(`Windows_NT` per spec §A2 — some Windows shells report it instead of the Git-Bash `MINGW64_NT-…` form.)

Extend the zig fetch: after the existing `case "$(uname -s)"` for `ZIG_OS`, add `Windows_NT | MINGW* | MSYS*) ZIG_OS="windows" ;;`. The cached-executable guard must account for the `.exe` suffix (a bare `-x "$ZIG_DIR/zig"` check would treat the Windows cache as forever-absent), and `unzip` needs `-o` so a re-extract over a partial dir can't prompt:

```bash
    ZIG_EXE="zig"
    if [ "$ZIG_OS" = "windows" ]; then ZIG_EXE="zig.exe"; fi
    if [ ! -e "$ZIG_DIR/$ZIG_EXE" ]; then
      echo "Fetching pinned zig ${ZIG_VERSION} for Burrito into $ZIG_DIR ..."
      mkdir -p "$(dirname "$ZIG_DIR")"
      if [ "$ZIG_OS" = "windows" ]; then
        ARCHIVE="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.zip"
        curl -fsSL -o "$(dirname "$ZIG_DIR")/$ARCHIVE" \
          "https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE}"
        unzip -qo "$(dirname "$ZIG_DIR")/$ARCHIVE" -d "$(dirname "$ZIG_DIR")"
      else
        TARBALL="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.tar.xz"
        curl -fsSL -o "$(dirname "$ZIG_DIR")/$TARBALL" \
          "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
        tar -xJf "$(dirname "$ZIG_DIR")/$TARBALL" -C "$(dirname "$ZIG_DIR")"
      fi
    fi
```

(This replaces the existing `[ ! -x "$ZIG_DIR/zig" ]` guard wholesale — one guard, suffix-aware.)

Also add `windows_x64: [os: :windows, cpu: :x86_64]` to the Burrito targets in `mix.exs` `releases()` (replacing the "No windows target yet" comment with a pointer to the windows-support spec) and set `include_executables_for: [:unix, :windows]` on `valea_desktop`.

Verify: `bash -n backend/scripts/build-release.sh`; on macOS `just package-backend` still succeeds (existing target unaffected).

- [ ] **Step 7: `Justfile` Windows branch**

In `package-backend`, add to the host case:

```bash
      Windows_NT-x86_64|MINGW*-x86_64|MSYS*-x86_64) export BURRITO_TARGET="${BURRITO_TARGET:-windows_x64}" ;;
```

and make the copy suffix-aware:

```bash
    exe=""
    case "$BURRITO_TARGET" in windows_*) exe=".exe" ;; esac
    cp "backend/burrito_out/valea_desktop_${BURRITO_TARGET}${exe}" \
       "desktop/src-tauri/binaries/valea-server-${triple}${exe}"
```

(`triple` on the Windows runner is `x86_64-pc-windows-msvc`. If the Burrito output name differs from `valea_desktop_windows_x64.exe`, record the actual name from the first CI run — that verification is Step 9.)

- [ ] **Step 8: Shell data dir → local (A6, desktop half)**

In `desktop/src-tauri/src/main.rs` `start_sidecar`, change

```rust
    let data_dir = app.path().app_data_dir()?;
```

to

```rust
    // windows-support spec A6: LOCAL app data, never Roaming — identical
    // paths on macOS/Linux, %LOCALAPPDATA% instead of %APPDATA% on Windows.
    let data_dir = app.path().app_local_data_dir()?;
```

Verify: `cd desktop/src-tauri && cargo check` — green. (On macOS/Linux both calls resolve to the same directory, so existing installs are unaffected.)

- [ ] **Step 9: Bring-up workflow**

Create `.github/workflows/windows-bringup.yml` — dispatch-only; **not** part of `release.yml` until Task 8:

```yaml
# Windows bring-up lane (windows-support spec T1/F). Dispatch-only on
# purpose: main must not ship a release lane that produces broken
# installers. Task 8 retires this file into the release.yml matrix.
name: Windows bring-up
on:
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-latest
    timeout-minutes: 90
    defaults:
      run:
        shell: bash
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
      - uses: dtolnay/rust-toolchain@stable
      - uses: taiki-e/install-action@v2
        with:
          tool: just
      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict
      - uses: actions/cache@v4
        with:
          path: |
            backend/deps
            backend/_build
          key: mix-prod-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('.tool-versions', 'backend/mix.lock') }}
      - uses: actions/cache@v4
        with:
          path: ~/.local/zig
          key: zig-0.15.2-${{ runner.os }}-${{ runner.arch }}
      - uses: swatinem/rust-cache@v2
        with:
          workspaces: desktop/src-tauri
      - name: Install JS deps
        run: |
          (cd frontend && bun install --frozen-lockfile)
          (cd desktop && bun install --frozen-lockfile)
      - name: Bootstrap hex/rebar
        run: cd backend && mix local.hex --force && mix local.rebar --force
      # mix test does NOT auto-fetch — without this a cold runner dies with
      # "missing dependencies" before the suite even starts.
      - name: Fetch backend deps
        run: cd backend && mix deps.get
      # Spec T1: run the FULL suite once to harvest the real Windows failure
      # list for Tasks 2-7. Non-gating by design.
      - name: Backend suite (survey run, non-gating)
        continue-on-error: true
        run: cd backend && mix test 2>&1 | tee ../windows-test-survey.txt
      - uses: actions/upload-artifact@v4
        with:
          name: windows-test-survey
          path: windows-test-survey.txt
      - name: Build SPA + Burrito sidecar
        env:
          BURRITO_TARGET: windows_x64
        run: just package-backend
      - name: Build NSIS bundle (no release)
        uses: tauri-apps/tauri-action@v0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY }}
          TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_SIGNING_PRIVATE_KEY_PASSWORD }}
        with:
          projectPath: desktop
      - uses: actions/upload-artifact@v4
        with:
          name: windows-bundles
          retention-days: 7
          if-no-files-found: error
          path: |
            desktop/src-tauri/target/release/bundle/nsis/*.exe
            desktop/src-tauri/target/release/bundle/nsis/*.exe.sig
```

Verify locally: `ruby -ryaml -e 'YAML.load_file(".github/workflows/windows-bringup.yml")'`.

- [ ] **Step 10: Full local regression + commit**

Run: `cd backend && mix test` and `cd desktop/src-tauri && cargo check` — green.

```bash
git add backend/mix.exs backend/scripts/build-release.sh Justfile \
  backend/lib/valea/app/config.ex backend/test/valea/app/config_test.exs \
  desktop/src-tauri/src/main.rs .github/workflows/windows-bringup.yml
git commit -m "feat(backend): Windows build bring-up — conditional erlexec, windows_x64 target, LOCALAPPDATA pin, bring-up CI lane"
```

- [ ] **Step 11 (needs a push + Daniel or CI access): dispatch the bring-up workflow**, download `windows-test-survey`, and record in the SDD ledger: (a) the exact Burrito output filename, (b) the suite failure list (feeds Tasks 2-7), (c) whether exqlite/mdex compiled (spec A3). If Burrito itself fails on Windows, STOP and escalate — the spec's named fallback (plain `mix release` + zip-dir sidecar) is a design change requiring sign-off.

---

### Task 2: Watcher availability model (spec A5)

**Files:**
- Modify: `backend/lib/valea/icm/watcher.ex` — `start_link/1` (:122), `init/1` fixed watcher (`{:ok, fixed_watcher} = FileSystem.start_link`, :164), `start_icm_watcher/1` (:349)
- Test: `backend/test/valea/icm/watcher_test.exs` (extend)
- Modify: `backend/lib/valea/mounts/doctor.ex` — integrate the disabled state into the EXISTING `watcher_live` check (`watcher_live_check/1`, no new check id)

**Interfaces:**
- Consumes: `FileSystem.start_link/1` (the `file_system` hex package).
- Produces: `start_link/1` accepts `root | {root, opts}` with `opts[:fs_mod]` (default `FileSystem`) and `opts[:name]` (default `__MODULE__`) — supervisor child spec `{Valea.ICM.Watcher, root}` unchanged. Public readers gain an optional server argument, singleton default: `watching?(server \\ __MODULE__) :: boolean` (new) and `watched_roots(server \\ __MODULE__)` (existing call, new arg). Doctor: the disabled state folds into the EXISTING per-mount `watcher_live` check (`Valea.Mounts.Doctor.watcher_live_check/1`) — no new check id.

- [ ] **Step 1: Failing test — watcher survives a backend-start error**

CAUTION: the file's existing `setup` opens a real workspace via `Manager.create/1` (`watcher_test.exs:9-27`), which already starts the singleton-named watcher — a second `start_supervised!` under the default name dies with `:already_started` before reaching the code under test. This test therefore lives in its own `describe` with its own minimal setup (a bare tmp dir, no `Manager`), and starts the watcher under a private name:

```elixir
describe "degraded start (windows spec A5)" do
  defmodule FailingFS do
    def start_link(_opts), do: {:error, :backend_unavailable}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "valea-watch-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "enters disabled state instead of crashing when the FS backend can't start", %{root: root} do
    pid =
      start_supervised!(
        {Valea.ICM.Watcher, {root, fs_mod: FailingFS, name: :degraded_watcher_test}}
      )

    assert Valea.ICM.Watcher.watching?(:degraded_watcher_test) == false
    # the GenServer still serves its API in the disabled state:
    assert Enum.empty?(Valea.ICM.Watcher.watched_roots(:degraded_watcher_test))
    assert Process.alive?(pid)
  end
end
```

(`FailingFS` only needs `start_link/1` — `FileSystem.subscribe/1` is never reached when start fails. `watched_roots` returns a `MapSet` — assert emptiness, not `[]`.)

- [ ] **Step 2: Run — expect crash/exit (today's `{:ok, _} =` match in `init/1` blows up).**

- [ ] **Step 3: Implement.**
  - `start_link/1`: accept `root | {root, opts}`, normalize to `{root, opts}`; `name: Keyword.get(opts, :name, __MODULE__)`. `watched_roots/0` becomes `watched_roots(server \\ __MODULE__)` (all existing zero-arity callers keep compiling).
  - `fs_mod` default reads an app-env seam so the REAL workspace-runtime path is testable too (spec A5 requires proving a workspace still opens): `Keyword.get(opts, :fs_mod, Application.get_env(:valea, :icm_watcher_fs_mod, FileSystem))`.
  - `init/1`: `fs_mod = Keyword.get(opts, :fs_mod, FileSystem)` into state. Replace the `:164` hard match:

```elixir
    {fixed_watcher, watching} =
      case fs_mod.start_link(dirs: fixed_dirs(root)) do
        {:ok, watcher} ->
          FileSystem.subscribe(watcher)
          {watcher, true}

        {:error, reason} ->
          Logger.warning(
            "ICM file watching disabled (#{inspect(reason)}) — tree refreshes on navigation only"
          )

          {nil, false}
      end
```

  - `start_icm_watcher/1` (:349) becomes `start_icm_watcher/2` taking state (or `{roots, fs_mod, watching}`): returns `nil` without starting anything when `watching: false`; otherwise same `case fs_mod.start_link` shape (a dynamic-start error also logs once and returns `nil` — degrade, don't crash). `recompute_dirs/1` therefore no-ops naturally in the disabled state.
  - Only *start* errors degrade — keep raising on bad-argument shapes (spec A5: config errors are bugs).
  - Add `watching?(server \\ __MODULE__)` (`GenServer.call(server, :watching?)`) + its `handle_call`, reading the new `watching:` state field.

- [ ] **Step 3b: The spec's actual acceptance — a WORKSPACE still opens with watching disabled.** Second test in the degraded `describe`, driving the real runtime path through the app-env seam (mirror the file's existing setup: `VALEA_APP_DIR` tmp dir + `Manager`):

```elixir
test "workspace open survives an unavailable FS backend (spec A5)" do
  dir =
    Path.join(
      System.tmp_dir!(),
      "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    )

  System.put_env("VALEA_APP_DIR", dir)
  Application.put_env(:valea, :icm_watcher_fs_mod, FailingFS)

  on_exit(fn ->
    Valea.Workspace.Manager.close()
    Application.delete_env(:valea, :icm_watcher_fs_mod)
    File.rm_rf!(dir)
    System.delete_env("VALEA_APP_DIR")
  end)

  assert {:ok, _ws} = Valea.Workspace.Manager.create("W")
  assert Valea.ICM.Watcher.watching?() == false
end
```

- [ ] **Step 4: Run the new tests (PASS) + the whole watcher suite (no regressions — the happy path still subscribes exactly as before).**

- [ ] **Step 5: Doctor surfacing — inside the EXISTING check.** `Valea.Mounts.Doctor.watcher_live_check/1` (doctor.ex:388) currently reports `failed` ("not in the watcher's root set", stale remedy) whenever a mount is missing from `watched_roots()` — with a disabled watcher that would mis-diagnose every enabled mount as stale. Insert a branch between the `not mount.enabled` clause and the `MapSet.member?` clause:

```elixir
      not Watcher.watching?() ->
        unknown(
          id,
          label,
          "File watching is unavailable on this system — the tree refreshes on navigation instead."
        )
```

(Module attribute for the detail string if the file's style prefers, mirroring `@watcher_disabled_detail`.) Also the spec's network-path copy (A5): in the `MapSet.member?` OK branch, when the mount root is a network share (plain `String.starts_with?(mount.root, "//")` check here — Task 3's classifier doesn't exist yet; Task 4's migration may route it through `Valea.Paths` later), the detail reads `"#{mount.root} is in the watcher's current root set (best-effort on network paths)."`. Extend the doctor test: with a disabled watcher (FailingFS-started under the SINGLETON name in a doctor-owned test that doesn't open a workspace), every enabled mount's `watcher_live` check reports `unknown` with that detail — never `failed`; and a `//srv/share`-rooted mount in the OK state carries the best-effort wording.

- [ ] **Step 6: Full backend suite green. Commit:** `feat(backend): watcher degrades to disabled state when the FS backend is unavailable (windows spec A5)`

---

### Task 3: Platform-aware `Valea.Paths` — classifier, normalize, root-floor walk (spec D1, D2, D3, D5)

**Files:**
- Modify: `backend/lib/valea/paths.ex` (rewrite the walk; add the platform API)
- Test: `backend/test/valea/paths_test.exs` (extend heavily)

**Interfaces:**
- Produces (used by Task 4/6/7 — exact signatures):
  - `Valea.Paths.host_platform() :: :unix | :windows`
  - `Valea.Paths.classify(path, platform \\ host_platform()) :: :absolute | :relative | :drive_relative | :invalid`
  - `Valea.Paths.absolute?(path, platform \\ host_platform()) :: boolean` (`classify == :absolute`)
  - `Valea.Paths.normalize(path, platform \\ host_platform()) :: String.t()` (`\\`→`/`, strip `\\?\`/`\\?\UNC` wrappers, upcase drive letter; identity on `:unix`)
  - `Valea.Paths.ancestor?(ancestor, descendant, platform \\ host_platform()) :: boolean` (case-folded on `:windows`, exact on `:unix`; the `prefix <> "/"` idiom done once)
  - `Valea.Paths.resolve_real(path, base) :: {:ok, String.t()} | {:error, :outside | :invalid}` (signature unchanged; host platform internally)
- The walk's internal representation becomes `{root, components}` where `root ∈ {"/", "C:/", "//host/share"}` — `..` can never pop above `root` (root-floor, spec §D1).

- [ ] **Step 1: Failing tests — classification + normalize + ancestor (pure, all platforms)**

```elixir
describe "classify/2 windows shapes (pure — runs on every host)" do
  test "drive and UNC absolutes" do
    assert Valea.Paths.classify("C:/Users/mara", :windows) == :absolute
    assert Valea.Paths.classify("C:\\Users\\mara", :windows) == :absolute
    assert Valea.Paths.classify("//srv/share/icm", :windows) == :absolute
    assert Valea.Paths.classify("\\\\srv\\share", :windows) == :absolute
  end

  test "rejected forms" do
    assert Valea.Paths.classify("C:foo", :windows) == :drive_relative
    assert Valea.Paths.classify("C:", :windows) == :drive_relative
    assert Valea.Paths.classify("\\\\.\\COM1", :windows) == :invalid
    assert Valea.Paths.classify("//srv", :windows) == :invalid          # bare host, no share
    assert Valea.Paths.classify("/rootless", :windows) == :invalid     # current-drive rooted
  end

  test "unix unchanged" do
    assert Valea.Paths.classify("/a/b", :unix) == :absolute
    assert Valea.Paths.classify("C:/x", :unix) == :relative            # a legal dir name on unix
  end
end

describe "normalize/2" do
  test "extended-length wrappers strip to plain forms" do
    assert Valea.Paths.normalize("\\\\?\\C:\\a\\b", :windows) == "C:/a/b"
    assert Valea.Paths.normalize("\\\\?\\UNC\\srv\\share\\x", :windows) == "//srv/share/x"
    assert Valea.Paths.normalize("c:\\a", :windows) == "C:/a"
  end
end

describe "ancestor?/3" do
  test "case-folded on windows, exact on unix" do
    assert Valea.Paths.ancestor?("C:/Work/ICM", "c:/work/icm/notes.md", :windows)
    refute Valea.Paths.ancestor?("/work/icm", "/work/ICM/notes.md", :unix)
    assert Valea.Paths.ancestor?("//SRV/Share/icm", "//srv/share/icm/a", :windows)
  end

  test "no prefix-collision false positives" do
    refute Valea.Paths.ancestor?("C:/work/icm", "C:/work/icm-private/x", :windows)
  end
end

describe "root-floor (pure helpers)" do
  test "`..` cannot pop above a UNC share or drive root" do
    assert Valea.Paths.resolve_lexical("../..", "//srv/share/icm", :windows) == "//srv/share"
    assert Valea.Paths.resolve_lexical("../../../../..", "//srv/share/icm", :windows) == "//srv/share"
    assert Valea.Paths.resolve_lexical("../../../..", "C:/a/b", :windows) == "C:/"
  end
end
```

(`resolve_lexical/3` is the exposed pure walk — no filesystem — that `resolve_real` shares its segment/floor logic with; it exists precisely so Windows floor semantics are testable on Unix hosts, per spec §D testing split.)

- [ ] **Step 2: Run — expect failures (functions undefined).**

- [ ] **Step 3: Implement.** Shape of the rewrite (complete the details in-module; keep the moduledoc's symlink-semantics contract):

```elixir
  def host_platform do
    case :os.type() do
      {:win32, _} -> :windows
      _ -> :unix
    end
  end

  def classify(path, platform \\ host_platform())
  def classify("/" <> _, :unix), do: :absolute
  def classify(_, :unix), do: :relative

  def classify(path, :windows) do
    p = String.replace(path, "\\", "/")

    cond do
      String.starts_with?(p, "//./") -> :invalid
      String.starts_with?(p, "//?/") -> p |> strip_extended() |> classify_stripped()
      match?({_, _}, unc_root(p)) -> :absolute
      String.starts_with?(p, "//") -> :invalid
      drive_abs?(p) -> :absolute
      Regex.match?(~r/^[A-Za-z]:/, p) -> :drive_relative
      String.starts_with?(p, "/") -> :invalid
      true -> :relative
    end
  end

  # //host/share[...]  → {"//host/share", remaining_components} | nil
  defp unc_root("//" <> rest) do
    case String.split(rest, "/", trim: true) do
      [host, share | comps] when host != "" and share != "" -> {"//#{host}/#{share}", comps}
      _ -> nil
    end
  end
  defp unc_root(_), do: nil

  # The slash is REQUIRED: bare "C:" means "current directory on drive C" —
  # drive-RELATIVE (rejected), not a root. Codex round 3.
  defp drive_abs?(p), do: Regex.match?(~r{^[A-Za-z]:/}, p)
```

`normalize/2`: `:unix` → identity; `:windows` → `\\`→`/`, strip `//?/UNC/h/s`→`//h/s` and `//?/C:`→`C:`, upcase the drive letter. `ancestor?/3`: fold both sides with `String.downcase/1` when `:windows`, then the existing `== or starts_with?(d <> "/", a <> "/")` comparison. `resolve_lexical/3` + `resolve_real/2`: rework the walk to carry `{root, comps}` — `root_and_components(path, base, platform)` uses `classify` + `unc_root`/drive parsing for absolute paths (never `Path.split` on Windows shapes), `".."` pops `comps` (empty stays empty — that IS the floor), rendering joins `root` and `comps` with `/`. `resolve_real` keeps `File.read_link` symlink hops exactly as today (targets re-enter via `classify`), and final containment goes through `ancestor?/3` with the host platform.

- [ ] **Step 4: Run new tests (PASS) + the ENTIRE existing `paths_test.exs` untouched and green** — the Unix behavior contract must not move.

- [ ] **Step 5: 8.3 pin test (spec D5)** — add:

```elixir
test "8.3-style short-name aliases stay fail-closed (never resolved to long names)" do
  # DOCUME~1 is just a literal component to the walk; if the base is the
  # long-name form, containment must DENY, not alias. Pin it.
  refute Valea.Paths.ancestor?("C:/Users/mara/Documents", "C:/Users/mara/DOCUME~1/x", :windows)
end
```

- [ ] **Step 6: Full backend suite. Commit:** `feat(backend): platform-aware Valea.Paths — windows classification, UNC roots, root-floor walk, case-folded containment (windows spec D1-D3, D5)`

- [ ] **Step 7: Native-Windows gate.** Add a GATING step to `windows-bringup.yml` (after the survey step, no `continue-on-error`): `cd backend && mix test test/valea/paths_test.exs` — ONLY the paths suite; `paths_boundary_test.exs` doesn't exist until Task 4, which appends it to this step. Dispatch the workflow (needs push — Daniel/CI); the task is complete only when that step is green on `windows-latest` (spec testing split: OTP/filesystem path behavior needs the native lane). Record the run URL in the ledger.

---

### Task 4: Inventory migration — every path gate through `Valea.Paths` (spec D4 + B3 absoluteness half)

**Files (the 16-site inventory, verified 2026-07-19):**
- Modify: `backend/lib/valea/icm.ex:233`
- Modify: `backend/lib/valea/mounts.ex:427`, `:902`
- Modify: `backend/lib/valea/calendar/local.ex:784`
- Modify: `backend/lib/valea/harnesses/claude_code.ex:54`, `:58`
- Modify: `backend/lib/valea/agents/permission_policy.ex:251`, `:415`, `:468` (and the doc at `:131`)
- Modify: `backend/lib/valea/icm/watcher.ex:294`, `:383`
- Modify: `backend/lib/valea/api/icm.ex:404`, `:448`
- Modify: `backend/lib/valea_web/controllers/files_controller.ex:230`
- Exempt (do NOT touch): `backend/lib/valea/icm/backlinks.ex:160` (markdown-URL classification)
- Create: `backend/test/valea/paths_boundary_test.exs` (architecture test)

**Interfaces:**
- Consumes: `Valea.Paths.absolute?/1..2`, `Valea.Paths.ancestor?/2..3`, `Valea.Paths.normalize/1..2` (Task 3).
- Produces: no path-shaped `String.starts_with?` outside `paths.ex` — enforced by the architecture test below, which later tasks must keep green.

- [ ] **Step 1: Write the architecture test first (it fails against today's tree):**

```elixir
defmodule Valea.PathsBoundaryTest do
  use ExUnit.Case, async: true

  @exempt ["lib/valea/paths.ex", "lib/valea/icm/backlinks.ex"]

  test "absoluteness/ancestor string logic lives only in Valea.Paths (windows spec D4)" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn f -> Enum.any?(@exempt, &String.ends_with?(f, &1)) end)
      |> Enum.filter(fn f ->
        src = File.read!(f)
        Regex.match?(~r/starts_with\?\([^\n)]*"\/"\s*\)/, src) or
          Regex.match?(~r/starts_with\?\([^\n)]*<>\s*"\/"/, src)
      end)

    assert offenders == [],
           "path logic outside Valea.Paths (route through absolute?/ancestor?): #{inspect(offenders)}"
  end
end
```

Run: `mix test test/valea/paths_boundary_test.exs` — FAIL listing the offender files (8 at the time of writing; the Files inventory above, minus the two exempt).

- [ ] **Step 2: Migrate site by site** — one commit-sized sweep, same replacement grammar everywhere. Patterns (apply the matching one at each listed line, keeping surrounding logic identical):

```elixir
# ancestor idiom: X == root or String.starts_with?(X <> "/", root <> "/")
Valea.Paths.ancestor?(root, x)

# bare-prefix idiom: String.starts_with?(abs, root <> "/")   (strict child)
Valea.Paths.ancestor?(root, abs) and abs != root   # ONLY where the original excluded equality — read each site

# absoluteness: String.starts_with?(path, "/")
Valea.Paths.absolute?(path)
```

For `claude_code.ex:54-58` (spec B3's absoluteness half): configured commands classify via `Valea.Paths.absolute?(cmd)`; the rest of `resolve/2` stays (find_executable path; the PATHEXT extension fallback is Task 6). For `permission_policy.ex:251` (`split_resolve_candidate`) use `absolute?/1`. Where a site compares user/config input, `normalize/1` the input first (mount roots in `mounts.ex`, adopt-a-folder in `api/icm.ex`, session cwd — spec D2 ingress list).

- [ ] **Step 3: Run the architecture test (PASS) + the FULL backend suite (no behavior change on unix — every replacement is semantics-preserving there).** Any test that breaks = you changed semantics at that site; re-read it. Also append `test/valea/paths_boundary_test.exs` to the bring-up workflow's gating paths step (created in Task 3 Step 7) so the guard runs on the Windows lane from here on.

- [ ] **Step 4: Commit:** `feat(backend): route all path absoluteness/ancestry through Valea.Paths (windows spec D4) — grep-empty enforced by paths_boundary_test`

- [ ] **Step 5: Native-Windows gate (this task rewired every containment site — it gets its own gate, not a free ride on Task 3's).** Extend the bring-up workflow's GATING step to `mix test test/valea/paths_test.exs test/valea/paths_boundary_test.exs` plus the test files of the migrated modules that exist (check and list them: the mounts, permission-policy, icm/api-icm, calendar-local, and files-controller suites under `backend/test/`). Dispatch; complete only on green. Ledger the run URL.

---

### Task 5: `valea-spawn` shim + Windows packaging + sidecar Job Object (spec B2, E1)

**Files:**
- Create: `desktop/src-tauri/src/bin/valea_spawn.rs`
- Modify: `desktop/src-tauri/Cargo.toml` (`[[bin]]`, windows-only deps)
- Create: `desktop/src-tauri/tauri.windows.conf.json`
- Modify: `desktop/src-tauri/src/main.rs` (`start_sidecar`: `VALEA_SPAWN_SHIM` env + E1 Job Object for the sidecar)
- Modify: `Justfile` + `.github/workflows/windows-bringup.yml` (build+copy the shim before `tauri build` on Windows)
- Test: `desktop/src-tauri/tests/spawn_shim.rs` (`#[cfg(windows)]`)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (Task 6 relies on these exact semantics): shim invoked as `valea-spawn <cmd> [args…]`; env `VALEA_SPAWN_STDERR_FILE` (required — missing ⇒ exit code 64 immediately); stdin/stdout passed through; child tree in a kill-on-close Job; **stdin EOF ⇒ whole tree dies**; shim exit code = child exit code. Bundled name: `valea-spawn.exe` next to the app executable (Tauri externalBin layout); `start_sidecar` passes its absolute path as `VALEA_SPAWN_SHIM` to `valea-server`.

- [ ] **Step 1: Cargo wiring**

```toml
# Cargo.toml additions
[[bin]]
name = "valea-spawn"
path = "src/bin/valea_spawn.rs"

[target.'cfg(windows)'.dependencies]
windows = { version = "0.58", features = [
  "Win32_Foundation",
  "Win32_System_JobObjects",
  "Win32_System_Threading",
] }
```

- [ ] **Step 2: The shim.** `src/bin/valea_spawn.rs` — non-Windows builds get a stub so `cargo check` stays green on every host:

```rust
// valea-spawn (windows-support spec B2): Job-Object process shim.
// Erlang Ports can neither separate stderr nor kill a Windows process
// tree; this binary does both. Contract: see the spec — stdin EOF is the
// kill switch, exit code mirrors the child.
#[cfg(not(windows))]
fn main() {
    eprintln!("valea-spawn is Windows-only");
    std::process::exit(64);
}

#[cfg(windows)]
fn main() {
    std::process::exit(win::run());
}

#[cfg(windows)]
mod win {
    use std::io::{copy, Read, Write};
    use std::os::windows::io::AsRawHandle;
    use std::process::{Command, Stdio};
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::System::JobObjects::*;

    const CAP: u64 = 1024 * 1024; // 1 MiB stderr cap (spec B2)

    pub fn run() -> i32 {
        let mut args = std::env::args_os().skip(1);
        let Some(cmd) = args.next() else { return 64 };
        let Ok(stderr_path) = std::env::var("VALEA_SPAWN_STDERR_FILE") else { return 64 };

        // Job first, child second, assign before any pumping.
        let job = unsafe { CreateJobObjectW(None, None) }.expect("job");
        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job, JobObjectExtendedLimitInformation,
                &info as *const _ as _, std::mem::size_of_val(&info) as u32,
            ).expect("job limits");
        }

        // Spec B3: CreateProcess cannot execute .cmd/.bat directly — batch
        // targets route through COMSPEC, and the shim owns the quoting.
        let mut command = match build_command(&cmd, args) {
            Some(c) => c,
            None => return 64, // embedded-quote arg to a batch target: unquotable for cmd.exe
        };
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn");
        unsafe {
            AssignProcessToJobObject(job, HANDLE(child.as_raw_handle() as _)).expect("assign");
        }

        let mut child_stdin = child.stdin.take().unwrap();
        let mut child_stdout = child.stdout.take().unwrap();
        let mut child_stderr = child.stderr.take().unwrap();

        // Pump 1: our stdin -> child stdin. EOF here = owner closed the Port
        // = shutdown: closing the job handle on process exit kills the tree.
        std::thread::spawn(move || {
            let _ = copy(&mut std::io::stdin().lock(), &mut child_stdin);
            // stdin EOF: exit the whole shim; job kill-on-close reaps the tree.
            std::process::exit(120);
        });
        // Pump 2: child stdout -> our stdout (NDJSON passthrough).
        let out = std::thread::spawn(move || {
            let _ = copy(&mut child_stdout, &mut std::io::stdout().lock());
        });
        // Pump 3: child stderr -> capped file (share-read).
        let err = std::thread::spawn(move || {
            let mut f = std::fs::File::create(&stderr_path).expect("stderr file");
            let mut buf = [0u8; 8192];
            let mut written: u64 = 0;
            loop {
                match child_stderr.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if written < CAP {
                            let take = ((CAP - written).min(n as u64)) as usize;
                            let _ = f.write_all(&buf[..take]);
                            written += take as u64;
                            if written >= CAP {
                                let _ = f.write_all(b"\n[truncated]\n");
                            }
                        }
                    }
                }
            }
        });

        let status = child.wait().expect("wait");
        let _ = out.join();
        let _ = err.join();
        status.code().unwrap_or(1)
        // job handle drops here -> kill-on-close reaps any grandchildren
    }

    /// Direct spawn for real executables; `cmd.exe /d /s /c "<one quoted
    /// line>"` for .cmd/.bat (via raw_arg — the only reliable quoting for
    /// cmd.exe). Returns None for args containing `"` when the target is a
    /// batch file: there is no safe way to quote those for cmd.exe, and the
    /// agent argv never legitimately contains them — fail loud (exit 64).
    fn build_command(
        cmd: &std::ffi::OsString,
        args: impl Iterator<Item = std::ffi::OsString>,
    ) -> Option<Command> {
        use std::os::windows::process::CommandExt;

        let is_batch = std::path::Path::new(cmd)
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("cmd") || e.eq_ignore_ascii_case("bat"))
            .unwrap_or(false);

        if !is_batch {
            let mut c = Command::new(cmd);
            c.args(args);
            return Some(c);
        }

        let mut line = String::from("/d /s /c \"");
        line.push('"');
        line.push_str(cmd.to_str()?);
        line.push('"');
        for a in args {
            let a = a.to_str()?.to_string();
            if a.contains('"') {
                return None;
            }
            line.push_str(" \"");
            line.push_str(&a);
            line.push('"');
        }
        line.push('"');

        let comspec = std::env::var_os("COMSPEC").unwrap_or_else(|| "cmd.exe".into());
        let mut c = Command::new(comspec);
        c.raw_arg(line);
        Some(c)
    }
}
```

Verify on macOS: `cargo check` (stub path) — green.

- [ ] **Step 3: Platform config + packaging.** `tauri.windows.conf.json`:

```json
{
  "bundle": {
    "externalBin": ["binaries/valea-server", "binaries/valea-spawn"]
  }
}
```

Justfile — add after the sidecar copy in `package-backend` (inside the existing bash recipe):

```bash
    case "$BURRITO_TARGET" in
      windows_*)
        (cd desktop/src-tauri && cargo build --release --bin valea-spawn)
        cp desktop/src-tauri/target/release/valea-spawn.exe \
           "desktop/src-tauri/binaries/valea-spawn-${triple}.exe"
        ;;
    esac
```

(The bring-up workflow needs no change — it calls `just package-backend`.)

- [ ] **Step 4: `start_sidecar` — shim env + E1 Job Object.** In `main.rs`:

```rust
    #[cfg(windows)]
    let spawn_shim = std::env::current_exe()?
        .parent()
        .map(|d| d.join("valea-spawn.exe"))
        .filter(|p| p.exists());

    let mut cmd = app.shell().sidecar("valea-server")?
        .env("PHX_SERVER", "true")
        // ... existing envs unchanged ...
        ;
    #[cfg(windows)]
    if let Some(shim) = &spawn_shim {
        cmd = cmd.env("VALEA_SPAWN_SHIM", shim);
    }
    let (_rx, child) = cmd.spawn()?;

    // E1: the Burrito wrapper can't exec() on Windows — child.kill() would
    // orphan the BEAM. Put the sidecar in a kill-on-close Job. The returned
    // Job OWNS the handle: dropping a kill-on-close handle CLOSES it and
    // kills the sidecar instantly, so it must live in managed state until
    // process exit (where its Drop reaps any stragglers — desired).
    #[cfg(windows)]
    {
        let job = winjob::Job::assign_kill_on_close(child.pid())?;
        app.state::<SidecarJob>().0.lock().unwrap().replace(job);
    }
```

with, alongside the existing `Backend` state:

```rust
/// Owns the sidecar's kill-on-close Job handle for the app's lifetime
/// (windows-support spec E1). Never read — existence IS the semantics.
#[cfg(windows)]
struct SidecarJob(Mutex<Option<winjob::Job>>);
```

registered in `main()` next to `.manage(Backend(...))` (`#[cfg(windows)]` split the builder: `let builder = tauri::Builder::default()…; #[cfg(windows)] let builder = builder.manage(SidecarJob(Mutex::new(None)));`). `winjob::Job` (new `desktop/src-tauri/src/winjob.rs`, shared by `main.rs`) wraps the `HANDLE` from `CreateJobObjectW` + `SetInformationJobObject(kill-on-close)` + `AssignProcessToJobObject` via `OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, …)` on the pid, and `impl Drop` closes it. The shim keeps its own ~20-line copy (separate binary, not worth a crate).

- [ ] **Step 5: Windows-only integration tests** (`tests/spawn_shim.rs`, `#![cfg(windows)]`): spawn the built shim against `cmd /c` scripts asserting (a) exit-code passthrough, (b) stdout passthrough ≥ 50 MB uncorrupted, (c) stderr file capped with `[truncated]`, (d) closing shim stdin kills a `cmd /c "start /b notepad & ping -n 60 127.0.0.1"` tree (no survivor via `tasklist`), (e) missing `VALEA_SPAWN_STDERR_FILE` ⇒ exit 64, (f) a `.cmd` target in a path WITH SPACES receiving spaced args echoes them back faithfully (COMSPEC route), (g) an embedded-`"` arg to a `.cmd` target ⇒ exit 64 (the documented unquotable bound). These run in the bring-up lane: add `cargo test --release --test spawn_shim` to `windows-bringup.yml` after the bundle step.

- [ ] **Step 6: `cargo check` (macOS) + commit:** `feat(desktop): valea-spawn Job-Object shim + Windows sidecar job (windows spec B2/E1)`

- [ ] **Step 7: Native-Windows gate.** The `cargo test --release --test spawn_shim` step added to `windows-bringup.yml` in Step 5 is GATING (no `continue-on-error`). Dispatch; the task is complete only when the shim test suite is green on `windows-latest` — macOS `cargo check` alone never closes this task. Ledger the run URL.

---

### Task 6: ProcessAdapter — facade, Port adapter, platform env, doctor + fixtures (spec B1, B3-remainder, B4, B5, A1-assertion)

**Files:**
- Create: `backend/lib/valea/agents/process_runtime/exec.ex` (today's `process_runtime.ex` body, renamed module `Valea.Agents.ProcessRuntime.Exec`)
- Create: `backend/lib/valea/agents/process_runtime/port_shim.ex`
- Rewrite: `backend/lib/valea/agents/process_runtime.ex` (facade + behaviour)
- Modify: `backend/lib/valea/application.ex` (boot-time adapter selection — spec B1)
- Modify: `backend/lib/valea/agents/session_server.ex` (stderr path into the start spec, BEFORE `ProcessRuntime.start` — see Step 3a)
- Modify: `backend/lib/valea/agents/env.ex`
- Modify: `backend/lib/valea/harnesses/claude_code.ex` (PATHEXT fallback)
- Modify: `backend/lib/valea/agents/doctor.ex:190-233` (`run_cmd` through the facade)
- Create: `backend/test/support/platform_fixtures.ex`
- Modify: `backend/test/valea/agents/doctor_test.exs`, `backend/test/valea/agents/process_runtime_test.exs`, `backend/test/test_helper.exs` (`:unix_only` exclusion)

**Interfaces:**
- Consumes: shim contract from Task 5 (`VALEA_SPAWN_SHIM`, `VALEA_SPAWN_STDERR_FILE`, exit-code mirror, stdin-EOF kill); `Valea.Paths.absolute?/1` (Task 3).
- Produces: `Valea.Agents.ProcessRuntime` keeps its EXACT public API (`start/2`, `write/2`, `stop/1`, owner messages `{:runtime_output, binary}`, `{:runtime_stderr, binary}`, `{:runtime_exit, code | nil}`) — `SessionServer` does not change. New behaviour `Valea.Agents.ProcessAdapter` with those three callbacks. `Valea.Agents.Env.allowlist/0` becomes platform-selected.

- [ ] **Step 1: Behaviour + facade — selection ONCE at boot, with a test seam (failing tests first):**

```elixir
# tests: process_runtime_test.exs
test "facade routes through the boot-selected adapter (app-env seam)" do
  Application.put_env(:valea, :process_adapter, __MODULE__.FakeAdapter)
  on_exit(fn -> Valea.Agents.ProcessRuntime.select_adapter!() end)

  assert {:ok, %{fake: true}} = Valea.Agents.ProcessRuntime.start(%{cmd: "x", args: []}, self())
end

test "boot selection matches the host platform" do
  # This suite runs on BOTH lanes (Windows full-suite gate, Step 8) — the
  # expectation must branch, never hardcode Exec.
  Valea.Agents.ProcessRuntime.select_adapter!()

  expected =
    case :os.type() do
      {:win32, _} -> Valea.Agents.ProcessRuntime.PortShim
      _ -> Valea.Agents.ProcessRuntime.Exec
    end

  assert Valea.Agents.ProcessRuntime.adapter() == expected
end

test "Exec's A1 assertion names the failure when :exec is unavailable" do
  assert_raise RuntimeError, ~r/erlexec unavailable.*spec A1/, fn ->
    Valea.Agents.ProcessRuntime.Exec.ensure_available!(false)
  end
end
```

(`FakeAdapter`: a test-module with `start/2 → {:ok, %{fake: true}}`, `write/2`/`stop/1 → :ok`.) Then:

```elixir
defmodule Valea.Agents.ProcessAdapter do
  @callback start(map(), pid()) :: {:ok, map()} | {:error, String.t()}
  @callback write(map(), iodata()) :: :ok
  @callback stop(map()) :: :ok
end

defmodule Valea.Agents.ProcessRuntime do
  @behaviour Valea.Agents.ProcessAdapter
  # Selection happens ONCE at boot (spec B1): Valea.Application.start/2 calls
  # select_adapter!/0. The app-env slot doubles as the test seam —
  # `Application.put_env(:valea, :process_adapter, Fake)` in a test, reset via
  # select_adapter!/0 in on_exit. The erlexec module is not even compiled into
  # Windows releases (mix.exs platform_deps, spec A1).
  def select_adapter!,
    do: Application.put_env(:valea, :process_adapter, default_adapter())

  def adapter,
    do: Application.get_env(:valea, :process_adapter) || default_adapter()

  defp default_adapter do
    case :os.type() do
      {:win32, _} -> Valea.Agents.ProcessRuntime.PortShim
      _ -> Valea.Agents.ProcessRuntime.Exec
    end
  end

  def start(spec, owner), do: adapter().start(spec, owner)
  def write(handle, data), do: adapter().write(handle, data)
  def stop(handle), do: adapter().stop(handle)
end
```

In `Valea.Application.start/2`, first line of `start/2`: `Valea.Agents.ProcessRuntime.select_adapter!()`. `Exec` gains `def ensure_available!(loaded? \\ Code.ensure_loaded?(:exec))` raising `"erlexec unavailable — unix adapter selected on a build without it (windows-support spec A1)"` when false; `Exec.start/2` calls it first.

- [ ] **Step 2: Move today's implementation to `Exec`** (module rename only, zero body changes), run the existing process-runtime tests against `Valea.Agents.ProcessRuntime` (facade) — green proves the facade is transparent.

- [ ] **Step 3: PortShim adapter.** Mirrors Exec's relay shape with a Port:

```elixir
defmodule Valea.Agents.ProcessRuntime.PortShim do
  @behaviour Valea.Agents.ProcessAdapter
  @stderr_tail_bytes 64 * 1024

  def start(%{cmd: cmd} = spec, owner) do
    with {:ok, shim} <- shim_path(),
         true <- File.exists?(cmd) || {:error, "executable not found: #{cmd}"} do
      stderr_file = stderr_path(spec)
      relay = spawn_relay(shim, spec, stderr_file, owner)
      # same {:relay_started, os_pid} handshake + timeout as Exec
    end
  end

  defp shim_path do
    case System.get_env("VALEA_SPAWN_SHIM") do
      nil -> {:error, "spawn shim missing — reinstall Valea (windows spec B2)"}
      p -> if File.exists?(p), do: {:ok, p}, else: {:error, "spawn shim missing at #{p}"}
    end
  end

  # Port.open({:spawn_executable, shim}, [:binary, :exit_status, :hide,
  #   {:args, [spec.cmd | spec.args]}, {:cd, spec.cd},
  #   {:env, env_charlists(spec.env, stderr_file)}])
  # relay loop: {port, {:data, d}} -> {:runtime_output, d}
  #             {port, {:exit_status, code}} -> emit_stderr_tail(); {:runtime_exit, code}
  #             {:write, d} -> Port.command(port, d)
  #             :stop -> Port.close(port); emit_stderr_tail(); {:runtime_exit, nil}
end
```

The stderr path arrives in the spec map as `spec.stderr_path` (Step 3a wires it) — PortShim requires it: absent ⇒ `{:error, "stderr path missing (windows spec B2)"}`. `emit_stderr_tail/…` reads the last `@stderr_tail_bytes`, sends `{:runtime_stderr, tail}` only if non-empty. Tests (portable, no real shim needed): a fake "shim" shell/exe fixture from Step 6's helper; on unix hosts point the Port at a `sh` fixture that mimics the contract — the adapter itself is platform-neutral Port code, only its *selection* is Windows-bound.

- [ ] **Step 3a: SessionServer stderr-path wiring (ordering matters — Codex round 1).** `SessionServer` calls `ProcessRuntime.start/2` with the spec map BEFORE `open_transcript/2` runs (session_server.ex:127-135 vs :151), and the transcript is a flat file `logs/sessions/<id>.jsonl` (:465) — there is no per-session directory. So: where the start-spec map is built, compute and create the path first:

```elixir
    stderr_path =
      Path.join([
        scope.workspace.root,
        "logs",
        "sessions",
        id <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])) <> ".stderr.log"
      ])

    File.mkdir_p!(Path.dirname(stderr_path))
```

and add `stderr_path: stderr_path` to the map handed to `ProcessRuntime.start/2` (`Exec` ignores the extra key; `PortShim` requires it). Same `logs/sessions/` home as the transcript ⇒ same retention, per spec §B2. Extend the existing session-server test that asserts the start-spec shape (or add one) to pin the key's presence and its `logs/sessions/` prefix.

- [ ] **Step 4: Env B4 (failing test → impl):**

```elixir
test "windows allowlist carries profile/appdata/pathext, unix stays unchanged" do
  assert "SystemRoot" in Valea.Agents.Env.allowlist(:windows)
  assert "USERPROFILE" in Valea.Agents.Env.allowlist(:windows)
  refute "SystemRoot" in Valea.Agents.Env.allowlist(:unix)
  refute Enum.any?(Valea.Agents.Env.allowlist(:windows), &(&1 == "SECRET_KEY_BASE"))
end
```

```elixir
@unix_allowlist ~w(HOME PATH USER LOGNAME LANG LC_ALL LC_CTYPE TMPDIR SHELL ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)
@windows_allowlist ~w(PATH USERPROFILE APPDATA LOCALAPPDATA PATHEXT COMSPEC SystemRoot SystemDrive TEMP TMP ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)
def allowlist(platform \\ Valea.Paths.host_platform())
def allowlist(:windows), do: @windows_allowlist
def allowlist(_), do: @unix_allowlist
```

(`minimal/0` reads `allowlist()`.)

- [ ] **Step 5: PATHEXT fallback in `claude_code.ex` (B3 remainder):** after `System.find_executable(cmd)` returns nil on `:windows`, try `Enum.find_value(extensions_from_pathext(), fn ext -> System.find_executable(cmd <> ext) end)` with default `~w(.exe .cmd .bat .com)`. Test with a temp dir on PATH containing `probe.cmd`. Windows install-location discovery lives in `Valea.Harnesses.ClaudeCode` too — the doctor has NO candidate list of its own (`adapter_check` resolves solely via `ClaudeCode.acp_command/1`, doctor.ex:107). The candidates are derived from the **configured command name** (default `claude-agent-acp`, `Valea.App.Config` `@default_harness_command`) — NEVER a hardcoded `claude` basename: `claude.exe` is the interactive CLI, not the ACP adapter, and resolving it would spawn the wrong protocol executable (Codex round 3). After `find_executable` + PATHEXT both miss on `:windows`, for the bare configured name `cmd` probe, in order: `Path.join([System.get_env("APPDATA") || "", "npm", cmd <> ".cmd"])`, then `Path.join([System.get_env("USERPROFILE") || "", ".local", "bin", cmd <> ".exe"])` and the same with `.cmd` — first existing wins. Verify these locations against a real Windows install of the adapter during the Step 8 gate run and adjust there if the installer layout differs.

- [ ] **Step 6: Doctor through the facade + fixture split.** Replace `doctor.ex`'s `exec_and_await/3` internals with `ProcessRuntime.start/2` + the same receive/timeout/collect loop over the runtime messages (`stop/1` on timeout — group-kill semantics preserved on unix via Exec, Job semantics on windows via PortShim). Doctor probes have no session, so their spec map sets `stderr_path: Path.join(System.tmp_dir!(), "valea-doctor-#{System.unique_integer([:positive])}.stderr.log")`, best-effort `File.rm/1` after collection. Create `test/support/platform_fixtures.ex`:

```elixir
defmodule Valea.PlatformFixtures do
  @doc "Writes an executable script fixture, .sh on unix / .cmd on windows; returns its path."
  def script!(dir, name, unix_body, windows_body) do
    case :os.type() do
      {:win32, _} ->
        path = Path.join(dir, name <> ".cmd")
        File.write!(path, windows_body)
        path
      _ ->
        path = Path.join(dir, name <> ".sh")
        File.write!(path, "#!/bin/sh\n" <> unix_body)
        File.chmod!(path, 0o755)
        path
    end
  end
end
```

Migrate `doctor_test.exs`'s `#!/bin/sh`/`chmod` fixtures to it, **and `process_runtime_test.exs` likewise** — it hardcodes `cat` (`:6`), `sh` heredoc scripts (`:20`, `:42`), and asserts group-kill via `pgrep -g` (`:61`); this suite MUST pass on the Windows lane (Step 8 flips the full suite to gating), so: portable cases go through `Valea.PlatformFixtures.script!/4`, the `pgrep -g` group-kill assertion is tagged `@tag :unix_only` (excluded on windows via `ExUnit.configure(exclude: [:unix_only])` in `test_helper.exs` by `:os.type()`), and a Windows twin asserts no surviving child via `tasklist` after `stop/1`. Same tagging discipline for any doctor test the survey flags.

- [ ] **Step 7: Full backend suite green (mac). Commit:** `feat(backend): ProcessAdapter facade + Windows Port/shim adapter, platform env allowlist, PATHEXT resolution, doctor via adapter (windows spec B1,B3-B5)`

- [ ] **Step 8: Native-Windows gate — the suite goes gating.** By this task, paths (T3) + fixtures/adapter (this task) should make the full backend suite pass on Windows: flip the bring-up workflow's survey step to gating (remove `continue-on-error: true`, drop the "survey" framing from its name). Dispatch; complete only on a green full suite on `windows-latest`. Any residual red = fix here, not defer. Ledger the run URL.

---

### Task 7: Maildir separator per store (spec C1, C2, C3)

**Files:**
- Modify: `backend/lib/valea/mail/maildir.ex:12,32-43` (codec)
- Modify: `backend/lib/valea/mail/account.ex` (separator field)
- Modify: callers (compiler-forced by the new arity): `backend/lib/valea/mail/sync_pass.ex:560,644-645,758` (+ parse at `:799` — unchanged), `backend/lib/valea/mail/reconcile.ex:134,291`, `backend/lib/valea/mail/ops_executor.ex:1140-1141,1556,1809`, plus every other `encode_filename` caller the compiler reveals (incl. delivery in `maildir.ex` itself)
- Modify: `backend/lib/valea/mail/engine.ex` (read separator at activation, thread into the ctx those modules receive)
- Test: `backend/test/valea/mail/maildir_test.exs`, `backend/test/valea/mail/account_test.exs`, new `backend/test/valea/mail/separator_matrix_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Maildir.encode_filename(msg_id, uid, flags, separator)` — **/4, no default** (the compiler is the completeness audit); `Maildir.parse_filename/1` tolerant of both `:` and `;`; `Account.separator(root, slug) :: {:ok, ":" | ";"} | {:error, :invalid_separator}` (absent file or absent key ⇒ `{:ok, ":"}` — legacy rule); `Account.write_if_absent!/4` (`identity` + `separator`).

- [ ] **Step 1: Failing codec tests:**

```elixir
test "encode/4 uses the store separator" do
  flags = MapSet.new(["F", "S"])
  assert Maildir.encode_filename("2026-07-15-alex-4f2a91c3", 42, flags, ":") ==
           "2026-07-15-alex-4f2a91c3,U=42:2,FS"
  assert Maildir.encode_filename("2026-07-15-alex-4f2a91c3", 42, flags, ";") ==
           "2026-07-15-alex-4f2a91c3,U=42;2,FS"
end

test "parse accepts both separators and excludes both from msg_id" do
  assert {:ok, %{msg_id: "m", uid: nil}} = Maildir.parse_filename("m:2,")
  assert {:ok, %{msg_id: "m", uid: 7}} = Maildir.parse_filename("m,U=7;2,S")
  assert :error = Maildir.parse_filename("a;b:2,")   # separator chars illegal inside msg_id
end
```

- [ ] **Step 2: Implement codec:** regex → `~r/^(?<id>[^,:;]+)(,U=(?<uid>\d+))?[:;]2,(?<flags>[A-Za-z]*)$/`; `encode_filename/4` with `when separator in [":", ";"]`, interpolating `separator` where `:` was. Delete `/3`. `mix compile` now lists every caller — that list IS the C3 threading worklist; fix each by passing the ctx separator (Step 4).

- [ ] **Step 3: Account field (failing tests → impl):** `write_if_absent!(root, slug, identity, separator)` renders a third line `maildir_separator: ";"` (same `yaml_string/1` hardening); `separator/2` per Interfaces (parse failure or a value outside `[":", ";"]` ⇒ `{:error, :invalid_separator}`); `verify/3` UNCHANGED (separator is store metadata, not identity). Tests: absent file ⇒ `{:ok, ":"}`; legacy file without the key ⇒ `{:ok, ":"}`; `";"` round-trips; `"|"` ⇒ error.

- [ ] **Step 4: Thread it.** In `engine.ex` activation (where `Account.verify/3` + `write_if_absent!` already run): choose `separator = case Valea.Paths.host_platform() do :windows -> ";"; _ -> ":" end` for NEW stores, pass to `write_if_absent!/4`; then `Account.separator(root, slug)` and put it into the same ctx/args structs handed to `SyncPass`/`Reconcile`/`OpsExecutor` (follow each compiler error to its ctx). `{:error, :invalid_separator}` at activation ⇒ the same sticky failure path as `:identity_mismatch` (reuse it; message "invalid maildir_separator in .account").

- [ ] **Step 5: Matrix test** (`separator_matrix_test.exs`): build a `;`-store via the existing test helpers (whatever `sync_pass_test`/`ops_executor_test` use to fabricate stores — reuse those factories), then: deliver → flag rename → move → reconcile pass → recovery lookup, asserting every produced filename contains `;2,` and none contain `:2,`; plus one listing containing BOTH separators parses fully. C2: add a `File.rename!` onto-existing-target test in `maildir_test.exs` (documents the semantics; runs everywhere, meaningful on the Windows lane).

- [ ] **Step 5b: C3 literal-filename audit (spec §C3 — the compiler sweep is NOT this).** The `/4` arity change finds every *encoder*; C3 is about sites that **persist or parse** literal maildir filenames, which the compiler cannot flag. Grep-driven pass: `grep -rn "filename" backend/lib/valea/mail/message_file.ex backend/lib/valea/mail/views.ex backend/lib/valea/mail/index*.ex backend/lib/valea/mail/reconcile.ex` plus every `parse_filename` call site (`grep -rn "parse_filename" backend/lib`). For each hit, record in a checklist (goes verbatim into the PR description): the site either (a) re-encodes from structured `{msg_id, uid, flags}` — fine, (b) parses via `parse_filename/1` — fine (tolerant since Step 2), or (c) string-matches/persists a literal filename — fix it to (a) or (b). Known anchor: `message_file.ex:148` embeds the maildir filename in derived-view frontmatter — verify its readers re-derive rather than string-match the separator.

- [ ] **Step 6: Full mail suite + full backend suite green (mac). Commit:** `feat(backend): per-store maildir separator in .account — ';' on Windows, tolerant parser, compiler-forced threading (windows spec C1-C3)`

- [ ] **Step 7: Native-Windows gate.** Dispatch `windows-bringup.yml` (suite is gating since Task 6); complete only on green — this is where C2's `File.rename` semantics and the `;`-store matrix actually run on NTFS. Ledger the run URL.

---

### Task 8: Release lane, chrome audit, docs, acceptance (spec E2, E3, A4, F + RELEASING/spec-index updates)

**Files:**
- Modify: `.github/workflows/release.yml` (add the windows matrix entry)
- Delete: `.github/workflows/windows-bringup.yml`
- Modify: `frontend/src/lib/components/shell/Sidebar.svelte` + `frontend/src/routes/+layout.svelte` (overlay-chrome gating — E2)
- Modify: `docs/RELEASING.md` ("Windows" blockers section → runbook)
- Modify: `docs/ARCHITECTURE.md` (spec-index entry → Shipped; Release section gains the Windows row)
- Create: `docs/superpowers/acceptance/2026-07-19-windows-support.md`

**Interfaces:**
- Consumes: everything prior; the bring-up lane must have produced a bootable NSIS bundle before this task lands (gate: do not start Task 8 otherwise).

- [ ] **Step 1: Matrix entry** in `release.yml` (mirror of the bring-up steps, minus the survey run):

```yaml
          - os: windows-latest
            burrito_target: windows_x64
```

and — **this is load-bearing (Codex round 1)** — widen the BEAM install step: `release.yml`'s `erlef/setup-beam` step is currently `if: runner.os == 'Linux'` (line 69), so a Windows entry would reach `mix` with no Erlang/Elixir. Change that step to `if: runner.os != 'macOS'` and rename it "Install Erlang/Elixir (Linux/Windows)" (macOS keeps its asdf path). Keep the Linux-only apt step guarded as-is; the shim build/copy rides inside `just package-backend` already. Extend the dry-run artifact `path:` list with the NSIS globs (`bundle/nsis/*.exe`, `*.exe.sig`). Delete `windows-bringup.yml` in the same commit. Update the top-of-file comment (three platforms now) and the matrix's "No Windows lane" comment — it's a lane now.

- [ ] **Step 2: E2 chrome gating.** The overlay-title-bar compensation currently keys on `inDesktop()` alone — TRUE on Windows too, where decorations are standard and there are no traffic lights: `Sidebar.svelte`'s brand band (`desktop ? 'pt-12' : 'pt-4'` + `data-tauri-drag-region` + `pointer-events-none` children) would waste a 48px strip, and `+layout.svelte`'s fixed top drag strip is pointless under a native title bar. Extract one helper — `export function overlayChrome(): boolean { return inDesktop() && navigator.userAgent.includes('Macintosh'); }` (put it next to `inDesktop` in `$lib/keychain.ts`'s consumer, or a tiny `$lib/shell/platform.ts`; UA check is adequate for the three webviews, no Tauri API needed) — and switch both files' `desktop` consts to it. Verify in browser (non-mac UA emulation via devtools): no dead strip, brand band back to `pt-4`; screenshot for the PR. macOS behavior unchanged.

- [ ] **Step 3: E3/A4 verifications on the Windows VM** (with Task 1-7 merged and a real tag built): updater `windows-x86_64` entry present in `latest.json`; NSIS passive update N→N+1; IMAPS connect trusts a public CA via the OS store (A4). Record outcomes in the acceptance doc.

- [ ] **Step 4: Acceptance doc** — create `docs/superpowers/acceptance/2026-07-19-windows-support.md` with the spec's 7 acceptance items as checkboxes (fresh install→agent round-trip incl. Task-Manager orphan check **and the CLAUDE.md symlink-fallback verification: on a VM without developer mode, a freshly created ICM's `CLAUDE.md` is the literal one-line `@AGENTS.md` file, no error surfaced** — spec Ground truth "verify, don't build"; mail `;2,` E2E; calendar; kill→relaunch no PortCollision; auto-update N→N+1; cross-OS workspace honest-fail; UNC share ICM incl. `..`-above-root deny + best-effort watcher doctor line), each with its manual procedure, mirroring `docs/superpowers/acceptance/2026-07-18-calendar-feeds.md`'s format.

- [ ] **Step 5: Docs.** `RELEASING.md`: replace the "Windows" blocker section with the lane runbook — platforms table row (NSIS + AppImage-style updater note), SmartScreen expectation (unsigned; Authenticode = follow-up secret like Apple notarization), "moving workspaces" hard edge (`:`-store on NTFS), network-share notes (SMB reparse trust caveat, watcher best-effort, profile pinned local), **and the spec-D6 line: OneDrive/Dropbox cloud-placeholder locations are unsupported for workspaces/ICMs**. `ARCHITECTURE.md`: flip the windows spec index entry to **Shipped**, add one sentence + the Windows row to "Release & auto-update", **and add the spec-D7 SMB limitation to the "Trust model" section** (the repo has no separate security notes file — Trust model IS that surface): server-side reparse points on a network share are invisible to client-side containment; the share's configuration is part of the trust boundary.

- [ ] **Step 6: Full `just test` + workflow YAML parse + commit:** `ci: promote Windows to the release matrix; chrome audit, runbook + acceptance doc (windows spec T5)`

---

## Plan self-review (done at write time)

- **Spec coverage:** A1 (T1+T6 assertion), A2 (T1), A3 (T1 survey), A4 (T8), A5 (T2), A6 (T1), B1 (T6), B2 (T5), B3 (T4 absoluteness + T6 PATHEXT), B4 (T6), B5 (T6), C1-C3 (T7), D1-D3 (T3), D4 (T4), D5 (T3), D6 (no code — doc note lands in T8's RELEASING sweep), D7 (T8 docs), E1 (T5), E2 (T8), E3 (T8), F (T1 bring-up → T8 promotion). No orphans.
- **Known intentional deviations:** none from the spec's T1-T5 ordering — plan tasks 1-8 are the same sequence at reviewable granularity (spec T1→plan 1-2, T2→3-4, T3→5-6, T4→7, T5→8).
- **Type consistency check:** `encode_filename/4` (T7 interfaces = T7 steps); `ProcessRuntime` facade keeps `start/2,write/2,stop/1` (T6 = spec B1); `default_dir/2` (T1 test = T1 impl); shim exit 64/120 and `VALEA_SPAWN_*` names consistent between T5 and T6; `watching?/1` + `watched_roots/1` optional-server args (T2 test = T2 impl = doctor call sites).

### Codex round 1 (2026-07-19) — all findings verified against the tree, all folded

Blocking: release.yml BEAM install widened to Windows (T8); T2 test rewritten (own describe/setup, `name:` seam — the file's existing setup opens a workspace and owns the singleton) and doctor integration moved into the existing `watcher_live_check/1` (a disabled watcher must read as `unknown`, never `failed`-stale); T6 gained Step 3a (SessionServer computes `stderr_path` under `logs/sessions/` BEFORE `ProcessRuntime.start`; flat-file transcript, no per-session dir) + doctor tmp-path line; T1 zig guard made `.exe`-aware with `unzip -o` and `Windows_NT` host arms added; native-Windows CI gates added to T3/T5/T6/T7 (T6 flips the suite from survey to gating). Nice-to-haves: CLAUDE.md fallback verification in T8 acceptance; D6 cloud-placeholder + D7 Trust-model doc lines pinned to concrete surfaces; adapter selection moved to boot (`select_adapter!/0` from `Application.start/2`) with the app-env slot as the test seam — note: `adapter/0` still *reads* the slot per call (fast app-env lookup); the *decision* happens once at boot, which is the spec §B1 property that matters.

### Codex round 2 (2026-07-26) — all findings verified against the tree, all folded

Round-1 folds confirmed landed (7 full, 2 partial — both partials fixed). Blockers: Task 3's Windows gate now runs `paths_test.exs` only (`paths_boundary_test.exs` joins the gate in Task 4, which creates it); Task 5's Job Object is OWNED (`SidecarJob` managed state holding `winjob::Job` whose Drop closes the handle — the round-2 snippet dropped a kill-on-close handle immediately, which would have killed the sidecar at spawn); Task 6's selection test branches its expectation by `:os.type()` (an unconditional `Exec` assertion would fail the Windows full-suite gate this same plan mandates). Majors: bring-up workflow gained `mix deps.get` (mix test does not auto-fetch); the shim gained `build_command/2` — `.cmd`/`.bat` route through `COMSPEC /d /s /c` with `raw_arg` single-line quoting, embedded-`"` args to batch targets fail loud with exit 64 (documented bound), tests (f)/(g) pin both; Windows install-location discovery assigned to `Valea.Harnesses.ClaudeCode` (the doctor has no candidate list — `adapter_check` resolves via `acp_command/1` only), candidates `%USERPROFILE%\.local\bin\claude.exe` + `%APPDATA%\npm\claude.cmd`, verify-at-gate; `process_runtime_test.exs` (`cat`/`sh`/`pgrep -g`) explicitly added to the Task 6 fixture migration with a `tasklist` twin. Minor: Task 2's Files bullet no longer contradicts its body (integrate existing `watcher_live`, no new check id).

### Codex round 3 (2026-07-26) — all findings verified, all folded

Round-2 fold audit: 7 PASS, 1 FAIL — the FAIL was the sharpest catch of all three rounds: my Windows discovery candidates hardcoded `claude.exe`/`claude.cmd`, but the harness command is `claude-agent-acp` (`Valea.App.Config` `@default_harness_command`) — resolving the interactive CLI as the ACP adapter would have spawned the wrong protocol executable. Candidates are now derived from the configured command name (`%APPDATA%\npm\<cmd>.cmd`, `%USERPROFILE%\.local\bin\<cmd>.exe|.cmd`), verify-at-gate. New findings folded: `drive_abs?` required the slash (`C:` is drive-RELATIVE — "current dir on C" — my `(/|$)` regex mis-classified it; test pins it); Task 2 gained Step 3b proving a real `Manager.create/1` workspace open survives a failing FS backend via the `:icm_watcher_fs_mod` app-env seam (the bare-watcher test alone never exercised the runtime path the spec names); Task 2's doctor copy gained the A5 "best-effort on network paths" detail for `//`-rooted mounts (plain prefix check pre-Task-3, with a note that Task 4 may route it through the classifier); Task 4 gained its own native-Windows gate (paths + boundary + migrated-module suites — rewiring 16 containment sites doesn't ride Task 3's earlier gate); Task 7 gained Step 5b, the actual §C3 audit (persist/parse sites the compiler sweep can't flag, `message_file.ex:148` anchor, checklist into the PR description); Task 4's "9 offender files" corrected to 8. Tree-drift fold (not from Codex): the E2 chrome audit retargeted from `AppShell.svelte` to `Sidebar.svelte` + `+layout.svelte`, whose new overlay-chrome code gates on `inDesktop()` — true on Windows too — now to be switched to a mac-only `overlayChrome()` helper.
