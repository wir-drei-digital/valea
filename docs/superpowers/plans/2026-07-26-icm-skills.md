# ICM Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vendored, consent-gated skill installs into user-owned ICMs (`<icm>/.claude/skills/`), with state visible and manageable in the agent settings modal and a one-time offer card at mount time. First catalog entry: icm-architect.

**Architecture:** A pinned skill snapshot lives in `backend/priv/skills/` next to a `catalog.yaml`; a new `Valea.Skills` context derives per-mount install state from a hash-manifest provenance sidecar and performs staged (tmp + rename) installs/updates/uninstalls; a new generation-guarded `Valea.Api.Skills` RPC resource exposes it to the control-token-gated UI only. Frontend adds a Skills section to the existing agent settings modal and a dismissible offer card in the sidebar's Projects list.

**Tech Stack:** Elixir/Phoenix/Ash (generic map actions, AshTypescript codegen), YamlElixir for reads / pretty-JSON-as-YAML for engine-written sidecars (the `Valea.Mail.OpsFile` precedent), SvelteKit 5 runes + shadcn-svelte dialogs, vitest.

**Spec:** `docs/superpowers/specs/2026-07-26-icm-skills-design.md` — read it before starting; the state-derivation precedence and trust model live there.

## Global Constraints

- The agent never installs anything; only control-token-gated UI RPCs mutate. Agent sessions have no RPC access (existing isolation test must stay green).
- No runtime fetching, ever. The snapshot is repo-vendored; updating it is a repo commit.
- Valea never writes into `~/.claude` or any global Claude config.
- After install, files belong to the user. Valea touches them again only on an explicit update/uninstall click.
- Product copy: plain language, no exclamation marks, no emoji, buttons name outcomes ("Install into Mara Lindt Coaching"). Light theme only.
- Backend format: the repo has a mix-format hook; do not run any formatter in `frontend/` (no prettier configured — never run it bare).
- Full check: `cd backend && mix test`, `cd frontend && bun run check && bun run test`. Codegen staleness gate: `cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/`.
- Commit after every task with a `feat(skills):`/`docs(skills):` conventional message and the `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

## Execution bundles

The 12 tasks below execute as THREE bundles — one worker/session and one
review gate per bundle, commits still land per task. Run the bundle's
tasks in order; verify at the bundle boundary before moving on.

- **Bundle A — backend skills context (Tasks 1–5).** Vendor + catalog +
  provenance + state + ops. Gate: `cd backend && mix test test/valea/skills*
  test/valea/skills/` all green.
- **Bundle B — RPC and guardrails (Tasks 6–8).** Mounts dismissal state,
  `Valea.Api.Skills`, RiskTier. Gate: `cd backend && mix test` (full suite)
  green.
- **Bundle C — frontend and docs (Tasks 9–12).** Codegen + client, settings
  section + consent dialog, offer card, ARCHITECTURE.md. Gate: `cd frontend
  && bun run check && bun run test`, codegen staleness check, and the two
  in-browser verifications (Tasks 10/11) done.

---

### Task 1: Vendor the icm-architect snapshot + catalog.yaml

**Files:**
- Create: `backend/priv/skills/icm-architect/**` (vendored tree)
- Create: `backend/priv/skills/catalog.yaml`

**Interfaces:**
- Produces: the on-disk catalog contract every later task reads — `catalog.yaml` schema below; snapshot at `backend/priv/skills/<skill-id>/` containing at least `SKILL.md`.

This is a data-vendoring task (TDD exception: configuration/data). Verification is by inspection commands, not unit tests.

- [ ] **Step 1: Clone the pinned source into scratch and record the commit**

```bash
git clone --depth 1 https://github.com/RinDig/icm-architect \
  /tmp/icm-architect-vendor
PINNED_SHA=$(git -C /tmp/icm-architect-vendor rev-parse HEAD)
echo "$PINNED_SHA"
```

- [ ] **Step 2: Copy the tree (minus `.git`) into priv**

```bash
mkdir -p backend/priv/skills
rsync -a --exclude='.git' /tmp/icm-architect-vendor/ backend/priv/skills/icm-architect/
ls -R backend/priv/skills/icm-architect
```

Expected contents (per upstream README): `SKILL.md`, `references/core.md`, `references/forms.md`, `assets/templates/…`. If upstream ships extra top-level files (README, LICENSE), keep them — the install copies the whole snapshot and the hash manifest covers whatever is there.

- [ ] **Step 3: Write `backend/priv/skills/catalog.yaml`** (substitute the real sha from Step 1)

```yaml
version: 1
skills:
  icm-architect:
    name: "ICM Architect"
    description: "Structure this ICM's folders and add new workflow documents using the ICM methodology's five forms."
    source_url: "https://github.com/RinDig/icm-architect"
    license: "MIT"
    pinned: "<PINNED_SHA from step 1>"
```

- [ ] **Step 4: Verify SKILL.md has frontmatter** (Claude Code needs `name`/`description` frontmatter to load it)

```bash
head -10 backend/priv/skills/icm-architect/SKILL.md
```

Expected: a `---` YAML frontmatter block with `name:` and `description:`. If missing, stop and report — do not invent frontmatter.

- [ ] **Step 5: Commit**

```bash
git add backend/priv/skills
git commit -m "feat(skills): vendor icm-architect snapshot + catalog"
```

---

### Task 2: `Valea.Skills.Catalog`

**Files:**
- Create: `backend/lib/valea/skills/catalog.ex`
- Test: `backend/test/valea/skills/catalog_test.exs`

**Interfaces:**
- Produces: `Valea.Skills.Catalog.load/0 :: {:ok, %{String.t() => entry}} | {:error, term}` where `entry :: %{id: String.t(), name: String.t(), description: String.t(), source_url: String.t(), license: String.t(), pinned: String.t(), snapshot_dir: String.t(), defect: nil | :snapshot_missing}`. Also `Catalog.dir/0` (priv path, overridable for tests via app env `:skills_catalog_dir`).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Valea.Skills.CatalogTest do
  use ExUnit.Case, async: true

  alias Valea.Skills.Catalog

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-skillcat-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    prev = Application.get_env(:valea, :skills_catalog_dir)
    Application.put_env(:valea, :skills_catalog_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      if prev, do: Application.put_env(:valea, :skills_catalog_dir, prev),
        else: Application.delete_env(:valea, :skills_catalog_dir)
    end)

    %{dir: dir}
  end

  defp write_catalog!(dir, yaml), do: File.write!(Path.join(dir, "catalog.yaml"), yaml)

  test "the real priv catalog parses and its snapshot dirs exist" do
    Application.delete_env(:valea, :skills_catalog_dir)
    assert {:ok, skills} = Catalog.load()
    assert %{"icm-architect" => entry} = skills
    assert entry.name == "ICM Architect"
    assert entry.license == "MIT"
    assert entry.defect == nil
    assert File.exists?(Path.join(entry.snapshot_dir, "SKILL.md"))
  end

  test "an entry whose snapshot dir is missing is a defect, not a crash", %{dir: dir} do
    write_catalog!(dir, """
    version: 1
    skills:
      ghost:
        name: "Ghost"
        description: "d"
        source_url: "https://example.com"
        license: "MIT"
        pinned: "abc"
    """)

    assert {:ok, %{"ghost" => entry}} = Catalog.load()
    assert entry.defect == :snapshot_missing
  end

  test "unknown keys are ignored (forward compat)", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "x"))

    write_catalog!(dir, """
    version: 1
    future_top_level: true
    skills:
      x:
        name: "X"
        description: "d"
        source_url: "https://example.com"
        license: "MIT"
        pinned: "abc"
        future_key: 42
    """)

    assert {:ok, %{"x" => %{name: "X", defect: nil}}} = Catalog.load()
  end

  test "a missing or unparseable catalog file is an error, not a raise", %{dir: dir} do
    assert {:error, _} = Catalog.load()
    write_catalog!(dir, ": not yaml [")
    assert {:error, _} = Catalog.load()
  end

  test "an entry missing a required field is dropped with an error tuple", %{dir: dir} do
    write_catalog!(dir, """
    version: 1
    skills:
      bad:
        name: "No description"
    """)

    assert {:ok, skills} = Catalog.load()
    assert skills == %{}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/skills/catalog_test.exs`
Expected: FAIL — `Valea.Skills.Catalog` is not available.

- [ ] **Step 3: Implement**

```elixir
defmodule Valea.Skills.Catalog do
  @moduledoc """
  Parses + validates `priv/skills/catalog.yaml` — the repo-vendored skill
  catalog (ICM skills design spec, §Catalog). Read-only and side-effect
  free. Unknown keys are ignored (the `icm.yaml` forward-compat posture);
  an entry missing a required field is dropped; an entry whose snapshot
  directory is missing loads with `defect: :snapshot_missing` (doctor
  material, never a crash). No runtime fetching exists anywhere.
  """

  @required ~w(name description source_url license pinned)

  def dir do
    Application.get_env(:valea, :skills_catalog_dir) ||
      Path.join(:code.priv_dir(:valea), "skills")
  end

  @spec load() :: {:ok, %{String.t() => map()}} | {:error, term()}
  def load do
    path = Path.join(dir(), "catalog.yaml")

    with {:ok, %{"skills" => skills}} when is_map(skills) <-
           YamlElixir.read_from_file(path) do
      {:ok,
       skills
       |> Enum.flat_map(fn {id, raw} -> entry(id, raw) end)
       |> Map.new()}
    else
      {:ok, _shape} -> {:error, :invalid_catalog}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry(id, raw) when is_map(raw) do
    if Enum.all?(@required, &is_binary(raw[&1])) do
      snapshot_dir = Path.join(dir(), id)

      [
        {id,
         %{
           id: id,
           name: raw["name"],
           description: raw["description"],
           source_url: raw["source_url"],
           license: raw["license"],
           pinned: raw["pinned"],
           snapshot_dir: snapshot_dir,
           defect: if(File.dir?(snapshot_dir), do: nil, else: :snapshot_missing)
         }}
      ]
    else
      []
    end
  end

  defp entry(_id, _raw), do: []
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/skills/catalog_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/skills/catalog.ex backend/test/valea/skills/catalog_test.exs
git commit -m "feat(skills): catalog loader for vendored skill snapshots"
```

---

### Task 3: `Valea.Skills.Provenance` — sidecar + hash manifest

**Files:**
- Create: `backend/lib/valea/skills/provenance.ex`
- Test: `backend/test/valea/skills/provenance_test.exs`

**Interfaces:**
- Produces:
  - `Provenance.hash_tree/1 :: (dir) -> %{rel_path => sha256_hex}` — every regular file under `dir`, recursive, excluding `.provenance.yaml`; refuses symlinks (`{:error, {:symlink, rel}}`).
  - `Provenance.write!/2 :: (skill_dir, %{skill:, version:, source_url:}) -> :ok` — hashes the tree and writes `.provenance.yaml` (pretty JSON, a strict YAML subset — the `Valea.Mail.OpsFile` sidecar precedent).
  - `Provenance.read/1 :: (skill_dir) -> {:ok, %{skill:, version:, source_url:, files: %{rel => hash}}} | :error`
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Valea.Skills.ProvenanceTest do
  use ExUnit.Case, async: true

  alias Valea.Skills.Provenance

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-skillprov-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp seed!(dir) do
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: x\n---\nbody\n")
    File.mkdir_p!(Path.join(dir, "references"))
    File.write!(Path.join(dir, "references/core.md"), "core\n")
  end

  test "hash_tree hashes every file recursively, excluding the sidecar", %{dir: dir} do
    seed!(dir)
    File.write!(Path.join(dir, ".provenance.yaml"), "{}")

    assert {:ok, manifest} = Provenance.hash_tree(dir)
    assert Map.keys(manifest) |> Enum.sort() == ["SKILL.md", "references/core.md"]

    expected = :crypto.hash(:sha256, "core\n") |> Base.encode16(case: :lower)
    assert manifest["references/core.md"] == expected
  end

  test "hash_tree refuses a symlink inside the tree", %{dir: dir} do
    seed!(dir)
    File.ln_s!("/etc/hosts", Path.join(dir, "link.md"))
    assert {:error, {:symlink, "link.md"}} = Provenance.hash_tree(dir)
  end

  test "write!/read round-trip", %{dir: dir} do
    seed!(dir)

    :ok =
      Provenance.write!(dir, %{
        skill: "icm-architect",
        version: "abc123",
        source_url: "https://github.com/RinDig/icm-architect"
      })

    assert {:ok, prov} = Provenance.read(dir)
    assert prov.skill == "icm-architect"
    assert prov.version == "abc123"
    assert prov.files["SKILL.md"]
    refute Map.has_key?(prov.files, ".provenance.yaml")
  end

  test "the written sidecar is valid YAML (JSON subset) and carries format: 1", %{dir: dir} do
    seed!(dir)
    :ok = Provenance.write!(dir, %{skill: "s", version: "v", source_url: "u"})

    assert {:ok, doc} = YamlElixir.read_from_file(Path.join(dir, ".provenance.yaml"))
    assert doc["format"] == 1
    assert doc["installed_by"] == "valea"
  end

  test "read on a missing or unparseable sidecar is :error", %{dir: dir} do
    assert :error = Provenance.read(dir)
    File.write!(Path.join(dir, ".provenance.yaml"), ": [")
    assert :error = Provenance.read(dir)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/skills/provenance_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 3: Implement**

```elixir
defmodule Valea.Skills.Provenance do
  @moduledoc """
  The `.provenance.yaml` sidecar inside an installed skill folder (ICM
  skills design spec, §On-disk contract): skill id, installed version,
  source URL, and a content-hash manifest of every installed file. The
  sidecar travels with the portable ICM, so any Valea instance recognizes
  the install and — by re-hashing — whether the user edited it.

  Written as pretty-printed JSON, a strict YAML subset (the
  `Valea.Mail.OpsFile` sidecar precedent): agent-readable `.yaml` without
  a hand-rolled YAML encoder. `hash_tree/1` refuses symlinks — a link
  inside a skill tree is never hashed or copied.
  """

  @sidecar ".provenance.yaml"

  @spec hash_tree(String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:symlink, String.t()}}
  def hash_tree(dir) do
    walk(dir, ".", %{})
  end

  defp walk(base, rel, acc) do
    abs = Path.join(base, rel)

    Enum.reduce_while(File.ls!(abs), {:ok, acc}, fn name, {:ok, acc} ->
      rel_child = if rel == ".", do: name, else: Path.join(rel, name)
      abs_child = Path.join(base, rel_child)
      stat = File.lstat!(abs_child)

      cond do
        rel_child == @sidecar ->
          {:cont, {:ok, acc}}

        stat.type == :symlink ->
          {:halt, {:error, {:symlink, rel_child}}}

        stat.type == :directory ->
          case walk(base, rel_child, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            err -> {:halt, err}
          end

        stat.type == :regular ->
          hash =
            :crypto.hash(:sha256, File.read!(abs_child)) |> Base.encode16(case: :lower)

          {:cont, {:ok, Map.put(acc, rel_child, hash)}}

        true ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  @spec write!(String.t(), %{skill: String.t(), version: String.t(), source_url: String.t()}) ::
          :ok
  def write!(dir, %{skill: skill, version: version, source_url: source_url}) do
    {:ok, files} = hash_tree(dir)

    doc = %{
      "format" => 1,
      "skill" => skill,
      "version" => version,
      "source_url" => source_url,
      "installed_by" => "valea",
      "files" => files
    }

    path = Path.join(dir, @sidecar)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(doc, pretty: true))
    File.rename!(tmp, path)
  end

  @spec read(String.t()) :: {:ok, map()} | :error
  def read(dir) do
    with {:ok, doc} <- YamlElixir.read_from_file(Path.join(dir, @sidecar)),
         %{"skill" => skill, "version" => version, "files" => files}
         when is_binary(skill) and is_binary(version) and is_map(files) <- doc do
      {:ok,
       %{
         skill: skill,
         version: version,
         source_url: doc["source_url"],
         files: files
       }}
    else
      _missing_or_invalid -> :error
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/skills/provenance_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/skills/provenance.ex backend/test/valea/skills/provenance_test.exs
git commit -m "feat(skills): provenance sidecar with content-hash manifest"
```

---

### Task 4: `Valea.Skills` — state derivation

**Files:**
- Create: `backend/lib/valea/skills.ex`
- Test: `backend/test/valea/skills_test.exs`

**Interfaces:**
- Consumes: `Catalog.load/0`, `Provenance.read/1`, `Provenance.hash_tree/1` (Tasks 2–3).
- Produces: `Valea.Skills.state(catalog_entry, icm_root) :: {:not_installed | :foreign | :edited | :update_available | :installed, %{installed_version: String.t() | nil}}`. Skill dir convention: `<icm_root>/.claude/skills/<entry.id>`. Precedence exactly as spec §On-disk contract: not_installed → foreign → edited → update_available → installed, first match wins.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Valea.SkillsTest do
  use ExUnit.Case, async: true

  alias Valea.Skills
  alias Valea.Skills.Provenance

  @entry %{
    id: "icm-architect",
    name: "ICM Architect",
    description: "d",
    source_url: "https://github.com/RinDig/icm-architect",
    license: "MIT",
    pinned: "sha-new",
    snapshot_dir: "unused-in-state-tests",
    defect: nil
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-skills-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    icm = Path.join(dir, "icm")
    File.mkdir_p!(icm)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{icm: icm}
  end

  defp install!(icm, version) do
    skill_dir = Path.join([icm, ".claude", "skills", "icm-architect"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: x\n---\n")

    :ok =
      Provenance.write!(skill_dir, %{
        skill: "icm-architect",
        version: version,
        source_url: @entry.source_url
      })

    skill_dir
  end

  test "no skill dir -> not_installed", %{icm: icm} do
    assert {:not_installed, %{installed_version: nil}} = Skills.state(@entry, icm)
  end

  test "dir present without a parseable sidecar -> foreign", %{icm: icm} do
    skill_dir = Path.join([icm, ".claude", "skills", "icm-architect"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "someone else's\n")

    assert {:foreign, _meta} = Skills.state(@entry, icm)
  end

  test "hashes match + version matches -> installed", %{icm: icm} do
    install!(icm, "sha-new")
    assert {:installed, %{installed_version: "sha-new"}} = Skills.state(@entry, icm)
  end

  test "hashes match + older version -> update_available", %{icm: icm} do
    install!(icm, "sha-old")
    assert {:update_available, %{installed_version: "sha-old"}} = Skills.state(@entry, icm)
  end

  test "edited beats update_available: hash mismatch at an old version -> edited", %{icm: icm} do
    skill_dir = install!(icm, "sha-old")
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: x\n---\nuser edit\n")

    assert {:edited, %{installed_version: "sha-old"}} = Skills.state(@entry, icm)
  end

  test "edited at the current version -> edited", %{icm: icm} do
    skill_dir = install!(icm, "sha-new")
    File.write!(Path.join(skill_dir, "SKILL.md"), "edited\n")

    assert {:edited, _meta} = Skills.state(@entry, icm)
  end

  test "a file added by the user (not in manifest) -> edited", %{icm: icm} do
    skill_dir = install!(icm, "sha-new")
    File.write!(Path.join(skill_dir, "extra.md"), "new\n")

    assert {:edited, _meta} = Skills.state(@entry, icm)
  end

  test "a symlink planted inside the skill dir -> foreign (never hashed)", %{icm: icm} do
    skill_dir = install!(icm, "sha-new")
    File.ln_s!("/etc/hosts", Path.join(skill_dir, "link.md"))

    assert {:foreign, _meta} = Skills.state(@entry, icm)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/skills_test.exs`
Expected: FAIL — `Valea.Skills` not available.

- [ ] **Step 3: Implement** (`backend/lib/valea/skills.ex`; install/update/uninstall come in Task 5 — only `state/2` and the path helper now)

```elixir
defmodule Valea.Skills do
  @moduledoc """
  ICM skills: consent-gated install/update/uninstall of repo-vendored
  skill snapshots into a user-owned ICM's `.claude/skills/`, and the
  per-mount state derivation the settings UI renders (ICM skills design
  spec `docs/superpowers/specs/2026-07-26-icm-skills-design.md`).

  The agent never calls this; only the control-token-gated UI RPC
  (`Valea.Api.Skills`) does, and only on an explicit user click — the
  click IS the consent step. After install the files are the user's:
  Valea touches them again only on an explicit update or uninstall.

  State precedence (spec §On-disk contract, first match wins):
  `not_installed` → `foreign` → `edited` → `update_available` →
  `installed`. `foreign` (a dir Valea can't attribute to itself — no
  parseable sidecar, or a symlink inside the tree) is listed read-only
  and never updated or removed through Valea.
  """

  alias Valea.Skills.Provenance

  @spec skill_dir(String.t(), String.t()) :: String.t()
  def skill_dir(icm_root, skill_id),
    do: Path.join([icm_root, ".claude", "skills", skill_id])

  @spec state(map(), String.t()) :: {atom(), %{installed_version: String.t() | nil}}
  def state(entry, icm_root) do
    dir = skill_dir(icm_root, entry.id)

    cond do
      not File.dir?(dir) ->
        {:not_installed, %{installed_version: nil}}

      true ->
        with {:ok, prov} <- Provenance.read(dir),
             {:ok, on_disk} <- Provenance.hash_tree(dir) do
          cond do
            on_disk != prov.files -> {:edited, %{installed_version: prov.version}}
            prov.version != entry.pinned -> {:update_available, %{installed_version: prov.version}}
            true -> {:installed, %{installed_version: prov.version}}
          end
        else
          _no_sidecar_or_symlink -> {:foreign, %{installed_version: nil}}
        end
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/skills_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/skills.ex backend/test/valea/skills_test.exs
git commit -m "feat(skills): per-mount skill state derivation"
```

---

### Task 5: `Valea.Skills` — install / update / uninstall (staged writes, containment)

**Files:**
- Modify: `backend/lib/valea/skills.ex`
- Test: `backend/test/valea/skills_test.exs` (append a new `describe`)

**Interfaces:**
- Consumes: `Valea.Mounts.mount_by_key/2` (`mount | nil`; mount has `.root`, `.enabled`, `.degraded`), `Valea.Paths.resolve_real/2` (`{:ok, abs} | {:error, :outside | :invalid}`), `Catalog.load/0`, `Provenance`.
- Produces (all take `(workspace :: String.t(), mount_key :: String.t(), skill_id :: String.t())`):
  - `install/3 :: :ok | {:error, reason}`
  - `update/4` (extra `opts :: [force: boolean]`) `:: :ok | {:error, reason}`
  - `uninstall/3 :: :ok | {:error, reason}`
  - `list/2 :: (workspace, mount_key) -> {:ok, [row]} | {:error, reason}` where `row :: %{skill_id, name, description, source_url, license, pinned, state :: String.t(), installed_version}` — one per catalog entry, plus `%{skill_id: dirname, state: "foreign", ...nil fields}` for on-disk dirs not in the catalog.
  - Error reasons: `:icm_unavailable` (no mount / disabled / degraded), `:unknown_skill`, `:snapshot_missing`, `:already_installed`, `:not_installed`, `:foreign`, `:edited` (update without force), `:up_to_date`, `:containment` (symlinked `.claude`/`skills` escaping the root).

- [ ] **Step 1: Write the failing tests** (append to `backend/test/valea/skills_test.exs`; these need a real mounted workspace — use `Valea.AgentCase.open_workspace!/1` exactly as `Valea.Api.IcmsTest` does, so make the module `async: false` and move the existing tests unchanged into a `describe "state/2"` block)

```elixir
  # -- install/update/uninstall ---------------------------------------------
  # These use a real workspace + mounted ICM (Valea.AgentCase) because the
  # ops resolve mounts by key and enforce containment against the real
  # filesystem. The module therefore becomes async: false.

  describe "install/update/uninstall" do
    setup do
      ws = Valea.AgentCase.open_workspace!("W")

      icm_path =
        Path.join(System.tmp_dir!(), "valea-skills-icm-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(icm_path) end)

      {:ok, %{mount_key: mount_key}} = Valea.Mounts.create(ws.path, "Coaching", icm_path)

      # A fake vendored catalog so tests don't depend on the real snapshot.
      cat_dir =
        Path.join(System.tmp_dir!(), "valea-skills-cat-#{System.unique_integer([:positive])}")

      snap = Path.join(cat_dir, "icm-architect")
      File.mkdir_p!(Path.join(snap, "references"))
      File.write!(Path.join(snap, "SKILL.md"), "---\nname: icm-architect\n---\nv2\n")
      File.write!(Path.join(snap, "references/core.md"), "core v2\n")

      File.write!(Path.join(cat_dir, "catalog.yaml"), """
      version: 1
      skills:
        icm-architect:
          name: "ICM Architect"
          description: "d"
          source_url: "https://github.com/RinDig/icm-architect"
          license: "MIT"
          pinned: "sha-v2"
      """)

      prev = Application.get_env(:valea, :skills_catalog_dir)
      Application.put_env(:valea, :skills_catalog_dir, cat_dir)

      on_exit(fn ->
        File.rm_rf!(cat_dir)
        if prev, do: Application.put_env(:valea, :skills_catalog_dir, prev),
          else: Application.delete_env(:valea, :skills_catalog_dir)
      end)

      %{ws: ws.path, mount_key: mount_key, icm: icm_path}
    end

    test "install copies the snapshot, writes provenance, state becomes installed",
         %{ws: ws, mount_key: key, icm: icm} do
      assert :ok = Skills.install(ws, key, "icm-architect")

      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      assert File.read!(Path.join(dir, "SKILL.md")) =~ "v2"
      assert {:ok, prov} = Provenance.read(dir)
      assert prov.version == "sha-v2"

      assert {:ok, [row]} = Skills.list(ws, key)
      assert row.state == "installed"
    end

    test "install refuses when already installed, foreign, or unknown",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      assert {:error, :already_installed} = Skills.install(ws, key, "icm-architect")

      foreign = Path.join([icm, ".claude", "skills", "hand-rolled"])
      File.mkdir_p!(foreign)
      assert {:error, :unknown_skill} = Skills.install(ws, key, "hand-rolled")
      assert {:error, :unknown_skill} = Skills.install(ws, key, "nope")
    end

    test "install refuses on unknown/disabled mount", %{ws: ws, mount_key: key} do
      assert {:error, :icm_unavailable} = Skills.install(ws, "ghost", "icm-architect")
      {:ok, _} = Valea.Mounts.set_enabled(ws, key, false)
      assert {:error, :icm_unavailable} = Skills.install(ws, key, "icm-architect")
    end

    test "no partial skill dir is ever left at the live path (staged write)",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      skills_root = Path.join([icm, ".claude", "skills"])
      entries = File.ls!(skills_root)
      assert entries == ["icm-architect"], "stray staging entries: #{inspect(entries)}"
    end

    test "update on an unedited old install replaces content and version",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      # Simulate an old install: rewrite provenance at an older version.
      :ok =
        Provenance.write!(dir, %{skill: "icm-architect", version: "sha-v1", source_url: "u"})

      assert {:ok, [%{state: "update_available"}]} = Skills.list(ws, key)
      assert :ok = Skills.update(ws, key, "icm-architect")
      assert {:ok, [%{state: "installed", installed_version: "sha-v2"}]} = Skills.list(ws, key)
    end

    test "update refuses an edited install without force, replaces with force",
         %{ws: ws, mount_key: key, icm: icm} do
      :ok = Skills.install(ws, key, "icm-architect")
      dir = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.write!(Path.join(dir, "SKILL.md"), "my edits\n")

      assert {:error, :edited} = Skills.update(ws, key, "icm-architect")
      assert :ok = Skills.update(ws, key, "icm-architect", force: true)
      assert File.read!(Path.join(dir, "SKILL.md")) =~ "v2"
    end

    test "update on a current install is up_to_date; on nothing, not_installed",
         %{ws: ws, mount_key: key} do
      assert {:error, :not_installed} = Skills.update(ws, key, "icm-architect")
      :ok = Skills.install(ws, key, "icm-architect")
      assert {:error, :up_to_date} = Skills.update(ws, key, "icm-architect")
    end

    test "uninstall removes the dir; refuses foreign and not_installed",
         %{ws: ws, mount_key: key, icm: icm} do
      assert {:error, :not_installed} = Skills.uninstall(ws, key, "icm-architect")

      :ok = Skills.install(ws, key, "icm-architect")
      assert :ok = Skills.uninstall(ws, key, "icm-architect")
      refute File.dir?(Path.join([icm, ".claude", "skills", "icm-architect"]))

      foreign = Path.join([icm, ".claude", "skills", "icm-architect"])
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "SKILL.md"), "hand-rolled\n")
      assert {:error, :foreign} = Skills.uninstall(ws, key, "icm-architect")
    end

    test "containment: a symlinked .claude escaping the root refuses every op",
         %{ws: ws, mount_key: key, icm: icm} do
      outside = Path.join(System.tmp_dir!(), "valea-skills-outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)
      File.ln_s!(outside, Path.join(icm, ".claude"))

      assert {:error, :containment} = Skills.install(ws, key, "icm-architect")
      assert {:error, :containment} = Skills.uninstall(ws, key, "icm-architect")
      assert File.ls!(outside) == []
    end

    test "list includes foreign on-disk dirs not in the catalog",
         %{ws: ws, mount_key: key, icm: icm} do
      foreign = Path.join([icm, ".claude", "skills", "hand-rolled"])
      File.mkdir_p!(foreign)

      assert {:ok, rows} = Skills.list(ws, key)
      assert Enum.any?(rows, &(&1.skill_id == "hand-rolled" and &1.state == "foreign"))
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/skills_test.exs`
Expected: FAIL — `Skills.install/3` undefined (state tests still pass).

- [ ] **Step 3: Implement** (add to `backend/lib/valea/skills.ex`; keep `state/2` from Task 4 unchanged)

```elixir
  alias Valea.Mounts
  alias Valea.Paths
  alias Valea.Skills.Catalog

  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(workspace, mount_key) do
    with {:ok, root} <- effective_root(workspace, mount_key),
         {:ok, catalog} <- Catalog.load() do
      catalog_rows =
        for {_id, entry} <- Enum.sort(catalog) do
          {state, meta} = state(entry, root)

          %{
            skill_id: entry.id,
            name: entry.name,
            description: entry.description,
            source_url: entry.source_url,
            license: entry.license,
            pinned: entry.pinned,
            state: Atom.to_string(state),
            installed_version: meta.installed_version
          }
        end

      {:ok, catalog_rows ++ foreign_rows(root, catalog)}
    end
  end

  # On-disk dirs under .claude/skills/ with no catalog entry: listed
  # read-only as foreign, never mutated through Valea.
  defp foreign_rows(root, catalog) do
    skills_root = Path.join([root, ".claude", "skills"])

    case File.ls(skills_root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not Map.has_key?(catalog, name),
            not String.starts_with?(name, ".tmp-"),
            File.dir?(Path.join(skills_root, name)) do
          %{
            skill_id: name,
            name: name,
            description: nil,
            source_url: nil,
            license: nil,
            pinned: nil,
            state: "foreign",
            installed_version: nil
          }
        end

      {:error, _reason} ->
        []
    end
  end

  @spec install(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def install(workspace, mount_key, skill_id) do
    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:not_installed, _meta} -> stage_in(entry, skills_root)
        {:foreign, _meta} -> {:error, :foreign}
        {_installed_any, _meta} -> {:error, :already_installed}
      end
    end
  end

  @spec update(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update(workspace, mount_key, skill_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:update_available, _meta} -> replace(entry, skills_root)
        {:edited, _meta} when force -> replace(entry, skills_root)
        {:edited, _meta} -> {:error, :edited}
        {:installed, _meta} -> {:error, :up_to_date}
        {:not_installed, _meta} -> {:error, :not_installed}
        {:foreign, _meta} -> {:error, :foreign}
      end
    end
  end

  @spec uninstall(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def uninstall(workspace, mount_key, skill_id) do
    with {:ok, root, entry} <- resolve(workspace, mount_key, skill_id),
         {:ok, skills_root} <- contained_skills_root(root) do
      case state(entry, root) do
        {:not_installed, _meta} ->
          {:error, :not_installed}

        {:foreign, _meta} ->
          {:error, :foreign}

        {_removable, _meta} ->
          File.rm_rf!(Path.join(skills_root, entry.id))
          :ok
      end
    end
  end

  # -- shared plumbing --------------------------------------------------------

  defp resolve(workspace, mount_key, skill_id) do
    with {:ok, root} <- effective_root(workspace, mount_key),
         {:ok, catalog} <- Catalog.load(),
         %{defect: nil} = entry <- catalog[skill_id] || {:error, :unknown_skill} do
      {:ok, root, entry}
    else
      {:error, _} = err -> err
      %{defect: :snapshot_missing} -> {:error, :snapshot_missing}
    end
  end

  defp effective_root(workspace, mount_key) do
    case Mounts.mount_by_key(workspace, mount_key) do
      %{enabled: true, degraded: nil, root: root} -> {:ok, root}
      _missing_or_ineffective -> {:error, :icm_unavailable}
    end
  end

  # `.claude/skills` must resolve INSIDE the mount root — a symlinked
  # `.claude` (or `skills`) pointing elsewhere refuses rather than follows.
  # `resolve_real` walks symlinks; a missing suffix resolves to where it
  # WOULD live, so a fresh ICM (no `.claude` yet) still passes.
  defp contained_skills_root(root) do
    case Paths.resolve_real(".claude/skills", root) do
      {:ok, resolved} ->
        File.mkdir_p!(resolved)
        {:ok, resolved}

      {:error, _outside_or_invalid} ->
        {:error, :containment}
    end
  end

  defp stage_in(entry, skills_root) do
    staging =
      Path.join(skills_root, ".tmp-#{entry.id}-#{System.unique_integer([:positive])}")

    File.cp_r!(entry.snapshot_dir, staging)
    :ok = Valea.Skills.Provenance.write!(staging, %{
      skill: entry.id,
      version: entry.pinned,
      source_url: entry.source_url
    })

    File.rename!(staging, Path.join(skills_root, entry.id))
    :ok
  end

  # Update: stage the new copy, move the old aside, rename in, drop the old.
  defp replace(entry, skills_root) do
    live = Path.join(skills_root, entry.id)
    aside = Path.join(skills_root, ".tmp-old-#{entry.id}-#{System.unique_integer([:positive])}")

    staging =
      Path.join(skills_root, ".tmp-#{entry.id}-#{System.unique_integer([:positive])}")

    File.cp_r!(entry.snapshot_dir, staging)
    :ok = Valea.Skills.Provenance.write!(staging, %{
      skill: entry.id,
      version: entry.pinned,
      source_url: entry.source_url
    })

    File.rename!(live, aside)
    File.rename!(staging, live)
    File.rm_rf!(aside)
    :ok
  end
```

Note: `File.cp_r!` follows the source tree as-is; the snapshot is repo-vendored (trusted). The symlink refusal matters on the *installed* side (`hash_tree`) and the *path* side (`resolve_real`), both covered by tests. Also verify the `.tmp-` prefix skip in `foreign_rows` keeps crash leftovers out of listings (the staged-write test covers the happy path; leftovers are inert and cleaned on the next successful op for the same skill — YAGNI beyond that).

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/skills_test.exs`
Expected: PASS (state describe + 10 new tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/skills.ex backend/test/valea/skills_test.exs
git commit -m "feat(skills): staged install/update/uninstall with containment"
```

---

### Task 6: offer-dismissal state in `Valea.Mounts`

**Files:**
- Modify: `backend/lib/valea/mounts.ex` (two new public functions near `set_enabled/3`)
- Test: `backend/test/valea/mounts_test.exs` (append)

**Interfaces:**
- Consumes: existing private helpers `read_icms_config/1`, `write_workspace_config/2`, `render_icms_doc/2` in the same module.
- Produces:
  - `Mounts.skills_offers_dismissed(workspace, mount_key) :: [String.t()]` — `[]` when absent/not a list.
  - `Mounts.dismiss_skills_offer(workspace, mount_key, skill_id) :: :ok | {:error, :not_mounted}` — appends (idempotent, no duplicates) to the `skills_offers_dismissed` list on that ICM's `icms:` entry in `config/workspace.yaml`.

- [ ] **Step 1: Write the failing tests** (append to the existing mounts test module, using its existing workspace setup helpers — read the top of `backend/test/valea/mounts_test.exs` first and reuse its setup pattern verbatim)

```elixir
  describe "skills offer dismissal" do
    # Reuse this file's existing workspace+mount setup helper; the assertions
    # below only need `ws` (workspace path) and a mounted `key`.
    test "absent -> [], dismiss appends idempotently and survives re-read", %{ws: ws} do
      {:ok, %{mount_key: key}} = mount_fresh_icm!(ws)

      assert Valea.Mounts.skills_offers_dismissed(ws, key) == []

      assert :ok = Valea.Mounts.dismiss_skills_offer(ws, key, "icm-architect")
      assert :ok = Valea.Mounts.dismiss_skills_offer(ws, key, "icm-architect")

      assert Valea.Mounts.skills_offers_dismissed(ws, key) == ["icm-architect"]

      # The entry's other keys survive the rewrite (generic encoder).
      assert Valea.Mounts.mount_by_key(ws, key).enabled
    end

    test "unknown mount key refuses", %{ws: ws} do
      assert {:error, :mount_not_found} =
               Valea.Mounts.dismiss_skills_offer(ws, "ghost", "icm-architect")

      assert Valea.Mounts.skills_offers_dismissed(ws, "ghost") == []
    end
  end
```

(If the existing test file's setup exposes different names than `ws`/`mount_fresh_icm!`, adapt the two tests to its actual helpers — the behavior under test is exactly as written.)

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/mounts_test.exs`
Expected: FAIL — `skills_offers_dismissed/2` undefined.

- [ ] **Step 3: Implement** (in `backend/lib/valea/mounts.ex`, near `set_enabled/3`; follow its exact shape — `validate_mount_name/1` + `read_icms_config/1` + `ensure_icm_present/2`, then `write_icms/2` with the updated map. No audit event: offer dismissal is minor operational state, unlike enable/disable.)

```elixir
  @doc """
  The skill ids whose one-time offer card the user dismissed for this
  mount (ICM skills design spec, §Frontend/Offer card) — operational
  state, so it lives on the `icms:` entry in `config/workspace.yaml`,
  never inside the user-owned ICM. `[]` when absent or malformed.
  """
  @spec skills_offers_dismissed(String.t(), String.t()) :: [String.t()]
  def skills_offers_dismissed(workspace, mount_key) do
    case workspace |> read_icms_config() |> Map.get(mount_key) do
      %{"skills_offers_dismissed" => list} when is_list(list) ->
        Enum.filter(list, &is_binary/1)

      _absent_or_malformed ->
        []
    end
  end

  @doc """
  Appends `skill_id` to the mount's dismissed-offers list (idempotent).
  A list rather than a boolean so future catalog entries each get their
  own one-time offer.
  """
  @spec dismiss_skills_offer(String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def dismiss_skills_offer(workspace, mount_key, skill_id)
      when is_binary(skill_id) do
    with :ok <- validate_mount_name(mount_key),
         icms = read_icms_config(workspace),
         :ok <- ensure_icm_present(icms, mount_key) do
      dismissed =
        (skills_offers_dismissed(workspace, mount_key) ++ [skill_id]) |> Enum.uniq()

      new_icms =
        Map.update!(icms, mount_key, &Map.put(&1, "skills_offers_dismissed", dismissed))

      write_icms(workspace, new_icms)
    end
  end
```

Note: `ensure_icm_present/2`'s missing-entry error is `:mount_not_found` in the existing code — if so, use that atom instead of `:not_mounted` in the Step 1 test (read `set_enabled/3`'s neighbors first; the existing vocabulary wins).

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/mounts_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/mounts.ex backend/test/valea/mounts_test.exs
git commit -m "feat(skills): per-mount offer-dismissal list in workspace config"
```

---

### Task 7: `Valea.Api.Skills` RPC resource

**Files:**
- Create: `backend/lib/valea/api/skills.ex`
- Modify: `backend/lib/valea/api.ex` (add `resource Valea.Api.Skills` to the `resources do` block)
- Test: `backend/test/valea/api/skills_test.exs`

**Interfaces:**
- Consumes: `Valea.Skills.list/2`, `.install/3`, `.update/4`, `.uninstall/3` (Task 5); `Valea.Mounts.skills_offers_dismissed/2`, `.dismiss_skills_offer/3` (Task 6); `Valea.Workspace.Manager.check_generation/1` + `.current/0`.
- Produces RPC actions (all generation-guarded, `Valea.Api.Icms` shape exactly):
  - `list_skills(mount_key, generation)` → `%{skills: [row], dismissed: [String.t()]}` (row fields: `skill_id, name, description, source_url, license, pinned, state, installed_version` — strings, nullable where Task 5 produces nil)
  - `install_skill(mount_key, skill_id, generation)` → `%{ok: true}`
  - `update_skill(mount_key, skill_id, force, generation)` → `%{ok: true}` (`force :: boolean`, default false)
  - `uninstall_skill(mount_key, skill_id, generation)` → `%{ok: true}`
  - `dismiss_skills_offer(mount_key, skill_id, generation)` → `%{ok: true}`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Valea.Api.SkillsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Api.Skills, as: ApiSkills
  alias Valea.Workspace.Manager

  setup do
    ws = AgentCase.open_workspace!("W")

    icm_path =
      Path.join(System.tmp_dir!(), "valea-apiskills-icm-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(icm_path) end)
    {:ok, %{mount_key: mount_key}} = Valea.Mounts.create(ws.path, "Coaching", icm_path)

    %{ws: ws.path, key: mount_key, generation: Manager.generation()}
  end

  defp run(action, input) do
    ApiSkills
    |> Ash.ActionInput.for_action(action, input)
    |> Ash.run_action()
  end

  test "list_skills returns the real catalog entry as not_installed + empty dismissed",
       %{key: key, generation: generation} do
    assert {:ok, %{skills: skills, dismissed: []}} =
             run(:list_skills, %{mount_key: key, generation: generation})

    assert %{skill_id: "icm-architect", state: "not_installed"} =
             Enum.find(skills, &(&1.skill_id == "icm-architect"))
  end

  test "install -> installed; uninstall -> not_installed", %{key: key, generation: generation} do
    assert {:ok, %{ok: true}} =
             run(:install_skill, %{mount_key: key, skill_id: "icm-architect", generation: generation})

    assert {:ok, %{skills: skills}} = run(:list_skills, %{mount_key: key, generation: generation})
    assert %{state: "installed"} = Enum.find(skills, &(&1.skill_id == "icm-architect"))

    assert {:ok, %{ok: true}} =
             run(:uninstall_skill, %{mount_key: key, skill_id: "icm-architect", generation: generation})
  end

  test "dismiss_skills_offer lands in list_skills.dismissed", %{key: key, generation: generation} do
    assert {:ok, %{ok: true}} =
             run(:dismiss_skills_offer, %{mount_key: key, skill_id: "icm-architect", generation: generation})

    assert {:ok, %{dismissed: ["icm-architect"]}} =
             run(:list_skills, %{mount_key: key, generation: generation})
  end

  # The suite's stale-generation idiom (Valea.Api.IcmsTest): stale is
  # generation + 1, and the error surfaces as a %Valea.Api.Error{} with
  # code "workspace_changed" at the head of `error.errors`.
  test "every action rejects a stale generation with workspace_changed",
       %{key: key, generation: generation} do
    stale = generation + 1

    assert {:error, error} = run(:list_skills, %{mount_key: key, generation: stale})
    assert %Valea.Api.Error{code: "workspace_changed"} = error.errors |> hd()

    for {action, input} <- [
          {:install_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:update_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:uninstall_skill, %{mount_key: key, skill_id: "icm-architect", generation: stale}},
          {:dismiss_skills_offer, %{mount_key: key, skill_id: "icm-architect", generation: stale}}
        ] do
      assert {:error, _error} = run(action, input),
             "expected stale-generation refusal for #{action}"
    end
  end

  test "domain errors map to the shared vocabulary", %{key: key, generation: generation} do
    assert {:error, error} =
             run(:install_skill, %{mount_key: "ghost", skill_id: "icm-architect", generation: generation})

    assert %Valea.Api.Error{code: "icm_unavailable"} = error.errors |> hd()

    assert {:error, error} =
             run(:update_skill, %{mount_key: key, skill_id: "icm-architect", generation: generation})

    assert %Valea.Api.Error{code: "not_installed"} = error.errors |> hd()
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/api/skills_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 3: Implement** (`backend/lib/valea/api/skills.ex` — mirror `Valea.Api.Icms`'s structure: `use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]`, `typescript do type_name("Skills") end`, generic `:map` actions with `constraints fields:` typed like `list_icms`'s, a central `error_for/1`)

```elixir
defmodule Valea.Api.Skills do
  @moduledoc """
  ICM skills RPC (ICM skills design spec, §Backend): list / install /
  update / uninstall / dismiss-offer, per mounted ICM. Every action
  guards `Valea.Workspace.Manager.check_generation/1` FIRST. Trust model
  is the `set_harness_command` one — the settings click is the consent
  step; these actions are reachable only from the control-token-gated UI
  socket, and the agent tool surface carries no RPC access.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Skills")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Skills
  alias Valea.Workspace.Manager

  @row_fields [
    skill_id: [type: :string, allow_nil?: false],
    name: [type: :string, allow_nil?: false],
    description: [type: :string, allow_nil?: true],
    source_url: [type: :string, allow_nil?: true],
    license: [type: :string, allow_nil?: true],
    pinned: [type: :string, allow_nil?: true],
    state: [type: :string, allow_nil?: false],
    installed_version: [type: :string, allow_nil?: true]
  ]

  actions do
    action :list_skills, :map do
      constraints fields: [
                    skills: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [items: [fields: @row_fields]]
                    ],
                    dismissed: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             {:ok, rows} <- Skills.list(ws, mount_key) do
          {:ok, %{skills: rows, dismissed: Mounts.skills_offers_dismissed(ws, mount_key)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :install_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.install(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :update_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :force, :boolean, allow_nil?: false, default: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, force: force, generation: generation} =
          input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.update(ws, mount_key, skill_id, force: force) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :uninstall_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.uninstall(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :dismiss_skills_offer, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Mounts.dismiss_skills_offer(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  # Central error mapping — the `Valea.Api.Icms.error_for/1` vocabulary.
  defp error_for(:no_workspace), do: Error.new("workspace_not_open")
  defp error_for(:mount_not_found), do: Error.new("icm_unavailable")
  defp error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  defp error_for(reason), do: Error.new(inspect(reason))
end
```

Also add `resource Valea.Api.Skills` inside `resources do` in `backend/lib/valea/api.ex`.

Check how `Valea.Api.Icms` actions surface `check_generation`'s stale error (it likely returns `{:error, reason}` handled by the same `else` branch) — mirror it exactly.

- [ ] **Step 4: Run to verify pass, plus the isolation guard**

Run: `cd backend && mix test test/valea/api/skills_test.exs test/valea/agents/session_settings_test.exs`
Expected: PASS — including the existing "session_server and the harness adapter never reference the /rpc/run surface" test (the new actions live behind the same control-token plug; nothing agent-facing references them).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/api/skills.ex backend/lib/valea/api.ex backend/test/valea/api/skills_test.exs
git commit -m "feat(skills): generation-guarded skills RPC resource"
```

---

### Task 8: RiskTier — `.claude/**` classifies high

**Files:**
- Modify: `backend/lib/valea/agents/risk_tier.ex`
- Test: `backend/test/valea/agents/risk_tier_test.exs` (append)

**Interfaces:**
- Consumes/produces: `RiskTier.classify/1` keeps its exact signature; only the rule set grows.

- [ ] **Step 1: Write the failing tests** (append to the existing test module, matching its assertion style — read it first)

```elixir
  test ".claude paths classify high at any depth (skills configure future agent behavior)" do
    assert RiskTier.classify(%{"kind" => "icm", "path" => ".claude/skills/icm-architect/SKILL.md"}) ==
             "high"

    assert RiskTier.classify(%{"kind" => "icm", "path" => ".claude/settings.json"}) == "high"

    assert RiskTier.classify(%{"kind" => "icm", "path" => "clients/.claude/skills/x/SKILL.md"}) ==
             "high"
  end

  test "a file merely named .claude-something stays medium" do
    assert RiskTier.classify(%{"kind" => "icm", "path" => "notes/.claude-ideas.md"}) == "medium"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs`
Expected: FAIL — `.claude/...` currently classifies "medium".

- [ ] **Step 3: Implement** (in `classify/1` for the icm clause; segment-bounded, not substring)

```elixir
  def classify(%{"kind" => "icm", "path" => path}) when is_binary(path) do
    if Path.basename(path) in @behavior_basenames or path == "icm.yaml" or
         ".claude" in Path.split(path) do
      "high"
    else
      "medium"
    end
  end
```

Update the `@moduledoc` and `@doc` first paragraphs to name the third rule: "…plus anything under a `.claude/` directory at any depth (skills and harness config change future agent behavior — ICM skills design spec, §Risk tier)."

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/agents/risk_tier.ex backend/test/valea/agents/risk_tier_test.exs
git commit -m "feat(skills): .claude/** classifies high in the risk tier"
```

---

### Task 9: Codegen + typed client wrappers

**Files:**
- Modify (generated): `frontend/src/lib/api/ash_rpc.ts`
- Modify: `frontend/src/lib/api/client.ts`

**Interfaces:**
- Consumes: the Task 7 resource (codegen source).
- Produces client methods the UI tasks call: `api.listSkills({mountKey, generation})`, `api.installSkill({mountKey, skillId, generation})`, `api.updateSkill({mountKey, skillId, force, generation})`, `api.uninstallSkill({mountKey, skillId, generation})`, `api.dismissSkillsOffer({mountKey, skillId, generation})` — each returning the repo's standard `{ok: true, data} | {ok: false, error}` wrapper.

- [ ] **Step 1: Regenerate the client**

Run: `cd backend && mix ash_typescript.codegen`
Expected: `frontend/src/lib/api/ash_rpc.ts` gains `listSkills`/`installSkill`/`updateSkill`/`uninstallSkill`/`dismissSkillsOffer` (+ `…Channel` variants and `Skills*` types). Inspect the generated names — codegen camelCases the action names; use whatever it actually produced.

- [ ] **Step 2: Wrap in `client.ts`**

Follow the `listIcms`/`mountIcm` wrappers in `frontend/src/lib/api/client.ts` verbatim: import the generated functions (aliased `http…`), declare the fields arrays the map actions need (mirror `harnessConfigFields`' pattern — for `listSkills` select all row fields plus `dismissed`), and export the five methods on the `api` object with the same error-wrapping the neighbors use. `client.ts` is the only module allowed to import `ash_rpc` — do not import it anywhere else.

- [ ] **Step 3: Verify types + staleness gate**

Run: `cd frontend && bun run check` and `cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/ 2>/dev/null; cd ../frontend && git status --short ../frontend/src/lib/api/`
Expected: `bun run check` passes; the second codegen run produces no further diff (client is fresh, wrappers compile).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/api/ash_rpc.ts frontend/src/lib/api/client.ts
git commit -m "feat(skills): typed RPC client for the skills actions"
```

---

### Task 10: Skills section in the agent settings modal

**Files:**
- Create: `frontend/src/lib/components/agent/SkillsPanel.svelte`
- Create: `frontend/src/lib/components/agent/SkillConsentDialog.svelte`
- Create: `frontend/src/lib/components/agent/skills-rows.ts`
- Test: `frontend/src/lib/components/agent/skills-rows.test.ts`
- Modify: `frontend/src/lib/components/agent/HarnessSettingsModal.svelte` (render `<SkillsPanel />` below the harness command block, under a "Skills" heading styled like the modal's existing section labels)

**Interfaces:**
- Consumes: `api.listIcms`, `api.listSkills`, `api.installSkill`, `api.updateSkill`, `api.uninstallSkill` (Task 9); generation from wherever the modal's neighbors get it (grep `client.ts`/stores for how `generation` is sourced — `workspaceStore` exposes it; follow an existing caller such as the mounts store).
- Produces: `skills-rows.ts` exports used by both components and the Task 11 card:

```typescript
export type SkillRow = {
  skillId: string;
  name: string;
  description: string | null;
  sourceUrl: string | null;
  license: string | null;
  pinned: string | null;
  state: 'not_installed' | 'foreign' | 'edited' | 'update_available' | 'installed';
  installedVersion: string | null;
};

export type SkillAction = 'install' | 'update' | 'remove' | null;

/** The one action a row offers. foreign -> null (display-only). */
export function actionFor(row: SkillRow): SkillAction;

/** Short state label for the row, e.g. "Installed", "Update available",
 *  "Edited by you", "Installed by hand" (foreign), "Not installed". */
export function stateLabel(row: SkillRow): string;
```

- [ ] **Step 1: Write the failing tests** (`skills-rows.test.ts`)

```typescript
import { describe, expect, test } from 'vitest';
import { actionFor, stateLabel, type SkillRow } from './skills-rows';

const base: SkillRow = {
  skillId: 'icm-architect',
  name: 'ICM Architect',
  description: 'd',
  sourceUrl: 'https://github.com/RinDig/icm-architect',
  license: 'MIT',
  pinned: 'sha',
  state: 'not_installed',
  installedVersion: null
};

describe('actionFor', () => {
  test('not_installed -> install', () => {
    expect(actionFor(base)).toBe('install');
  });

  test('installed -> remove', () => {
    expect(actionFor({ ...base, state: 'installed' })).toBe('remove');
  });

  test('update_available and edited -> update', () => {
    expect(actionFor({ ...base, state: 'update_available' })).toBe('update');
    expect(actionFor({ ...base, state: 'edited' })).toBe('update');
  });

  test('foreign -> null (display-only)', () => {
    expect(actionFor({ ...base, state: 'foreign' })).toBeNull();
  });
});

describe('stateLabel', () => {
  test('labels are plain language without exclamation marks', () => {
    for (const state of ['not_installed', 'foreign', 'edited', 'update_available', 'installed'] as const) {
      const label = stateLabel({ ...base, state });
      expect(label.length).toBeGreaterThan(0);
      expect(label).not.toContain('!');
    }
  });

  test('edited names the user, foreign names the hand-install', () => {
    expect(stateLabel({ ...base, state: 'edited' })).toBe('Edited by you');
    expect(stateLabel({ ...base, state: 'foreign' })).toBe('Installed by hand');
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd frontend && bun run test -- skills-rows`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement `skills-rows.ts`**

```typescript
// Pure row-state helpers shared by SkillsPanel, SkillConsentDialog, and
// the sidebar offer card. States mirror `Valea.Skills.state/2`'s
// vocabulary (ICM skills design spec, §On-disk contract).

export type SkillRow = {
  skillId: string;
  name: string;
  description: string | null;
  sourceUrl: string | null;
  license: string | null;
  pinned: string | null;
  state: 'not_installed' | 'foreign' | 'edited' | 'update_available' | 'installed';
  installedVersion: string | null;
};

export type SkillAction = 'install' | 'update' | 'remove' | null;

export function actionFor(row: SkillRow): SkillAction {
  switch (row.state) {
    case 'not_installed':
      return 'install';
    case 'update_available':
    case 'edited':
      return 'update';
    case 'installed':
      return 'remove';
    case 'foreign':
      return null;
  }
}

export function stateLabel(row: SkillRow): string {
  switch (row.state) {
    case 'not_installed':
      return 'Not installed';
    case 'installed':
      return 'Installed';
    case 'update_available':
      return 'Update available';
    case 'edited':
      return 'Edited by you';
    case 'foreign':
      return 'Installed by hand';
  }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && bun run test -- skills-rows`
Expected: PASS.

- [ ] **Step 5: Build the components** (Svelte components carry no unit tests in this repo — behavior lives in the tested `skills-rows.ts`; visual verification is Step 6)

`SkillConsentDialog.svelte` — props `{ open (bindable), mode: 'install' | 'update', row: SkillRow, mountKey: string, mountName: string, edited: boolean, onDone: () => void }`. A shadcn `Dialog` in the modal's existing style. Install copy (spec §Frontend, verbatim structure — substitute the real mount name and file count from the row; count is not in the row, so say "its files"):

> **Install {row.name} into {mountName}?**
> Adds its files under `.claude/skills/{row.skillId}/` in your ICM folder. It teaches your assistant how to structure this ICM's folders and add new workflow documents. After installing, the files are yours — readable, editable, and they travel with the folder.
> Source: {row.sourceUrl} ({row.license}).
> Buttons: `Install into {mountName}` (primary, green — the action color) / `Not now` (ghost).

Update mode: title "Update {row.name} in {mountName}?", body notes "{row.installedVersion} → {row.pinned}". When `edited` is true, add a terracotta warning line "You have edited this skill. Updating replaces your changes." and the primary button becomes `Replace my edited copy` (still requires this explicit label — never a bare "Update"). Confirm calls `api.installSkill` or `api.updateSkill({ force: edited })`, then `onDone()`.

`SkillsPanel.svelte` — no props. On mount: `api.listIcms` → for each ICM (parallel `api.listSkills`), render a per-ICM group (ICM name as a small overline) with one row per `SkillRow`: name, `stateLabel(...)`, description (ink-meta), and the `actionFor(...)` button (`remove` uses a plain `confirm()`-style shadcn AlertDialog: "Remove {name} from {mountName}? You can reinstall it any time." / buttons `Remove` / `Keep`). Errors render inline in the modal's existing error style. Reload the mount's rows after any action completes.

Wire into `HarnessSettingsModal.svelte`: a `<h3>`-level "Skills" section under the doctor panel, rendering `<SkillsPanel />` when the modal is open.

- [ ] **Step 6: Verify in the browser**

Start the dev servers (browser preview, `just dev` equivalent launch config), open the agent settings modal, and verify: the icm-architect row lists per mounted ICM as "Not installed"; Install opens the consent dialog; confirming installs (`.claude/skills/icm-architect/` appears in the ICM folder on disk) and the row flips to "Installed"; Remove round-trips back. Screenshot the modal for the task record.

- [ ] **Step 7: Type-check and commit**

Run: `cd frontend && bun run check && bun run test`
Expected: clean.

```bash
git add frontend/src/lib/components/agent/
git commit -m "feat(skills): skills section + consent dialog in agent settings"
```

---

### Task 11: Offer card in the sidebar

**Files:**
- Create: `frontend/src/lib/stores/skills-offer.svelte.ts`
- Test: `frontend/src/lib/stores/skills-offer.test.ts`
- Create: `frontend/src/lib/components/shell/SkillsOfferCard.svelte`
- Modify: `frontend/src/lib/components/shell/IcmProjects.svelte` (render the card under the matching ICM group)
- Modify: `frontend/src/lib/components/shell/MountIcmAction.svelte` + the onboarding mount/create/adopt success paths (`frontend/src/lib/components/onboarding/` — grep for where `mountIcm`/`createIcm`/`adoptIcm` succeed) to call `skillsOfferStore.offerFor(mountKey)`

**Interfaces:**
- Consumes: `api.listSkills`, `api.dismissSkillsOffer` (Task 9), `SkillConsentDialog` + `SkillRow` (Task 10).
- Produces: `skillsOfferStore` singleton:

```typescript
export type SkillOffer = { mountKey: string; row: SkillRow };

class SkillsOfferStore {
  /** Mount keys offered this app session (set by mount/create/adopt success). */
  offerFor(mountKey: string): Promise<void>; // loads listSkills, stores an offer if eligible
  /** The offer to render under this mount's sidebar group, or null. */
  offerUnder(mountKey: string): SkillOffer | null;
  /** User dismissed: RPC + retire locally. */
  dismiss(offer: SkillOffer): Promise<void>;
  /** Install completed elsewhere (consent dialog): retire locally. */
  retire(mountKey: string): void;
}
```

Eligibility inside `offerFor` (this is the tested logic, extracted as a pure function): a catalog row is offered iff `row.state === 'not_installed'` and `!dismissed.includes(row.skillId)`. Only the first eligible row is offered (one card, one skill — today there is only one).

- [ ] **Step 1: Write the failing tests** (test the pure eligibility function, not the store's RPC plumbing)

```typescript
import { describe, expect, test } from 'vitest';
import { eligibleOffer } from './skills-offer.svelte';
import type { SkillRow } from '$lib/components/agent/skills-rows';

const row = (state: SkillRow['state']): SkillRow => ({
  skillId: 'icm-architect',
  name: 'ICM Architect',
  description: 'd',
  sourceUrl: null,
  license: null,
  pinned: 'sha',
  state,
  installedVersion: null
});

describe('eligibleOffer', () => {
  test('not_installed and not dismissed -> offered', () => {
    expect(eligibleOffer([row('not_installed')], [])).toEqual(row('not_installed'));
  });

  test('dismissed -> null', () => {
    expect(eligibleOffer([row('not_installed')], ['icm-architect'])).toBeNull();
  });

  test('installed, update_available, edited, foreign -> null', () => {
    for (const state of ['installed', 'update_available', 'edited', 'foreign'] as const) {
      expect(eligibleOffer([row(state)], [])).toBeNull();
    }
  });

  test('first eligible row wins', () => {
    const other = { ...row('not_installed'), skillId: 'other' };
    expect(eligibleOffer([row('not_installed'), other], ['icm-architect'])).toEqual(other);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd frontend && bun run test -- skills-offer`
Expected: FAIL — module missing.

- [ ] **Step 3: Implement the store**

```typescript
// One-time skill offer per ICM, shown at the mount/create/adopt moment
// (ICM skills design spec, §Frontend/Offer card). Session-local by
// design: the card appears only right after a mount event in THIS app
// session; the durable suppression is the backend dismissed list plus
// the install itself. Never blocks, never nags.

import { api } from '$lib/api/client';
import type { SkillRow } from '$lib/components/agent/skills-rows';

export type SkillOffer = { mountKey: string; row: SkillRow };

export function eligibleOffer(rows: SkillRow[], dismissed: string[]): SkillRow | null {
  return rows.find((r) => r.state === 'not_installed' && !dismissed.includes(r.skillId)) ?? null;
}

class SkillsOfferStore {
  private offers = $state<Record<string, SkillOffer>>({});

  async offerFor(mountKey: string): Promise<void> {
    const result = await api.listSkills({ mountKey });
    if (!result.ok) return; // a failed load never surfaces a card
    const row = eligibleOffer(result.data.skills, result.data.dismissed);
    if (row) this.offers = { ...this.offers, [mountKey]: { mountKey, row } };
  }

  offerUnder(mountKey: string): SkillOffer | null {
    return this.offers[mountKey] ?? null;
  }

  async dismiss(offer: SkillOffer): Promise<void> {
    this.retire(offer.mountKey);
    await api.dismissSkillsOffer({ mountKey: offer.mountKey, skillId: offer.row.skillId });
  }

  retire(mountKey: string): void {
    const { [mountKey]: _gone, ...rest } = this.offers;
    this.offers = rest;
  }
}

export const skillsOfferStore = new SkillsOfferStore();
```

(Adapt the `api.listSkills` argument shape to what Task 9's wrapper actually takes — the generation argument is supplied inside `client.ts` wrappers if that's the existing house pattern; check how `listIcms` is called by its consumers and mirror it.)

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && bun run test -- skills-offer`
Expected: PASS.

- [ ] **Step 5: Card + wiring**

`SkillsOfferCard.svelte` — props `{ offer: SkillOffer, mountName: string }`. A quiet paper card (hairline border, no accent fill — amber is for suggestions, so the overline reads "Suggested" in amber ink) with: "Your assistant can learn the ICM methodology — install the {offer.row.name} skill into this folder?", buttons `Install…` (opens `SkillConsentDialog` with the offer's row; on done → `skillsOfferStore.retire(mountKey)`) and `Not now` (→ `skillsOfferStore.dismiss(offer)`).

`IcmProjects.svelte`: under each rendered ICM group, `{#if skillsOfferStore.offerUnder(mount.mountKey)}` render the card.

Callers: in `MountIcmAction.svelte` and each onboarding success path (wherever `api.mountIcm` / `api.createIcm` / `api.adoptIcm` resolve `ok`), fire `void skillsOfferStore.offerFor(mountKey)` with the returned mount key.

- [ ] **Step 6: Verify in the browser**

Mount a fresh ICM from the sidebar: the card appears under its group; `Not now` removes it and re-mounting another folder still offers (per-ICM independence); installing from the card flips the settings row to "Installed" and the card is gone. Restart the dev session: no card (session-local offer set), and the dismissed ICM never offers again even at re-mount (backend list).

- [ ] **Step 7: Type-check, test, commit**

Run: `cd frontend && bun run check && bun run test`
Expected: clean.

```bash
git add frontend/src/lib/stores/skills-offer.svelte.ts frontend/src/lib/stores/skills-offer.test.ts frontend/src/lib/components/shell/SkillsOfferCard.svelte frontend/src/lib/components/shell/IcmProjects.svelte frontend/src/lib/components/shell/MountIcmAction.svelte frontend/src/lib/components/onboarding/
git commit -m "feat(skills): one-time skill offer card at the mount moment"
```

---

### Task 12: Docs + full verification

**Files:**
- Modify: `docs/ARCHITECTURE.md` (new `## ICM skills` section after the Agent-native ICMs section, + spec-index entry)
- Modify: `docs/VISION.md` only if the roadmap list is maintained there for shipped items (it is — add nothing; skills are not a roadmap item, skip VISION.md)

**Interfaces:** none — documentation of Tasks 1–11 as built.

- [ ] **Step 1: Write the ARCHITECTURE.md section**

Add after the "Agent-native ICMs (Spec D)" block:

```markdown
## ICM skills

Consent-gated install of repo-vendored agent skills into a user-owned
ICM's `.claude/skills/` (spec:
`docs/superpowers/specs/2026-07-26-icm-skills-design.md`). Pinned
snapshots + `catalog.yaml` live in `backend/priv/skills/` (first entry:
icm-architect); no runtime fetching exists. `Valea.Skills` derives
per-mount state (`not_installed` → `foreign` → `edited` →
`update_available` → `installed`, first match wins) from a
`.provenance.yaml` hash-manifest sidecar written inside the installed
folder, and performs staged tmp+rename installs/updates/uninstalls with
`Valea.Paths.resolve_real/2` containment (a symlinked `.claude` refuses).
`Valea.Api.Skills` exposes list/install/update/uninstall/dismiss as
generation-guarded, control-token-gated actions — the settings click is
the consent step; agents have no RPC access. Updates are badge +
one-click, never silent; an edited install warns before overwrite
(`force`). `RiskTier` classifies anything under `.claude/` in a mount as
high. UI: a Skills section in the agent settings modal
(`SkillsPanel.svelte` + `SkillConsentDialog.svelte`) and a one-time,
dismissible offer card under the ICM's sidebar group at the
mount/create/adopt moment (dismissals persist per skill id in the
`icms:` entry's `skills_offers_dismissed` list).
```

Add to the spec index at the bottom of ARCHITECTURE.md: `2026-07-26-icm-skills-design.md — ICM skills (vendored install, consent, settings)` in the index's existing format.

- [ ] **Step 2: Full verification**

Run: `cd backend && mix test`
Expected: all pass.

Run: `cd frontend && bun run check && bun run test`
Expected: clean.

Run: `cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/`
Expected: no diff (generated client committed fresh).

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs(skills): ICM skills as-built record + spec index entry"
```
