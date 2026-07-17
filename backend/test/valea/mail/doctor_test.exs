defmodule Valea.Mail.DoctorTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.Doctor

  @review "AI/Review"
  @processed "AI/Processed"
  @drafts "Drafts"

  # -- fixtures ---------------------------------------------------------------

  # TEMP v3-bridge: removed in Task 9 — `Valea.Mail.Settings` is now a v4
  # per-account struct (`slug`/`provider`/...) with no `account`/`folders.review`
  # fields, so `Doctor`'s ctx.settings is (for now) this plain v3-shaped map,
  # not a real `%Settings{}`. See `Valea.Mail.Engine`'s `load_settings/1`.
  defp settings(overrides \\ %{}) do
    Map.merge(
      %{
        account: "mara@example.com",
        imap: %{host: "localhost", port: 993, username: "mara@example.com"},
        folders: %{review: @review, processed: @processed, drafts: @drafts}
      },
      overrides
    )
  end

  defp ctx(overrides) do
    Map.merge(
      %{
        root: workspace_root(),
        settings: settings(),
        credential: fn -> "app-password" end,
        transport: FakeMailTransport
      },
      overrides
    )
  end

  defp workspace_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "vmail-doctor-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    # `config/` must exist up front: `Valea.Mounts.mount/2` (used below by
    # `AgentCase.mount_test_icm!/2`) writes straight to
    # `config/workspace.yaml` and never creates the parent dir itself.
    File.mkdir_p!(Path.join(root, "config"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # Mounts a REAL EXTERNAL ICM (via `AgentCase.mount_test_icm!/2`) carrying
  # a `Workflows/New Inquiry Triage.md` page, and returns that page's
  # ABSOLUTE resolved path. `Doctor.run/1` no longer reads any mounted ICM
  # content itself — this helper is kept as a realistic mount fixture for
  # tests that want a workspace with a registered ICM present, on top of
  # whatever body the caller passes (a valid `icm.yaml` manifest still
  # requires a parseable frontmatter block — hence the minimal
  # `---\nenabled: true\n---\n` prepended here).
  defp write_triage!(root, body) do
    content = "---\nenabled: true\n---\n" <> body

    icm =
      AgentCase.mount_test_icm!(root,
        name: "Starter",
        id: "73de3db8-81d1-40ae-afc2-daa2424cc5e7",
        pages: %{"Workflows/New Inquiry Triage.md" => content}
      )

    Path.join(icm.root, "Workflows/New Inquiry Triage.md")
  end

  @good_triage """
  # New Inquiry Triage

  ## Inputs

  | Input | Where |
  | --- | --- |
  | The inquiry email | a `sources/mail/messages/*.md` file |
  """

  # -- real TCP listener helpers -----------------------------------------------

  # A real listening socket on an ephemeral loopback port, for tcp_reachable's
  # "ok" path — accepts the doctor's probe connection and immediately closes.
  defp with_listener(fun) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    acceptor =
      spawn(fn ->
        case :gen_tcp.accept(listen_socket, 5_000) do
          {:ok, socket} -> :gen_tcp.close(socket)
          {:error, _} -> :ok
        end
      end)

    try do
      fun.(port)
    after
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_socket)
    end
  end

  # A port nothing is listening on: allocate an ephemeral port then close the
  # listener immediately, so a connect attempt gets a prompt refusal on
  # loopback rather than genuinely hanging.
  defp closed_port do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    :ok = :gen_tcp.close(listen_socket)
    port
  end

  defp full_script do
    [
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, [@review, @processed, @drafts]}},
      {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE", "UIDPLUS"]}},
      {:logout, :_, :ok}
    ]
  end

  setup do
    {:ok, _} = FakeMailTransport.start_link()
    :ok
  end

  # -- all-green run ------------------------------------------------------------

  test "all-green run: every check ok, overall ok true" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)
      FakeMailTransport.script(full_script())

      assert {:ok, %{checks: checks, ok: true}} =
               Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

      assert Enum.all?(checks, &(&1["status"] == "ok"))

      ids = Enum.map(checks, & &1["id"])

      assert ids == [
               "config_present",
               "credential_present",
               "tcp_reachable",
               "tls_ok",
               "login_ok",
               "folders",
               "move_capability"
             ]

      assert Enum.all?(checks, &Map.has_key?(&1, "label"))
      assert Enum.all?(checks, &Map.has_key?(&1, "detail"))
      assert Enum.all?(checks, &Map.has_key?(&1, "remedy"))
    end)
  end

  defp imap(port), do: %{host: "localhost", port: port, username: "mara@example.com"}

  # -- missing config gates everything after -----------------------------------

  test "missing config: config_present fails, every later check is unknown" do
    root = workspace_root()
    write_triage!(root, @good_triage)

    assert {:ok, %{checks: checks, ok: false}} = Doctor.run(ctx(%{root: root, settings: nil}))

    [config | rest] = checks
    assert config["id"] == "config_present"
    assert config["status"] == "failed"
    assert config["remedy"] =~ "mail account"

    assert Enum.all?(rest, &(&1["status"] == "unknown"))
  end

  # -- missing credential --------------------------------------------------------

  test "missing credential: credential_present fails, the network/transport checks are unknown" do
    root = workspace_root()
    write_triage!(root, @good_triage)

    assert {:ok, %{checks: checks, ok: false}} =
             Doctor.run(ctx(%{root: root, credential: nil}))

    by_id = Map.new(checks, &{&1["id"], &1})
    assert by_id["config_present"]["status"] == "ok"
    assert by_id["credential_present"]["status"] == "failed"
    assert by_id["credential_present"]["remedy"] =~ "password"

    for id <- ["tcp_reachable", "tls_ok", "login_ok", "folders", "move_capability"] do
      assert by_id[id]["status"] == "unknown"
    end
  end

  # -- tcp unreachable ------------------------------------------------------------

  test "tcp unreachable: tcp_reachable fails, the transport group is unknown" do
    root = workspace_root()
    write_triage!(root, @good_triage)
    port = closed_port()

    assert {:ok, %{checks: checks, ok: false}} =
             Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

    by_id = Map.new(checks, &{&1["id"], &1})
    assert by_id["tcp_reachable"]["status"] == "failed"
    assert by_id["tls_ok"]["status"] == "unknown"
    assert by_id["login_ok"]["status"] == "unknown"
    assert by_id["folders"]["status"] == "unknown"
    assert by_id["move_capability"]["status"] == "unknown"
    # no transport call was ever attempted
    assert FakeMailTransport.calls() == []
  end

  # -- auth failure -----------------------------------------------------------

  test "auth failure: tls_ok ok, login_ok fails, folders/move unknown" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)

      FakeMailTransport.script([{:connect, :_, {:error, :auth_failed}}])

      assert {:ok, %{checks: checks, ok: false}} =
               Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

      by_id = Map.new(checks, &{&1["id"], &1})
      assert by_id["tls_ok"]["status"] == "ok"
      assert by_id["login_ok"]["status"] == "failed"
      assert by_id["login_ok"]["remedy"] =~ "username"
      assert by_id["folders"]["status"] == "unknown"
      assert by_id["move_capability"]["status"] == "unknown"
    end)
  end

  # -- connect failure below TLS -------------------------------------------------

  test "connect error other than auth_failed: tls_ok fails, login/folders/move unknown" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)

      FakeMailTransport.script([{:connect, :_, {:error, :closed}}])

      assert {:ok, %{checks: checks, ok: false}} =
               Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

      by_id = Map.new(checks, &{&1["id"], &1})
      assert by_id["tls_ok"]["status"] == "failed"
      assert by_id["login_ok"]["status"] == "unknown"
      assert by_id["folders"]["status"] == "unknown"
      assert by_id["move_capability"]["status"] == "unknown"
    end)
  end

  # -- missing folders + create_folders round-trip -------------------------------

  test "missing folders: lists them; create_folders then a re-run turns folders ok" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)
      the_ctx = ctx(%{root: root, settings: settings(%{imap: imap(port)})})

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, ["INBOX"]}},
        {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE"]}},
        {:logout, :_, :ok}
      ])

      assert {:ok, %{checks: checks}} = Doctor.run(the_ctx)
      folders = Enum.find(checks, &(&1["id"] == "folders"))
      assert folders["status"] == "failed"
      assert folders["detail"] =~ @review
      assert folders["detail"] =~ @processed
      assert folders["detail"] =~ @drafts
      assert folders["remedy"] =~ "Create AI folders"
      assert folders["remedy"] =~ "drafts"

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, ["INBOX"]}},
        {:create_folder, [:_, @review], :ok},
        {:create_folder, [:_, @processed], :ok},
        {:logout, :_, :ok}
      ])

      assert {:ok, created} = Doctor.create_folders(the_ctx)
      assert Enum.sort(created) == Enum.sort([@review, @processed])

      FakeMailTransport.script(full_script())
      assert {:ok, %{checks: checks2}} = Doctor.run(the_ctx)
      folders2 = Enum.find(checks2, &(&1["id"] == "folders"))
      assert folders2["status"] == "ok"
    end)
  end

  test "create_folders never tries to create the drafts folder" do
    root = workspace_root()
    the_ctx = ctx(%{root: root})

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["INBOX"]}},
      {:create_folder, [:_, @review], :ok},
      {:create_folder, [:_, @processed], :ok},
      {:logout, :_, :ok}
    ])

    assert {:ok, created} = Doctor.create_folders(the_ctx)
    assert Enum.sort(created) == Enum.sort([@review, @processed])
    refute Enum.any?(FakeMailTransport.calls(), &match?({:create_folder, [_, @drafts]}, &1))
  end

  test "create_folders skips a folder whose creation fails, but still creates the other" do
    root = workspace_root()
    the_ctx = ctx(%{root: root})

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, []}},
      {:create_folder, [:_, @review], {:error, :denied}},
      {:create_folder, [:_, @processed], :ok},
      {:logout, :_, :ok}
    ])

    assert {:ok, created} = Doctor.create_folders(the_ctx)
    assert created == [@processed]
  end

  test "create_folders propagates a connect failure" do
    root = workspace_root()
    the_ctx = ctx(%{root: root})
    FakeMailTransport.script([{:connect, :_, {:error, :econnrefused}}])

    assert {:error, :econnrefused} = Doctor.create_folders(the_ctx)
  end

  test "create_folders scrubs the credential from a connect error before returning it" do
    root = workspace_root()
    secret = "hunter2-super-secret-XYZ"
    the_ctx = ctx(%{root: root, credential: fn -> secret end})

    FakeMailTransport.script([{:connect, :_, {:error, {:weird, secret}}}])

    assert {:error, reason} = Doctor.create_folders(the_ctx)
    refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  test "already-complete folders: create_folders is a no-op" do
    root = workspace_root()
    the_ctx = ctx(%{root: root})

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, [@review, @processed, @drafts]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, []} = Doctor.create_folders(the_ctx)
  end

  # -- move capability ------------------------------------------------------------

  test "neither MOVE nor UIDPLUS: move_capability fails with the manual-move remedy" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, [@review, @processed, @drafts]}},
        {:capabilities, :_, {:ok, ["IMAP4rev1"]}},
        {:logout, :_, :ok}
      ])

      assert {:ok, %{checks: checks}} =
               Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

      move = Enum.find(checks, &(&1["id"] == "move_capability"))
      assert move["status"] == "failed"

      assert move["remedy"] ==
               "Your server supports neither MOVE nor UIDPLUS — Valea will leave messages in AI/Review and you move them manually."
    end)
  end

  test "UIDPLUS fallback when MOVE is absent" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, [@review, @processed, @drafts]}},
        {:capabilities, :_, {:ok, ["IMAP4rev1", "UIDPLUS"]}},
        {:logout, :_, :ok}
      ])

      assert {:ok, %{checks: checks}} =
               Doctor.run(ctx(%{root: root, settings: settings(%{imap: imap(port)})}))

      move = Enum.find(checks, &(&1["id"] == "move_capability"))
      assert move["status"] == "ok"
      assert move["detail"] == "UIDPLUS fallback"
    end)
  end

  # -- credential redaction ------------------------------------------------------------

  test "the credential never appears in the result, even on failures" do
    with_listener(fn port ->
      root = workspace_root()
      write_triage!(root, @good_triage)
      secret = "hunter2-super-secret-XYZ"

      FakeMailTransport.script([{:connect, :_, {:error, {:weird, secret}}}])

      {:ok, result} =
        Doctor.run(
          ctx(%{
            root: root,
            settings: settings(%{imap: imap(port)}),
            credential: fn -> secret end
          })
        )

      dump = inspect(result, limit: :infinity, printable_limit: :infinity)
      refute dump =~ secret
    end)
  end
end
