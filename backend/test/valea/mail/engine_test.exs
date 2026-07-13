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

  test "retry_ops/1 refuses on an inert (inactive) engine", %{root: root} do
    start_engine!(root, 11)
    assert Engine.retry_ops("some-run-id") == {:error, :inactive}
  end

  test "retry_ops/1 refuses when configured but not credentialed", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 14)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 14}
    )

    assert Engine.retry_ops("some-run-id") == {:error, :no_credential}
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
    # full-green run.
    mount_dir = Path.join([root, "mounts", "starter"])
    File.mkdir_p!(Path.join(mount_dir, "Workflows"))

    Valea.Mounts.Manifest.write!(mount_dir, %{
      id: "73de3db8-81d1-40ae-afc2-daa2424cc5e7",
      name: "Starter",
      description: ""
    })

    File.write!(
      Path.join([mount_dir, "Workflows", "New Inquiry Triage.md"]),
      "---\nenabled: true\n---\n# New Inquiry Triage\n\nInputs: a `sources/mail/messages/*.md` file.\n"
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

# A `Transport` double for the single-flight tests: `connect/3` announces the
# ops task's pid to a probe and blocks until released — so a test can prove a
# second trigger for the same run_id is a no-op WHILE an execution is
# genuinely in flight. Everything after connect delegates to the shared
# `FakeMailTransport` (release with `{:ok, FakeMailTransport}` so the conn
# routes to its script/call log).
defmodule Valea.Mail.EngineMailboxOpsTest.OpsHangingTransport do
  @behaviour Valea.Mail.Transport

  @impl true
  def connect(_config, _credential, _opts) do
    send(Application.get_env(:valea, :ops_probe), {:ops_connect, self()})

    receive do
      {:release, result} -> result
    end
  end

  @impl true
  defdelegate capabilities(conn), to: FakeMailTransport
  @impl true
  defdelegate list_folders(conn), to: FakeMailTransport
  @impl true
  defdelegate create_folder(conn, folder), to: FakeMailTransport
  @impl true
  defdelegate select(conn, folder), to: FakeMailTransport
  @impl true
  defdelegate uid_search(conn, criteria), to: FakeMailTransport
  @impl true
  defdelegate uid_fetch_meta(conn, uids), to: FakeMailTransport
  @impl true
  defdelegate uid_fetch_headers(conn, uids), to: FakeMailTransport
  @impl true
  defdelegate uid_fetch_full(conn, uid), to: FakeMailTransport
  @impl true
  defdelegate uid_move(conn, uid, folder), to: FakeMailTransport
  @impl true
  defdelegate append(conn, folder, flags, rfc822), to: FakeMailTransport
  @impl true
  defdelegate logout(conn), to: FakeMailTransport
end

# The mailbox-ops recovery + retry paths need the REAL Engine (started by the
# workspace Runtime) so `Valea.Queue`/`Valea.Mail.Store` resolve against an
# actually-open workspace — hence a separate module with its own setup that
# opens one via `AgentCase` rather than the raw-tmp-root `EngineTest` above.
defmodule Valea.Mail.EngineMailboxOpsTest do
  use ExUnit.Case, async: false

  alias Valea.AgentCase
  alias Valea.Mail.Engine
  alias Valea.Mail.Message
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings
  alias Valea.Queue

  setup do
    # The Runtime Engine reads this at init, so it must be set before the
    # workspace opens.
    Application.put_env(:valea, :mail_transport, FakeMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    {:ok, _} = FakeMailTransport.start_link()

    ws = AgentCase.open_workspace!()

    Settings.write!(ws.path, %{
      account: "mara@example.com",
      host: "imap.fastmail.com",
      port: 993,
      username: "mara@example.com"
    })

    %{root: ws.path}
  end

  # Re-fire the Engine's own generation's workspace_opened so it re-activates
  # against the now-real mail.yaml, running the activation recovery scan.
  defp reactivate(root) do
    gen = :sys.get_state(Engine).generation

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "W"}, gen}
    )
  end

  defp write_source_message(root, suffix, uid) do
    msg_id = "2026-07-09-priya-#{suffix}"
    rel = Path.join(["sources", "mail", "messages", "#{msg_id}.md"])
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))

    message = %Message{
      message_id: "<orig-#{suffix}@mail.example.com>",
      from: %{name: "Priya Nair", email: "priya@example.com"},
      subject: "Inquiry",
      date: ~U[2026-07-09 10:00:00Z],
      body_text: "Original.\n"
    }

    bytes =
      MessageFile.render(message, %{
        msg_id: msg_id,
        uid: uid,
        status: "review",
        source: "imap",
        attachments: []
      })

    File.write!(abs, bytes)
    %{rel: rel, abs: abs}
  end

  defp write_draft(root, run_id) do
    abs = Path.join([root, "sources", "mail", "drafts", "#{run_id}.md"])
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "---\nto: priya@example.com\nsubject: Re: Inquiry\n---\n\nHello Priya,\n")
  end

  defp plant_envelope(root, run_id, dir, ops, source_rel) do
    envelope = %{
      "schema" => "queue_item/v2",
      "run_id" => run_id,
      "workflow" => "icm/Workflows/New Inquiry Triage.md",
      "risk_level" => "medium",
      "created_at" => "2026-07-10T00:00:00Z",
      "source_message" => source_rel,
      "payload" => %{
        "schema" => "proposal/v1",
        "kind" => "email_draft",
        "title" => "Reply",
        "summary" => "Reply to Priya",
        "sources" => ["icm/Clients/Priya Nair.md"],
        "proposed_action" => %{
          "type" => "create_email_draft",
          "to" => "priya@example.com",
          "subject" => "Re: Inquiry",
          "body_markdown" => "Hi\n"
        }
      },
      "mailbox_ops" => ops
    }

    path = Path.join([root, "queue", dir, "#{run_id}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(envelope))
  end

  defp decided_ops(run_id) do
    {:ok, %{item: item}} = Queue.get_decided(run_id)
    item["mailbox_ops"]
  end

  test "the activation recovery scan runs a hand-planted approved envelope's pending ops", %{
    root: root
  } do
    id = "20260710T000000Z-recover1"
    source = write_source_message(root, "recover1", 71)
    write_draft(root, id)

    plant_envelope(
      root,
      id,
      "approved",
      %{"draft_append" => %{"status" => "pending"}, "archive_source" => %{"status" => "pending"}},
      source.rel
    )

    :ok = Engine.set_credential("app-password")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, "Drafts"], {:ok, %{uidvalidity: 1, uidnext: 10}}},
      {:uid_search, :_, {:ok, []}},
      {:append, :_, :ok},
      {:select, [:_, "AI/Review"], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    reactivate(root)

    # both ops report their outcome (draft_append, then archive_source)
    assert_receive {:mailbox_ops_updated, ^id}, 2000
    assert_receive {:mailbox_ops_updated, ^id}, 2000

    ops = decided_ops(id)
    assert ops["draft_append"]["status"] == "done"
    assert ops["archive_source"]["status"] == "done"
  end

  test "activation survives a message file with no frontmatter id (index never crashes the Engine)",
       %{root: root} do
    # A frontmatter-but-no-id message file makes Index.rebuild's Store create
    # raise (msg_id is required). Before the fix that raise escaped rebuild/1
    # and crashed Engine.activate on workspace_opened — the Engine restarted
    # inert and never re-activated. It must now survive as a skipped file.
    bad = Path.join([root, "sources", "mail", "messages", "no-id.md"])
    File.mkdir_p!(Path.dirname(bad))

    File.write!(
      bad,
      "---\nmessage_id: \"<x@example.com>\"\nsubject: \"no id\"\nstatus: review\nsource: imap\n---\n\nBody.\n"
    )

    :ok = Engine.set_credential("app-password")
    reactivate(root)

    # The synchronous status call is processed after the (async) activation
    # message, so a crashed-and-restarted-inert Engine would read "inactive".
    assert Engine.status().state == "idle"
    assert Process.alive?(Process.whereis(Engine))
  end

  test "the recovery scan leaves a failed op alone (it waits for retry)", %{root: root} do
    id = "20260710T000000Z-failwait"
    source = write_source_message(root, "failwait", 72)

    plant_envelope(
      root,
      id,
      "rejected",
      %{"archive_source" => %{"status" => "failed", "error" => "prior timeout"}},
      source.rel
    )

    :ok = Engine.set_credential("app-password")
    # No script: if the scan wrongly touched the failed op, connect would raise.
    reactivate(root)

    # give the (correctly inert) scan a chance to have NOT run anything
    Process.sleep(50)
    assert FakeMailTransport.calls() == []
    assert decided_ops(id)["archive_source"]["status"] == "failed"
  end

  test "retry_ops/1 re-runs a failed op to done", %{root: root} do
    id = "20260710T000000Z-retry1"
    source = write_source_message(root, "retry1", 73)

    :ok = Engine.set_credential("app-password")
    reactivate(root)
    # active + configured + credentialed now; plant AFTER the scan so only the
    # explicit retry drives it.
    plant_envelope(
      root,
      id,
      "rejected",
      %{"archive_source" => %{"status" => "failed", "error" => "prior timeout"}},
      source.rel
    )

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:select, [:_, "AI/Review"], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")
    assert :ok = Engine.retry_ops(id)

    assert_receive {:mailbox_ops_updated, ^id}, 2000
    assert decided_ops(id)["archive_source"]["status"] == "done"
    assert File.read!(source.abs) =~ "status: processed"
  end

  # Swaps the active Engine's transport for the hanging double and points its
  # probe at the test process. Returns :ok; used by the single-flight tests.
  defp install_hanging_transport! do
    Application.put_env(:valea, :ops_probe, self())
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:valea, :ops_probe) end)

    :sys.replace_state(Process.whereis(Engine), fn state ->
      %{state | transport: Valea.Mail.EngineMailboxOpsTest.OpsHangingTransport}
    end)

    :ok
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  test "single-flight per run_id: a second trigger while ops are in flight is a no-op (one APPEND)",
       %{root: root} do
    id = "20260710T000000Z-flight1"
    source = write_source_message(root, "flight1", 74)
    write_draft(root, id)

    :ok = Engine.set_credential("app-password")
    # activate BEFORE planting so the recovery scan has nothing to pick up —
    # only the explicit triggers below drive the ops. The broadcast is async,
    # so synchronize on a call before planting.
    reactivate(root)
    assert Engine.status().state == "idle"

    plant_envelope(
      root,
      id,
      "approved",
      %{"draft_append" => %{"status" => "pending"}, "archive_source" => %{"status" => "pending"}},
      source.rel
    )

    install_hanging_transport!()

    FakeMailTransport.script([
      {:select, [:_, "Drafts"], {:ok, %{uidvalidity: 1, uidnext: 10}}},
      {:uid_search, :_, {:ok, []}},
      {:append, :_, :ok},
      {:select, [:_, "AI/Review"], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")

    # first trigger: hangs at connect, holding the run_id in flight
    assert :ok = Engine.retry_ops(id)
    assert_receive {:ops_connect, task_pid}

    # second trigger while in flight — retry RPC and the approve-broadcast
    # path both no-op: no second connect
    assert :ok = Engine.retry_ops(id)
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail_ops", {:mailbox_ops_pending, id})
    refute_receive {:ops_connect, _another}, 150

    # release: the ONE execution completes both ops against the fake
    send(task_pid, {:release, {:ok, FakeMailTransport}})
    assert_receive {:mailbox_ops_updated, ^id}, 2000
    assert_receive {:mailbox_ops_updated, ^id}, 2000

    ops = decided_ops(id)
    assert ops["draft_append"]["status"] == "done"
    assert ops["archive_source"]["status"] == "done"

    # exactly ONE append reached the transport
    appends = for {:append, args} <- FakeMailTransport.calls(), do: args
    assert length(appends) == 1

    # and the in-flight slot clears once the task exits
    wait_until(fn -> :sys.get_state(Process.whereis(Engine)).ops_tasks == %{} end)
  end

  test "a killed ops task clears the single-flight slot so a later retry runs", %{root: root} do
    id = "20260710T000000Z-flight2"
    source = write_source_message(root, "flight2", 75)

    :ok = Engine.set_credential("app-password")
    reactivate(root)
    # synchronize with the async activation before planting a pending op —
    # the recovery scan must not race the plant.
    assert Engine.status().state == "idle"

    plant_envelope(
      root,
      id,
      "rejected",
      %{"archive_source" => %{"status" => "pending"}},
      source.rel
    )

    install_hanging_transport!()

    assert :ok = Engine.retry_ops(id)
    assert_receive {:ops_connect, first_pid}

    # kill the in-flight task — the :DOWN must free the run_id's slot
    Process.exit(first_pid, :kill)
    wait_until(fn -> :sys.get_state(Process.whereis(Engine)).ops_tasks == %{} end)

    FakeMailTransport.script([
      {:select, [:_, "AI/Review"], {:ok, %{uidvalidity: 1, uidnext: 50}}},
      {:uid_move, :_, :ok},
      {:logout, :_, :ok}
    ])

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")

    # a later retry spawns a fresh execution (guard cleared) and completes
    assert :ok = Engine.retry_ops(id)
    assert_receive {:ops_connect, second_pid}
    send(second_pid, {:release, {:ok, FakeMailTransport}})

    assert_receive {:mailbox_ops_updated, ^id}, 2000
    assert decided_ops(id)["archive_source"]["status"] == "done"
  end
end
