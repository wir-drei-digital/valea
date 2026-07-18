defmodule Valea.ICM.SearchTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.ICM.Search
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "AND semantics across title and body, ranked title-first", %{workspace: ws} do
    AgentCase.mount_test_icm!(ws,
      name: "Primary",
      pages: %{
        "Offers/Retainer.md" => "# Retainer\n\nMonthly coaching retainer.\n",
        "Clients/Note.md" => "# Note\n\nDiscussed a retainer with Julia.\n"
      }
    )

    retainer_path = "Offers/Retainer.md"
    note_path = "Clients/Note.md"

    {:ok, %{results: results}} = Search.search(ws, "retainer")
    paths = Enum.map(results, & &1.path)
    assert Enum.at(paths, 0) == retainer_path
    assert note_path in paths

    {:ok, %{results: both}} = Search.search(ws, "retainer julia")
    assert Enum.map(both, & &1.path) == [note_path]
  end

  test "workflow contracts are searchable; snippet carries the match", %{workspace: ws} do
    AgentCase.mount_test_icm!(ws,
      name: "Primary",
      pages: %{
        "Workflows/New Inquiry Triage.md" =>
          "# New Inquiry Triage\n\nClassify incoming inquiries by intent.\n"
      }
    )

    {:ok, %{results: results}} = Search.search(ws, "classify")
    assert Enum.any?(results, &String.contains?(&1.path, "Workflows/"))
    hit = Enum.find(results, &String.contains?(&1.path, "Workflows/"))
    assert String.downcase(hit.snippet) =~ "classify"
    assert hit.terms == ["classify"]
  end

  test "disabled mounts are excluded", %{workspace: ws} do
    icm =
      AgentCase.mount_test_icm!(ws,
        name: "Primary",
        pages: %{"Offers/Retainer.md" => "# Retainer\n\nMonthly coaching retainer.\n"}
      )

    :ok = Valea.Mounts.set_enabled(ws, icm.mount_key, false)
    {:ok, %{results: results}} = Search.search(ws, "coaching")
    assert results == []
    :ok = Valea.Mounts.set_enabled(ws, icm.mount_key, true)
  end

  test "a mount over budget is skipped and reported", %{workspace: ws} do
    # A large body (mirrors the "two mounts both over budget" fixture
    # below) so the scan genuinely cannot finish within `timeout_ms: 0`
    # regardless of scheduler timing -- a trivial one-line fixture can
    # race ahead of `Task.yield_many/2`'s own zero-wait check on a
    # fast/idle machine.
    slow_body =
      String.duplicate("the quick brown fox jumps over the lazy dog coaching ", 240_000)

    icm =
      AgentCase.mount_test_icm!(ws,
        name: "Primary",
        pages: %{"Offers/Retainer.md" => slow_body}
      )

    # ICM mounts only — `enabled/1` also carries the synthetic calendar
    # mount (Spec F Task 5), which the search surface never scans.
    [mount] = Enum.filter(Valea.Mounts.enabled(ws), &(&1.kind == :icm))

    {:ok, %{results: [], skipped: [skipped_name]}} =
      Search.search(ws, "coaching", nil, mounts: [mount], timeout_ms: 0)

    assert skipped_name == icm.mount_key
  end

  test "two mounts both over budget share one deadline, not a compounding one", %{
    workspace: ws
  } do
    # Each mount root holds a single large file. Scanning it (downcase, regex
    # snippet, term matching) takes far longer than either `timeout` or
    # `2 * timeout` below, so both mounts are legitimately too slow under any
    # implementation. What differs is the WALL TIME to find that out: the old
    # sequential `Task.yield` reduce checks mounts one at a time, so mount two
    # inherits a second full `timeout` window on top of mount one's — total
    # wall time compounds toward `2 * timeout`. The shared-deadline fix
    # (`Task.yield_many/2`) waits `timeout` once for every mount together, so
    # total wall time stays close to `timeout` regardless of mount count.
    slow_body = String.duplicate("the quick brown fox jumps over the lazy dog needle ", 240_000)

    dir_a = Path.join(ws, "slow_a")
    dir_b = Path.join(ws, "slow_b")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)
    File.write!(Path.join(dir_a, "big.md"), slow_body)
    File.write!(Path.join(dir_b, "big.md"), slow_body)

    mounts = [
      %{name: "slow_a", root: dir_a},
      %{name: "slow_b", root: dir_b}
    ]

    timeout = 100

    started = System.monotonic_time(:millisecond)

    {:ok, %{results: [], skipped: skipped}} =
      Search.search(ws, "needle", nil, mounts: mounts, timeout_ms: timeout)

    elapsed = System.monotonic_time(:millisecond) - started

    assert Enum.sort(skipped) == ["slow_a", "slow_b"]

    # Well under 2 * timeout (200ms): a compounding sequential wait would
    # land close to 200ms; a shared deadline lands close to 100ms.
    assert elapsed < 1.5 * timeout,
           "expected shared-deadline wall time (~#{timeout}ms), got #{elapsed}ms — " <>
             "looks like the per-mount budget is compounding across mounts"
  end

  test "empty and whitespace queries return nothing", %{workspace: ws} do
    assert {:ok, %{results: [], skipped: []}} = Search.search(ws, "   ")
  end

  test "regex metacharacters are literal text", %{workspace: ws} do
    AgentCase.mount_test_icm!(ws,
      name: "Primary",
      pages: %{"Offers/Weird.md" => "# Weird\n\nprice (150) [draft]\n"}
    )

    weird_path = "Offers/Weird.md"

    {:ok, %{results: results}} = Search.search(ws, "(150)")
    assert Enum.map(results, & &1.path) == [weird_path]
  end

  test "a query that is invalid as a regex is still treated as literal text", %{workspace: ws} do
    # "[draft" has an unmatched `[`, so compiling it as a regex would fail
    # (or need special error handling). It must still match literally via
    # String.contains?/2, proving no Regex.compile/1 path exists.
    AgentCase.mount_test_icm!(ws,
      name: "Primary",
      pages: %{"Offers/Weird.md" => "# Weird\n\nprice (150) [draft]\n"}
    )

    weird_path = "Offers/Weird.md"

    assert {:error, _} = Regex.compile("[draft")

    {:ok, %{results: results}} = Search.search(ws, "[draft")
    assert Enum.map(results, & &1.path) == [weird_path]
  end

  test "snippet cutting survives downcase byte-growth pushing a match past the body's own length",
       %{workspace: ws} do
    # Turkish dotted capital İ (2 bytes in UTF-8) downcases to "i" + a
    # combining dot above (3 bytes) — one extra byte per character. Enough
    # of them ahead of a match term pushes the match's byte offset in the
    # *downcased* body past `byte_size/1` of the *original* body, which used
    # to drive `binary_part/3` to a negative length and crash. This locks in
    # the fix (`safe_pos` clamp in `snippet/3`).
    body = "# Turkish\n\n" <> String.duplicate("İ", 120) <> " target\n"

    AgentCase.mount_test_icm!(ws, name: "Primary", pages: %{"Offers/Turkish.md" => body})

    turkish_path = "Offers/Turkish.md"

    assert {:ok, %{results: results}} = Search.search(ws, "target")
    assert Enum.any?(results, &(&1.path == turkish_path))
  end

  describe "scoped to primary + related ICMs (task 5.6)" do
    test "a mount_key scopes the scan to itself plus its declared-related ICM, never an unrelated third",
         %{workspace: ws} do
      b =
        AgentCase.mount_test_icm!(ws,
          name: "B",
          pages: %{"Note.md" => "# Note\n\ncoaching notes live here\n"}
        )

      c =
        AgentCase.mount_test_icm!(ws,
          name: "C",
          pages: %{"Note.md" => "# Note\n\ncoaching notes live here too\n"}
        )

      a =
        AgentCase.mount_test_icm!(ws,
          name: "A",
          pages: %{
            "Home.md" => "# Home\n\ncoaching starts here\n",
            "CONTEXT.md" => related_icms_frontmatter(b.id)
          }
        )

      {:ok, %{results: results}} = Search.search(ws, "coaching", a.mount_key)
      mounts_hit = results |> Enum.map(& &1.mount) |> Enum.uniq() |> Enum.sort()

      assert mounts_hit == Enum.sort([a.mount_key, b.mount_key])
      refute c.mount_key in mounts_hit
    end

    test "mount_key: nil preserves the pre-5.6 default of every enabled mount", %{workspace: ws} do
      a =
        AgentCase.mount_test_icm!(ws,
          name: "A",
          pages: %{"Home.md" => "# Home\n\ncoaching starts here\n"}
        )

      b =
        AgentCase.mount_test_icm!(ws,
          name: "B",
          pages: %{"Note.md" => "# Note\n\ncoaching notes live here\n"}
        )

      {:ok, %{results: results}} = Search.search(ws, "coaching")
      mounts_hit = results |> Enum.map(& &1.mount) |> Enum.uniq() |> Enum.sort()

      assert mounts_hit == Enum.sort([a.mount_key, b.mount_key])
    end
  end

  # Minimal `CONTEXT.md` frontmatter declaring `related_id` as a directly
  # related ICM, mirroring `Valea.Mounts.ContextTest`'s own fixture shape.
  defp related_icms_frontmatter(related_id) do
    """
    ---
    format: 1
    related_icms:
      - id: #{related_id}
        name: "Related"
    ---
    """
  end
end
