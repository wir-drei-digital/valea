defmodule Valea.Mail.OpsFileTest do
  # async: false — each test writes into its own tmp workspace dir, but the
  # link-safety tests use hardlinks/symlinks under it; keeping this serial
  # avoids any cross-test interference with the shared tmp namespace.
  use ExUnit.Case, async: false

  alias Valea.Mail.OpsFile

  @account "mara"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-opsfile-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(pending_dir(root))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root, dir: dir}
  end

  # -- path helpers -----------------------------------------------------------

  defp account_dir(root), do: Path.join([root, "sources", "mail", @account])
  defp pending_dir(root), do: Path.join([account_dir(root), "ops", "pending"])
  defp done_dir(root), do: Path.join([account_dir(root), "ops", "done"])

  defp write_pending!(root, name, contents) do
    path = Path.join(pending_dir(root), name)
    File.write!(path, contents)
    path
  end

  # ==========================================================================
  # parse/1 — closed vocabulary
  # ==========================================================================

  describe "parse/1" do
    test "parses a move op" do
      yaml = """
      - op: move
        msg_id: 2026-07-15-alex-4f2a91c3
        from: INBOX
        to: Archive
      """

      assert {:ok,
              [%{op: :move, msg_id: "2026-07-15-alex-4f2a91c3", from: "INBOX", to: "Archive"}]} =
               OpsFile.parse(yaml)
    end

    test "parses a flag op with add/remove S/R/F" do
      yaml = """
      - op: flag
        msg_id: 2026-07-15-alex-4f2a91c3
        folder: INBOX
        add: [S, F]
        remove: [R]
      """

      assert {:ok,
              [
                %{
                  op: :flag,
                  msg_id: "2026-07-15-alex-4f2a91c3",
                  folder: "INBOX",
                  add: ["S", "F"],
                  remove: ["R"]
                }
              ]} = OpsFile.parse(yaml)
    end

    test "parses a multi-op list preserving order" do
      yaml = """
      - op: move
        msg_id: a
        from: INBOX
        to: Archive
      - op: flag
        msg_id: b
        folder: INBOX
        add: [S]
        remove: []
      """

      assert {:ok, [%{op: :move, msg_id: "a"}, %{op: :flag, msg_id: "b"}]} = OpsFile.parse(yaml)
    end

    test "an empty list is an error" do
      assert {:error, _} = OpsFile.parse("[]\n")
    end

    test "a non-list document is an error" do
      assert {:error, _} = OpsFile.parse("op: move\n")
    end

    test "unparseable YAML is an error, never a raise" do
      assert {:error, _} = OpsFile.parse(": : :\n\t- broken")
    end

    test "an unknown op verb is rejected" do
      yaml = """
      - op: teleport
        msg_id: a
        from: INBOX
        to: Archive
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "a delete op is rejected (not in the vocabulary)" do
      yaml = """
      - op: delete
        msg_id: a
        folder: INBOX
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "a flag op with a non-pushable flag letter (T) is rejected" do
      yaml = """
      - op: flag
        msg_id: a
        folder: INBOX
        add: [T]
        remove: []
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "a flag op with an unknown flag letter (X) is rejected" do
      yaml = """
      - op: flag
        msg_id: a
        folder: INBOX
        add: []
        remove: [X]
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "an extra key on a move op is rejected" do
      yaml = """
      - op: move
        msg_id: a
        from: INBOX
        to: Archive
        priority: high
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "a move op missing a required key is rejected" do
      yaml = """
      - op: move
        msg_id: a
        from: INBOX
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end

    test "a flag op with a non-list add is rejected" do
      yaml = """
      - op: flag
        msg_id: a
        folder: INBOX
        add: S
        remove: []
      """

      assert {:error, _} = OpsFile.parse(yaml)
    end
  end

  # ==========================================================================
  # validate/2 — occurrence validation
  # ==========================================================================

  describe "validate/2 move" do
    defp move_ctx(occ_map, known \\ ["INBOX", "Archive", "Work"], write_through \\ ["Trash"]) do
      %{
        account: @account,
        occurrences_by_msg_id: fn msg_id -> Map.get(occ_map, msg_id, []) end,
        known_folders: MapSet.new(known),
        write_through: MapSet.new(write_through)
      }
    end

    defp occ(folder), do: %{folder: folder, uid: 1, uidvalidity: 1, msg_id: "x"}

    test "exactly one occurrence in `from`, dest is a known folder → :ok" do
      ctx = move_ctx(%{"m" => [occ("INBOX")]})
      assert :ok = OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "Archive"}, ctx)
    end

    test "dest may be a write-through folder even if not in known_folders" do
      ctx = move_ctx(%{"m" => [occ("INBOX")]})
      assert :ok = OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "Trash"}, ctx)
    end

    test "msg_id resolving to no occurrence in `from` → rejected" do
      ctx = move_ctx(%{"m" => [occ("Work")]})

      assert {:rejected, _} =
               OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "Archive"}, ctx)
    end

    test "multi-occurrence ambiguity in `from` → rejected" do
      ctx = move_ctx(%{"m" => [occ("INBOX"), occ("INBOX")]})

      assert {:rejected, _} =
               OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "Archive"}, ctx)
    end

    test "unknown destination folder → rejected" do
      ctx = move_ctx(%{"m" => [occ("INBOX")]})

      assert {:rejected, _} =
               OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "Nowhere"}, ctx)
    end

    test "to == from → rejected" do
      ctx = move_ctx(%{"m" => [occ("INBOX")]})

      assert {:rejected, _} =
               OpsFile.validate(%{op: :move, msg_id: "m", from: "INBOX", to: "INBOX"}, ctx)
    end
  end

  describe "validate/2 flag" do
    defp flag_ctx(occ_map) do
      %{
        account: @account,
        occurrences_by_msg_id: fn msg_id -> Map.get(occ_map, msg_id, []) end,
        known_folders: MapSet.new(["INBOX", "Archive"]),
        write_through: MapSet.new([])
      }
    end

    test "exactly one occurrence in `folder`, pushable flags → :ok" do
      ctx = flag_ctx(%{"m" => [occ("INBOX")]})

      assert :ok =
               OpsFile.validate(
                 %{op: :flag, msg_id: "m", folder: "INBOX", add: ["S"], remove: ["R"]},
                 ctx
               )
    end

    test "no occurrence in `folder` → rejected" do
      ctx = flag_ctx(%{"m" => [occ("Archive")]})

      assert {:rejected, _} =
               OpsFile.validate(
                 %{op: :flag, msg_id: "m", folder: "INBOX", add: ["S"], remove: []},
                 ctx
               )
    end

    test "multiple occurrences in `folder` → rejected" do
      ctx = flag_ctx(%{"m" => [occ("INBOX"), occ("INBOX")]})

      assert {:rejected, _} =
               OpsFile.validate(
                 %{op: :flag, msg_id: "m", folder: "INBOX", add: ["S"], remove: []},
                 ctx
               )
    end
  end

  # ==========================================================================
  # claim_next/2 — opaque-id, link-safe claiming
  # ==========================================================================

  describe "claim_next/2" do
    test "no pending files → :none", %{root: root} do
      assert :none = OpsFile.claim_next(root, @account)
    end

    test "a regular file is claimed under a fresh 26-char opid; bytes + name returned", %{
      root: root
    } do
      contents = "- op: move\n  msg_id: a\n  from: INBOX\n  to: Archive\n"
      write_pending!(root, "cleanup.yaml", contents)

      assert {:ok, %{opid: opid, bytes: ^contents, original_name: "cleanup.yaml"}} =
               OpsFile.claim_next(root, @account)

      assert String.length(opid) == 26
      assert Regex.match?(~r/^[a-z2-7]{26}$/, opid)

      # The pending entry is gone; the claimed engine-owned copy exists.
      refute File.exists?(Path.join(pending_dir(root), "cleanup.yaml"))
      assert File.exists?(Path.join(done_dir(root), "#{opid}.yaml"))
    end

    test "claims oldest-mtime-first", %{root: root} do
      old = write_pending!(root, "old.yaml", "- op: move\n  msg_id: a\n  from: INBOX\n  to: X\n")
      # Backdate the first file so it is unambiguously older.
      past = System.os_time(:second) - 100
      File.touch!(old, past)
      write_pending!(root, "new.yaml", "- op: move\n  msg_id: b\n  from: INBOX\n  to: X\n")

      assert {:ok, %{original_name: "old.yaml"}} = OpsFile.claim_next(root, @account)
    end

    test "a symlink in pending is quarantined, never claimed", %{root: root, dir: dir} do
      # The symlink target lives OUTSIDE pending/, so the symlink is the only
      # pending entry — it is what gets picked, and it must be quarantined,
      # never followed and claimed.
      target = Path.join(dir, "secret-target.txt")
      File.write!(target, "secret")
      link = Path.join(pending_dir(root), "sneaky.yaml")
      :ok = File.ln_s(target, link)

      assert {:quarantined, "sneaky.yaml"} = OpsFile.claim_next(root, @account)
      assert :none = OpsFile.claim_next(root, @account)
      # The symlink moved to quarantine; nothing was claimed into done/.
      refute File.exists?(link)
      assert claimed_yamls(root) == []
      assert File.read!(target) == "secret"
    end

    test "a hard-linked file in pending is quarantined, never claimed", %{root: root} do
      original = Path.join(pending_dir(root), "orig.yaml")
      File.write!(original, "- op: move\n  msg_id: a\n  from: INBOX\n  to: X\n")
      hardlink = Path.join(pending_dir(root), "hard.yaml")
      :ok = File.ln(original, hardlink)

      # Both entries are hard-linked to each other (links == 2), so BOTH get
      # quarantined across successive claims; nothing is ever claimed.
      assert {:quarantined, _} = OpsFile.claim_next(root, @account)
      assert {:quarantined, _} = OpsFile.claim_next(root, @account)
      assert :none = OpsFile.claim_next(root, @account)
      assert claimed_yamls(root) == []
    end

    # `<opid>.yaml` claim files present in done/ (empty when done/ is absent).
    defp claimed_yamls(root) do
      case File.ls(done_dir(root)) do
        {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".yaml"))
        {:error, _} -> []
      end
    end

    test "a pending file named like an existing done file gets a fresh opid, clobbering nothing",
         %{root: root} do
      # Pre-existing claimed file + its result (a crash-recovery record).
      File.mkdir_p!(done_dir(root))
      existing_opid = "aaaaaaaaaaaaaaaaaaaaaaaaaa"
      existing_claim = Path.join(done_dir(root), "#{existing_opid}.yaml")
      existing_result = Path.join(done_dir(root), "#{existing_opid}.result.yaml")
      File.write!(existing_claim, "PRESERVED CLAIM")
      File.write!(existing_result, "PRESERVED RESULT")

      # An agent submits a pending file named exactly like the existing claim.
      write_pending!(
        root,
        "#{existing_opid}.yaml",
        "- op: move\n  msg_id: a\n  from: I\n  to: X\n"
      )

      assert {:ok, %{opid: opid}} = OpsFile.claim_next(root, @account)
      refute opid == existing_opid
      # Nothing overwritten.
      assert File.read!(existing_claim) == "PRESERVED CLAIM"
      assert File.read!(existing_result) == "PRESERVED RESULT"
    end

    test "post-claim hardlink swap: claim returns pre-swap bytes; replay refuses the tampered copy",
         %{root: root, dir: dir} do
      contents = "- op: move\n  msg_id: a\n  from: INBOX\n  to: Archive\n"
      write_pending!(root, "cleanup.yaml", contents)

      assert {:ok, %{opid: opid, bytes: ^contents}} = OpsFile.claim_next(root, @account)
      claimed = Path.join(done_dir(root), "#{opid}.yaml")

      # Attacker hardlinks the claimed file into a writable dir and overwrites
      # through the link AFTER claim returned.
      writable = Path.join(dir, "attacker")
      File.mkdir_p!(writable)
      alias_path = Path.join(writable, "alias")
      :ok = File.ln(claimed, alias_path)
      File.write!(alias_path, "- op: move\n  msg_id: EVIL\n  from: INBOX\n  to: Trash\n")

      # read_claimed!/1 on replay detects links > 1 and refuses.
      assert {:error, _} = OpsFile.read_claimed!(claimed)
    end
  end

  # ==========================================================================
  # write_results! / write_op_state! / read_op_states / unresolved
  # ==========================================================================

  describe "results + state sidecars" do
    test "write_results! round-trips as YAML", %{root: root} do
      opid = "bbbbbbbbbbbbbbbbbbbbbbbbbb"

      results = [
        %{"op" => 0, "result" => "ok", "reason" => nil},
        %{"op" => 1, "result" => "rejected", "reason" => "unknown_folder"}
      ]

      assert :ok = OpsFile.write_results!(root, @account, opid, "cleanup.yaml", results)

      path = Path.join(done_dir(root), "#{opid}.result.yaml")
      assert {:ok, doc} = YamlElixir.read_from_file(path)
      assert doc["file"] == "cleanup.yaml"

      assert [%{"op" => 0, "result" => "ok"}, %{"op" => 1, "result" => "rejected"}] =
               doc["results"]
    end

    test "write_op_state! / read_op_states round-trip per index", %{root: root} do
      opid = "cccccccccccccccccccccccccc"

      state0 = %{
        folder: "INBOX",
        uid: 42,
        uidvalidity: 7,
        baseline_flags: ["\\Seen"],
        modseq: 13,
        postcondition: %{add: ["F"], remove: []},
        source_uidvalidity: 7,
        fingerprint: "abcd"
      }

      assert :ok = OpsFile.write_op_state!(root, @account, opid, 0, state0)

      state1 = %{folder: "INBOX", uid: 43, uidvalidity: 7, modseq: nil}
      assert :ok = OpsFile.write_op_state!(root, @account, opid, 1, state1)

      states = OpsFile.read_op_states(root, @account, opid)
      assert states[0].folder == "INBOX"
      assert states[0].uid == 42
      assert states[0].baseline_flags == ["\\Seen"]
      assert states[0].modseq == 13
      assert states[0].postcondition == %{add: ["F"], remove: []}
      assert states[1].uid == 43
      assert states[1].modseq == nil
    end

    test "read_op_states on a missing sidecar → empty map", %{root: root} do
      assert OpsFile.read_op_states(root, @account, "dddddddddddddddddddddddddd") == %{}
    end

    test "unresolved/2 lists claimed files lacking a result sidecar only", %{root: root} do
      File.mkdir_p!(done_dir(root))
      # Unresolved: claim without result.
      unresolved_opid = "eeeeeeeeeeeeeeeeeeeeeeeeee"
      File.write!(Path.join(done_dir(root), "#{unresolved_opid}.yaml"), "- op: move\n")
      # Resolved: claim WITH result.
      resolved_opid = "ffffffffffffffffffffffffff"
      File.write!(Path.join(done_dir(root), "#{resolved_opid}.yaml"), "- op: move\n")
      File.write!(Path.join(done_dir(root), "#{resolved_opid}.result.yaml"), "file: x\n")

      unresolved = OpsFile.unresolved(root, @account)
      opids = Enum.map(unresolved, & &1.opid)
      assert unresolved_opid in opids
      refute resolved_opid in opids
      assert Enum.all?(unresolved, &File.exists?(&1.path))
    end

    test "unresolved/2 on an empty/absent done dir → []", %{root: root} do
      assert OpsFile.unresolved(root, @account) == []
    end
  end
end
