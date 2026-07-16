# A `Transport` double whose `connect/3` announces itself to a probe pid and
# then blocks until released — so a test can observe the Engine's "syncing"
# state while a pass is genuinely in flight (rather than racing a fast fake).
# It blocks in the pass *Task*, never in the Engine, so status/sync_now calls
# stay responsive.
defmodule Valea.Mail.EngineTest.HangingTransport do
  @behaviour Valea.Mail.Transport

  @impl true
  def connect(_config, _credential, _opts) do
    send(Application.get_env(:valea, :engine_sync_probe), {:connect_called, self()})

    receive do
      {:release, result} -> result
    end
  end

  @impl true
  def capabilities(_conn), do: {:ok, []}
  @impl true
  def list_folders(_conn), do: {:ok, []}
  @impl true
  def create_folder(_conn, _folder), do: :ok
  @impl true
  def select(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1}}
  @impl true
  def uid_search(_conn, _criteria), do: {:ok, []}
  @impl true
  def uid_fetch_meta(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_headers(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_full(_conn, _uid), do: {:ok, ""}
  @impl true
  def uid_move(_conn, _uid, _folder), do: :ok
  @impl true
  def append(_conn, _folder, _flags, _rfc822), do: :ok
  @impl true
  def logout(_conn), do: :ok
end

# A `Transport` double whose `connect/3` returns an error reason that EMBEDS
# the raw credential — the worst case for the leak-into-`last_error` path. The
# Engine must scrub it back out before it reaches the status field or a log.
defmodule Valea.Mail.EngineTest.LeakyConnectTransport do
  @behaviour Valea.Mail.Transport

  @impl true
  def connect(_config, credential, _opts) do
    {:error, {:tls_alert, "handshake failed for " <> credential}}
  end

  @impl true
  def capabilities(_conn), do: {:ok, []}
  @impl true
  def list_folders(_conn), do: {:ok, []}
  @impl true
  def create_folder(_conn, _folder), do: :ok
  @impl true
  def select(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1}}
  @impl true
  def uid_search(_conn, _criteria), do: {:ok, []}
  @impl true
  def uid_fetch_meta(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_headers(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_full(_conn, _uid), do: {:ok, ""}
  @impl true
  def uid_move(_conn, _uid, _folder), do: :ok
  @impl true
  def append(_conn, _folder, _flags, _rfc822), do: :ok
  @impl true
  def logout(_conn), do: :ok
end

defmodule Valea.Mail.EngineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Valea.AgentCase
  alias Valea.Mail.Engine

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "vmail-engine-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_settings!(root, host, username) do
    File.write!(Path.join(root, "config/mail.yaml"), """
    account: #{username}
    imap:
      host: #{host}
      port: 993
      username: #{username}
    """)
  end

  defp start_engine!(root, generation) do
    start_supervised!({Engine, %{root: root, generation: generation}})
  end

  test "boots inert: state inactive, sync_now refuses", %{root: root} do
    start_engine!(root, 1)

    assert %{
             state: "inactive",
             configured: false,
             credential: "missing",
             last_sync_at: nil,
             last_error: nil,
             account: nil,
             username: nil,
             workspace_id: nil
           } = Engine.status()

    assert Engine.sync_now() == {:error, :inactive}
  end

  test "a mismatched-generation broadcast is ignored", %{root: root} do
    start_engine!(root, 2)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 1}
    )

    # synchronize with the (ignored) message having been processed
    assert Engine.status().state == "inactive"
  end

  test "activates only on its own generation's workspace_opened broadcast", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 3)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 3}
    )

    status = Engine.status()
    assert status.state == "idle"
    assert status.configured == true
    assert status.account == "mara@example.com"
  end

  test "status exposes the IMAP username distinct from the account label", %{root: root} do
    # account (display label) deliberately differs from imap.username (the
    # login) — the frontend's keychain lookup is keyed on the USERNAME
    # (spec §Credentials: account = workspace_id:username), so status must
    # surface it separately rather than making callers guess from `account`.
    File.write!(Path.join(root, "config/mail.yaml"), """
    account: Mara's mail
    imap:
      host: imap.fastmail.com
      port: 993
      username: mara@example.com
    """)

    start_engine!(root, 29)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 29}
    )

    status = Engine.status()
    assert status.account == "Mara's mail"
    assert status.username == "mara@example.com"
  end

  test "reads the workspace id from config/workspace.yaml at activation", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 3\nid: ws-abc-123\n")
    start_engine!(root, 30)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 30}
    )

    assert Engine.status().workspace_id == "ws-abc-123"
  end

  test "workspace_id stays nil when config/workspace.yaml is absent", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 31)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 31}
    )

    assert Engine.status().workspace_id == nil
  end

  test "reload_settings/0 re-reads config/mail.yaml and broadcasts :mail_status_changed", %{
    root: root
  } do
    start_engine!(root, 32)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 32}
    )

    assert Engine.status().configured == false

    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.reload_settings()

    assert_receive {:mail_status_changed, status}
    assert status.configured == true
    assert status.account == "mara@example.com"
    assert Engine.status().configured == true
  end

  test "placeholder settings (not-yet-configured) -> configured false, sync_now not_configured",
       %{
         root: root
       } do
    write_settings!(root, "imap.example.com", "mara@example.com")
    start_engine!(root, 5)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 5}
    )

    status = Engine.status()
    assert status.configured == false
    assert Engine.sync_now() == {:error, :not_configured}
  end

  test "configured but no credential -> sync_now no_credential", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 6)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 6}
    )

    assert Engine.sync_now() == {:error, :no_credential}
  end

  test "set_credential flips status and broadcasts :mail_status_changed", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 7)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 7}
    )

    assert Engine.status().credential == "missing"

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    assert :ok = Engine.set_credential("hunter2-secret")

    assert_receive {:mail_status_changed, status}
    assert status.credential == "present"
    assert Engine.status().credential == "present"
  end

  test "env fallback: VALEA_MAIL_PASSWORD is picked up at activation when unset previously", %{
    root: root
  } do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    System.put_env("VALEA_MAIL_PASSWORD", "dev-fallback-secret")
    on_exit(fn -> System.delete_env("VALEA_MAIL_PASSWORD") end)

    start_engine!(root, 8)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 8}
    )

    assert Engine.status().credential == "present"
  end

  test "no env fallback when VALEA_MAIL_PASSWORD is unset", %{root: root} do
    System.delete_env("VALEA_MAIL_PASSWORD")
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 9)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 9}
    )

    assert Engine.status().credential == "missing"
  end

  test "redaction: :sys.get_state never exposes the raw credential", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 10)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 10}
    )

    secret = "super-duper-secret-password-XYZ"
    :ok = Engine.set_credential(secret)

    dump =
      Valea.Mail.Engine
      |> :sys.get_state()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute dump =~ secret
  end

  test "doctor/0 on an inert (inactive) engine: config_present fails, everything after it is unknown",
       %{root: root} do
    start_engine!(root, 15)

    assert {:ok, %{ok: false, checks: checks}} = Engine.doctor()
    by_id = Map.new(checks, &{&1["id"], &1})
    assert by_id["config_present"]["status"] == "failed"
    assert by_id["workflow_contract"]["status"] == "unknown"
  end

  test "create_folders/0 refuses on an inert (inactive) engine", %{root: root} do
    start_engine!(root, 16)
    assert Engine.create_folders() == {:error, :inactive}
  end

  test "create_folders/0 refuses when configured but not credentialed", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 17)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 17}
    )

    assert Engine.create_folders() == {:error, :no_credential}
  end

  # Proves the full wiring, not just the gates: doctor/0 threads the
  # Engine's real settings/credential/transport into Doctor.run/1 (real
  # gen_tcp listener for tcp_reachable + FakeMailTransport for the rest),
  # and create_folders/0 threads the same snapshot into
  # Doctor.create_folders/1.
  test "doctor/0 and create_folders/0 against a real, activated engine: full green + folder creation",
       %{root: root} do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    acceptor =
      spawn(fn ->
        Enum.each(1..2, fn _ ->
          case :gen_tcp.accept(listen_socket, 5_000) do
            {:ok, socket} -> :gen_tcp.close(socket)
            {:error, _} -> :ok
          end
        end)
      end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_socket)
    end)

    Application.put_env(:valea, :mail_transport, FakeMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    {:ok, _} = FakeMailTransport.start_link()

    write_settings!(root, "localhost", "mara@example.com")
    # write_settings!/3 doesn't set a port, so patch it in directly.
    File.write!(Path.join(root, "config/mail.yaml"), """
    account: mara@example.com
    imap:
      host: localhost
      port: #{port}
      username: mara@example.com
    """)

    # The raw tmp root this test module uses (unlike AgentCase's full
    # template) has no mounts/ tree at all; give workflow_contract a
    # discoverable, non-legacy triage workflow to read (Task A-T13:
    # `Valea.Workflows.triage_path/1` requires a real mount — valid
    # icm.yaml manifest plus a parseable frontmatter block — not just a
    # file at the old hardcoded path) so this test proves a genuine
    # full-green run. Post-task-3.2, `Valea.Mounts.list/1` is config truth
    # over `icms:` ONLY — no more filesystem-glob discovery of an embedded
    # `mounts/<name>` — so this must be a REAL, REGISTERED external ICM
    # (`AgentCase.mount_test_icm!/2`), not a bare folder on disk.
    AgentCase.mount_test_icm!(root,
      name: "Starter",
      id: "73de3db8-81d1-40ae-afc2-daa2424cc5e7",
      pages: %{
        "Workflows/New Inquiry Triage.md" =>
          "---\nenabled: true\n---\n# New Inquiry Triage\n\nInputs: a `sources/mail/messages/*.md` file.\n"
      }
    )

    start_engine!(root, 18)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 18}
    )

    :ok = Engine.set_credential("app-password")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["AI/Review", "AI/Processed", "Drafts"]}},
      {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE"]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{ok: true, checks: checks}} = Engine.doctor()
    assert Enum.all?(checks, &(&1["status"] == "ok"))

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["Drafts"]}},
      {:create_folder, [:_, "AI/Review"], :ok},
      {:create_folder, [:_, "AI/Processed"], :ok},
      {:logout, :_, :ok}
    ])

    assert {:ok, created} = Engine.create_folders()
    assert Enum.sort(created) == Enum.sort(["AI/Review", "AI/Processed"])
  end

  test "an unsolicited :poll (simulating the timer firing) keeps the engine alive and idle", %{
    root: root
  } do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 12)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 12}
    )

    pid = Process.whereis(Engine)
    send(pid, :poll)

    assert Engine.status().state == "idle"
    assert Process.alive?(pid)
  end

  test "auth_failed pauses polling; set_credential clears it and re-arms", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 13)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 13}
    )

    pid = Process.whereis(Engine)
    :sys.replace_state(pid, fn state -> %{state | status: "auth_failed"} end)

    send(pid, :poll)
    # a poll tick while auth_failed must not re-arm the timer
    assert %{poll_timer: nil} = :sys.get_state(pid)
    assert Engine.status().state == "auth_failed"

    assert :ok = Engine.set_credential("new-secret")
    state_after = :sys.get_state(pid)
    assert state_after.status == "idle"
    assert state_after.poll_timer != nil
    assert Engine.status().state == "idle"
  end

  test "sync_now runs a pass in the background: status 'syncing', single-flight, result flips state",
       %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")

    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 20)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 20}
    )

    :ok = Engine.set_credential("app-password")
    # set_credential itself never starts a pass (only the timer / sync_now do)
    assert Engine.status().state == "idle"

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now()
    assert_receive {:connect_called, task_pid}
    assert Engine.status().state == "syncing"

    # a second sync_now while a pass is in flight is a no-op :ok — no new pass
    assert :ok = Engine.sync_now()
    refute_receive {:connect_called, _another}, 100

    # release the pass; its {:error, :auth_failed} flips status and finishes
    send(task_pid, {:release, {:error, :auth_failed}})
    assert_receive {:mail_sync_finished, %{new_messages: 0, errors: ["authentication failed"]}}
    assert Engine.status().state == "auth_failed"
    assert %{poll_timer: nil, sync_task: nil} = :sys.get_state(Process.whereis(Engine))
  end

  test "a pass task killed mid-flight is a failed pass: status recovers, never stuck syncing",
       %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")

    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 21)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 21}
    )

    :ok = Engine.set_credential("app-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now()
    assert_receive {:connect_called, task_pid}
    assert Engine.status().state == "syncing"

    # kill the pass task before it reports — the Engine's :DOWN handler must
    # treat it as a failed pass, not wedge in "syncing"
    Process.exit(task_pid, :kill)

    assert_receive {:mail_sync_finished, %{new_messages: 0, errors: [error]}}
    assert error =~ "sync failed"
    assert Engine.status().state == "idle"
    assert %{sync_task: nil} = :sys.get_state(Process.whereis(Engine))

    # and a fresh pass can start afterwards
    assert :ok = Engine.sync_now()
    assert_receive {:connect_called, new_task_pid}
    send(new_task_pid, {:release, {:error, :test_done}})
    assert_receive {:mail_sync_finished, _payload}
    assert Engine.status().state == "idle"
  end

  test "a sync task in flight is killed when the Engine stops (does not outlive it)", %{
    root: root
  } do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")

    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 41)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 41}
    )

    :ok = Engine.set_credential("app-password")
    assert :ok = Engine.sync_now()
    assert_receive {:connect_called, task_pid}
    assert Process.alive?(task_pid)

    # Tear the Engine down the way Workspace.Runtime does on a workspace
    # switch. Because the pass task is LINKED to the Engine, it must die with
    # it — a merely-monitored task blocked in connect would survive and later
    # write the OLD workspace's rows into the NEW one.
    ref = Process.monitor(task_pid)
    assert :ok = stop_supervised!(Valea.Mail.Engine)

    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1_000
    refute Process.alive?(task_pid)
  end

  test "a connect failure never leaks the credential into last_error or a log line", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")

    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.LeakyConnectTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 42)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 42}
    )

    secret = "hunter2-super-secret-XYZ"
    :ok = Engine.set_credential(secret)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    log =
      capture_log(fn ->
        assert :ok = Engine.sync_now()
        assert_receive {:mail_sync_finished, %{new_messages: 0, errors: [error]}}, 2_000
        refute error =~ secret
      end)

    refute log =~ secret
    status = Engine.status()
    assert status.last_error != nil
    refute status.last_error =~ secret
  end
end
