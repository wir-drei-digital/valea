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
  def select(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}
  @impl true
  def examine(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}
  @impl true
  def uid_search(_conn, _criteria), do: {:ok, []}
  @impl true
  def uid_fetch_meta(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_headers(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_full(_conn, _uid), do: {:ok, ""}
  @impl true
  def uid_fetch_flags(_conn, _uid_set), do: {:ok, []}
  @impl true
  def uid_store_flags(_conn, _uid, _add, _remove, _opts \\ []), do: {:ok, :applied}
  @impl true
  def uid_move(_conn, _uid, _folder), do: {:ok, %{dest_uid: nil}}
  @impl true
  def uid_copy(_conn, _uid, _folder), do: {:ok, %{dest_uid: nil}}
  @impl true
  def uid_mark_deleted(_conn, _uid), do: :ok
  @impl true
  def uid_expunge(_conn, _uid), do: :ok
  @impl true
  def append(_conn, _folder, _flags, _rfc822), do: {:ok, %{dest_uid: nil}}
  @impl true
  def supports?(_conn, _capability), do: false
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
  def select(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}
  @impl true
  def examine(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}
  @impl true
  def uid_search(_conn, _criteria), do: {:ok, []}
  @impl true
  def uid_fetch_meta(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_headers(_conn, _uids), do: {:ok, []}
  @impl true
  def uid_fetch_full(_conn, _uid), do: {:ok, ""}
  @impl true
  def uid_fetch_flags(_conn, _uid_set), do: {:ok, []}
  @impl true
  def uid_store_flags(_conn, _uid, _add, _remove, _opts \\ []), do: {:ok, :applied}
  @impl true
  def uid_move(_conn, _uid, _folder), do: {:ok, %{dest_uid: nil}}
  @impl true
  def uid_copy(_conn, _uid, _folder), do: {:ok, %{dest_uid: nil}}
  @impl true
  def uid_mark_deleted(_conn, _uid), do: :ok
  @impl true
  def uid_expunge(_conn, _uid), do: :ok
  @impl true
  def append(_conn, _folder, _flags, _rfc822), do: {:ok, %{dest_uid: nil}}
  @impl true
  def supports?(_conn, _capability), do: false
  @impl true
  def logout(_conn), do: :ok
end

defmodule Valea.Mail.EngineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Valea.Mail.Account
  alias Valea.Mail.Engine
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Supervisor, as: MailSupervisor

  # `Index.rebuild/2` and `build_status/1` now do REAL Store/Repo work (no
  # more v3-bridge no-op) — every test needs a real, migrated Repo, exactly
  # like `index_test.exs`/`sync_pass_test.exs`.
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "vmail-engine-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    root = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(root, "config"))

    start_supervised!({Valea.Repo, database: Path.join(dir, "app.sqlite"), pool_size: 1})

    migrations_path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    previous_compiler_options = Code.compiler_options(ignore_module_conflict: true)
    Ecto.Migrator.run(Valea.Repo, migrations_path, :up, all: true)
    Code.compiler_options(previous_compiler_options)

    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root}
  end

  # -- fixtures ---------------------------------------------------------------

  defp settings(slug, overrides \\ %{}) do
    Map.merge(
      %Settings{
        slug: slug,
        provider: :generic,
        imap: %{host: "imap.fastmail.com", port: 993, username: "#{slug}@example.com"},
        folders: %{drafts: "Drafts", sent: "Sent", archive: "Archive", trash: "Trash"},
        sync: %{
          window_days: 90,
          interval_minutes: 15,
          max_message_bytes: 26_214_400,
          exclude_folders: []
        }
      },
      overrides
    )
  end

  defp start_engine!(root, generation, slug, opts \\ []) do
    cfg =
      %{root: root, generation: generation, account: slug}
      |> Map.put(:settings, Keyword.get(opts, :settings, settings(slug)))
      |> maybe_put(:activate, Keyword.get(opts, :activate))
      |> maybe_put(:connect_opts, Keyword.get(opts, :connect_opts))

    start_supervised!({Engine, cfg}, id: String.to_atom("engine_#{slug}"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp open(root, generation) do
    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, generation}
    )
  end

  # -- boot / generation gating -------------------------------------------------

  test "boots inert: state inactive, sync_now refuses", %{root: root} do
    start_engine!(root, 1, "mara")

    # `username`/`configured`/`backfill` are already known — settings are
    # handed in at start_link, not lazily re-read from `config/mail.yaml` at
    # activation like the old singleton Engine did — but `state` stays
    # "inactive" and nothing has been indexed yet until the matching
    # `workspace_opened` broadcast arrives.
    assert %{
             account: "mara",
             state: "inactive",
             configured: true,
             credential: "missing",
             last_sync_at: nil,
             last_error: nil,
             username: "mara@example.com",
             workspace_id: nil,
             pending_ops: 0,
             held_folders: [],
             backfill: %{},
             notices: []
           } = Engine.status("mara")

    assert Engine.sync_now("mara") == {:error, :inactive}
  end

  test "a mismatched-generation broadcast is ignored", %{root: root} do
    start_engine!(root, 2, "mara")
    open(root, 1)
    assert Engine.status("mara").state == "inactive"
  end

  test "activates only on its own generation's workspace_opened broadcast", %{root: root} do
    start_engine!(root, 3, "mara")
    open(root, 3)

    status = Engine.status("mara")
    assert status.state == "idle"
    assert status.configured == true
    assert status.account == "mara"
    assert status.username == "mara@example.com"

    # The configured special-folder names ride the status map (string keys —
    # the UI's archive action composes its move op from these).
    assert status.folders == %{
             "drafts" => "Drafts",
             "sent" => "Sent",
             "archive" => "Archive",
             "trash" => "Trash"
           }
  end

  test "reads the workspace id from config/workspace.yaml at activation", %{root: root} do
    File.write!(Path.join(root, "config/workspace.yaml"), "version: 3\nid: ws-abc-123\n")
    start_engine!(root, 30, "mara")
    open(root, 30)
    assert Engine.status("mara").workspace_id == "ws-abc-123"
  end

  test "workspace_id stays nil when config/workspace.yaml is absent", %{root: root} do
    start_engine!(root, 31, "mara")
    open(root, 31)
    assert Engine.status("mara").workspace_id == nil
  end

  test "an engine started with no settings at all activates but reports not_configured", %{
    root: root
  } do
    start_engine!(root, 5, "mara", settings: nil)
    open(root, 5)

    status = Engine.status("mara")
    assert status.configured == false
    assert status.state == "idle"
    assert Engine.sync_now("mara") == {:error, :not_configured}
  end

  # -- per-account isolation ---------------------------------------------------

  test "two accounts get two isolated engines: status, credential routing, statuses/0", %{
    root: root
  } do
    start_engine!(root, 40, "mara")

    start_engine!(root, 40, "priya",
      settings:
        settings("priya", %{
          imap: %{host: "imap.other.com", port: 993, username: "priya@example.com"}
        })
    )

    open(root, 40)

    mara = Engine.status("mara")
    priya = Engine.status("priya")
    assert mara.account == "mara"
    assert priya.account == "priya"
    assert mara.username == "mara@example.com"
    assert priya.username == "priya@example.com"

    assert :ok = Engine.set_credential("mara", "mara-secret")
    assert Engine.status("mara").credential == "present"
    assert Engine.status("priya").credential == "missing"

    all = Engine.statuses()
    assert Map.keys(all) |> Enum.sort() == ["mara", "priya"]
    assert all["mara"].credential == "present"
    assert all["priya"].credential == "missing"
  end

  test "status/1, set_credential/2, sync_now/1, readopt/1 all report not_found for an unknown slug" do
    assert Engine.status("ghost") == nil
    assert Engine.set_credential("ghost", "x") == {:error, :not_found}
    assert Engine.sync_now("ghost") == {:error, :not_found}
    assert Engine.readopt("ghost") == {:error, :not_found}
    assert Engine.doctor("ghost") == {:error, :not_found}
    assert Engine.create_folders("ghost") == {:error, :not_found}
  end

  # -- identity binding ---------------------------------------------------------

  test "activation claims an absent .account with this settings' identity", %{root: root} do
    start_engine!(root, 51, "mara")
    open(root, 51)

    assert Engine.status("mara").state == "idle"

    assert Account.verify(root, "mara", %{
             host: "imap.fastmail.com",
             username: "mara@example.com"
           }) == :ok
  end

  test "identity mismatch: a pre-written .account with a DIFFERENT identity blocks activation entirely",
       %{root: root} do
    :ok =
      Account.write_if_absent!(root, "mara", %{
        host: "imap.other.com",
        username: "someone-else@example.com"
      })

    original = File.read!(Account.account_path(root, "mara"))

    start_engine!(root, 52, "mara")
    open(root, 52)

    status = Engine.status("mara")
    assert status.state == "identity_mismatch"
    assert Engine.sync_now("mara") == {:error, :inactive}

    # No index rebuild ran (no sync_state rows for this account) and the
    # mismatched file was left untouched (never overwritten).
    assert Store.folders("mara") == []
    assert File.read!(Account.account_path(root, "mara")) == original
  end

  # -- credential / config gating ----------------------------------------------

  test "configured but no credential -> sync_now no_credential", %{root: root} do
    start_engine!(root, 6, "mara")
    open(root, 6)
    assert Engine.sync_now("mara") == {:error, :no_credential}
  end

  test "set_credential flips status and broadcasts :mail_status_changed", %{root: root} do
    start_engine!(root, 7, "mara")
    open(root, 7)

    assert Engine.status("mara").credential == "missing"

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    assert :ok = Engine.set_credential("mara", "hunter2-secret")

    assert_receive {:mail_status_changed, "mara", status}
    assert status.credential == "present"
    assert Engine.status("mara").credential == "present"
  end

  test "env fallback: VALEA_MAIL_PASSWORD_<SLUG> is picked up at activation when unset previously",
       %{root: root} do
    System.put_env("VALEA_MAIL_PASSWORD_MARA", "dev-fallback-secret")
    on_exit(fn -> System.delete_env("VALEA_MAIL_PASSWORD_MARA") end)

    start_engine!(root, 8, "mara")
    open(root, 8)

    assert Engine.status("mara").credential == "present"
  end

  test "no env fallback when VALEA_MAIL_PASSWORD_<SLUG> is unset", %{root: root} do
    System.delete_env("VALEA_MAIL_PASSWORD_MARA")
    start_engine!(root, 9, "mara")
    open(root, 9)
    assert Engine.status("mara").credential == "missing"
  end

  test "redaction: :sys.get_state never exposes the raw credential", %{root: root} do
    start_engine!(root, 10, "mara")
    open(root, 10)

    secret = "super-duper-secret-password-XYZ"
    :ok = Engine.set_credential("mara", secret)

    dump =
      Engine.via("mara")
      |> GenServer.whereis()
      |> :sys.get_state()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute dump =~ secret
  end

  # -- doctor / create_folders --------------------------------------------------

  test "doctor/1 on an inert (inactive) engine: config_present ok (settings known), credential_present fails",
       %{root: root} do
    start_engine!(root, 15, "mara")

    assert {:ok, %{ok: false, checks: checks}} = Engine.doctor("mara")
    by_id = Map.new(checks, &{&1["id"], &1})
    assert by_id["config_present"]["status"] == "ok"
    assert by_id["credential_present"]["status"] == "failed"
  end

  test "create_folders/1 refuses on an inert (inactive) engine", %{root: root} do
    start_engine!(root, 16, "mara")
    assert Engine.create_folders("mara") == {:error, :inactive}
  end

  test "create_folders/1 refuses when configured but not credentialed", %{root: root} do
    start_engine!(root, 17, "mara")
    open(root, 17)
    assert Engine.create_folders("mara") == {:error, :no_credential}
  end

  test "doctor/1 and create_folders/1 against a real, activated engine: full green + folder creation",
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

    start_engine!(root, 18, "mara",
      settings:
        settings("mara", %{imap: %{host: "localhost", port: port, username: "mara@example.com"}})
    )

    open(root, 18)
    :ok = Engine.set_credential("mara", "app-password")

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["Drafts", "Sent", "Archive", "Trash"]}},
      {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE"]}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{ok: true, checks: checks}} = Engine.doctor("mara")
    assert Enum.all?(checks, &(&1["status"] == "ok"))

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["Drafts"]}},
      {:create_folder, [:_, "Sent"], :ok},
      {:create_folder, [:_, "Archive"], :ok},
      {:create_folder, [:_, "Trash"], :ok},
      {:logout, :_, :ok}
    ])

    assert {:ok, created} = Engine.create_folders("mara")
    assert Enum.sort(created) == Enum.sort(["Sent", "Archive", "Trash"])
  end

  # -- poll timer / auth_failed -------------------------------------------------

  test "an unsolicited :poll (simulating the timer firing) keeps the engine alive and idle", %{
    root: root
  } do
    start_engine!(root, 12, "mara")
    open(root, 12)

    pid = GenServer.whereis(Engine.via("mara"))
    send(pid, :poll)

    assert Engine.status("mara").state == "idle"
    assert Process.alive?(pid)
  end

  test "auth_failed pauses polling; set_credential clears it and re-arms", %{root: root} do
    start_engine!(root, 13, "mara")
    open(root, 13)

    pid = GenServer.whereis(Engine.via("mara"))
    :sys.replace_state(pid, fn state -> %{state | status: "auth_failed"} end)

    send(pid, :poll)
    assert %{poll_timer: nil} = :sys.get_state(pid)
    assert Engine.status("mara").state == "auth_failed"

    assert :ok = Engine.set_credential("mara", "new-secret")
    state_after = :sys.get_state(pid)
    assert state_after.status == "idle"
    assert state_after.poll_timer != nil
    assert Engine.status("mara").state == "idle"
  end

  # -- single-flight sync ------------------------------------------------------

  test "sync_now runs a pass in the background: status 'syncing', single-flight, result flips state",
       %{root: root} do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 20, "mara")
    open(root, 20)

    :ok = Engine.set_credential("mara", "app-password")
    assert Engine.status("mara").state == "idle"

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, task_pid}
    assert Engine.status("mara").state == "syncing"

    assert :ok = Engine.sync_now("mara")
    refute_receive {:connect_called, _another}, 100

    send(task_pid, {:release, {:error, :auth_failed}})

    assert_receive {:mail_sync_finished, "mara",
                    %{new_messages: 0, errors: ["authentication failed"]}}

    assert Engine.status("mara").state == "auth_failed"

    assert %{poll_timer: nil, sync_task: nil} =
             :sys.get_state(GenServer.whereis(Engine.via("mara")))
  end

  test "a pass task killed mid-flight is a failed pass: status recovers, never stuck syncing",
       %{root: root} do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 21, "mara")
    open(root, 21)

    :ok = Engine.set_credential("mara", "app-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, task_pid}
    assert Engine.status("mara").state == "syncing"

    Process.exit(task_pid, :kill)

    assert_receive {:mail_sync_finished, "mara", %{new_messages: 0, errors: [error]}}
    assert error =~ "sync failed"
    assert Engine.status("mara").state == "idle"
    assert %{sync_task: nil} = :sys.get_state(GenServer.whereis(Engine.via("mara")))

    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, new_task_pid}
    send(new_task_pid, {:release, {:error, :test_done}})
    assert_receive {:mail_sync_finished, "mara", _payload}
    assert Engine.status("mara").state == "idle"
  end

  test "a sync task in flight is killed when the Engine stops (does not outlive it)", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 41, "mara")
    open(root, 41)

    :ok = Engine.set_credential("mara", "app-password")
    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, task_pid}
    assert Process.alive?(task_pid)

    ref = Process.monitor(task_pid)
    assert :ok = stop_supervised(:engine_mara)

    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 1_000
    refute Process.alive?(task_pid)
  end

  test "a connect failure never leaks the credential into last_error or a log line", %{root: root} do
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.LeakyConnectTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 42, "mara")
    open(root, 42)

    secret = "hunter2-super-secret-XYZ"
    :ok = Engine.set_credential("mara", secret)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    log =
      capture_log(fn ->
        assert :ok = Engine.sync_now("mara")
        assert_receive {:mail_sync_finished, "mara", %{new_messages: 0, errors: [error]}}, 2_000
        refute error =~ secret
      end)

    refute log =~ secret
    status = Engine.status("mara")
    assert status.last_error != nil
    refute status.last_error =~ secret
  end

  # -- RPC ops serialization (I1/I2) -------------------------------------------

  # apply_ops calls block their caller, so drive them from a throwaway process
  # that ships the reply back to the test via a message.
  defp apply_ops_async(slug, ops) do
    test_pid = self()
    spawn(fn -> send(test_pid, {:ops_reply, Engine.apply_ops(slug, ops)}) end)
  end

  @a_flag_op %{
    "op" => "flag",
    "msg_id" => "m",
    "folder" => "INBOX",
    "add" => ["S"],
    "remove" => []
  }

  test "apply_ops does not run concurrently with an in-flight sync pass: it queues, then runs after",
       %{root: root} do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 70, "mara")
    open(root, 70)
    :ok = Engine.set_credential("mara", "app-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    # A sync pass is running (hung in its Task at connect).
    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, pass_pid}
    assert Engine.status("mara").state == "syncing"

    # apply_ops arrives mid-pass. It MUST NOT open a second connection (i.e.
    # start executing against the same mailbox/ledger) while the pass runs.
    apply_ops_async("mara", [@a_flag_op])
    refute_receive {:connect_called, _concurrent}, 200

    # Release the pass; only THEN does the queued ops task connect + run.
    send(pass_pid, {:release, {:error, :test_done}})
    assert_receive {:mail_sync_finished, "mara", _}, 2_000
    assert_receive {:connect_called, ops_pid}, 2_000

    send(ops_pid, {:release, {:ok, ops_pid}})
    assert_receive {:ops_reply, {:ok, results}}, 2_000
    assert [%{"op" => 0, "result" => _}] = results

    assert %{sync_task: nil, ops_current: nil} =
             :sys.get_state(GenServer.whereis(Engine.via("mara")))
  end

  test "a poll tick / sync_now arriving while an ops task runs never starts a concurrent pass", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 72, "mara")
    open(root, 72)
    :ok = Engine.set_credential("mara", "app-password")

    # An ops task is in flight (hung at connect).
    apply_ops_async("mara", [@a_flag_op])
    assert_receive {:connect_called, ops_pid}, 2_000

    pid = GenServer.whereis(Engine.via("mara"))

    # sync_now + a poll tick while the ops task runs: no second connect starts.
    assert :ok = Engine.sync_now("mara")
    send(pid, :poll)
    refute_receive {:connect_called, _concurrent}, 200

    send(ops_pid, {:release, {:ok, ops_pid}})
    assert_receive {:ops_reply, {:ok, _results}}, 2_000
  end

  test "status/1 answers instantly while an ops task is executing (never freezes behind it)", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 71, "mara")
    open(root, 71)
    :ok = Engine.set_credential("mara", "app-password")

    # An ops task is in flight (hung at connect) — the Engine's own loop must
    # stay free to answer status.
    apply_ops_async("mara", [@a_flag_op])
    assert_receive {:connect_called, ops_pid}, 2_000

    status = Engine.status("mara")
    assert status != nil
    assert status.account == "mara"

    send(ops_pid, {:release, {:ok, ops_pid}})
    assert_receive {:ops_reply, {:ok, _results}}, 2_000
  end

  # -- mailbox_replaced stickiness + readopt -----------------------------------

  @raw_a "From: A <a@example.com>\r\nSubject: Hi\r\nDate: Wed, 15 Jul 2026 09:00:00 +0000\r\nMessage-ID: <a@example.com>\r\n\r\nBody\r\n"

  test "mailbox_replaced: an INBOX reset blocks sync_now; readopt authorizes exactly one pass; a forced second replacement re-blocks",
       %{root: root} do
    slug = "mara"
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", @raw_a)

    Application.put_env(:valea, :mail_transport, ModelMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 60, slug, connect_opts: [name: name])
    open(root, 60)

    :ok = Engine.set_credential(slug, "app-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    # Baseline pass: no reset yet, ordinary success.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:mail_sync_finished, ^slug, %{errors: []}}, 2_000
    assert Engine.status(slug).state == "idle"

    # Whole-mailbox replacement: INBOX's UIDVALIDITY changes.
    ModelMailTransport.reset_uidvalidity(name, "INBOX")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:mail_sync_finished, ^slug, _}, 2_000
    assert Engine.status(slug).state == "mailbox_replaced"
    assert Engine.sync_now(slug) == {:error, :blocked}
    refute Account.readopt_authorized?(root, slug)

    # readopt/1: writes the marker, unblocks, re-arms polling.
    assert :ok = Engine.readopt(slug)
    assert Engine.status(slug).state == "idle"
    assert Account.readopt_authorized?(root, slug)

    # The NEXT pass reconciles (readopt_authorized skips detect_replacement)
    # and clears the marker on success.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:mail_sync_finished, ^slug, _}, 2_000
    assert Engine.status(slug).state == "idle"
    refute Account.readopt_authorized?(root, slug)

    # A forced SECOND replacement re-blocks normally — the marker is gone.
    ModelMailTransport.reset_uidvalidity(name, "INBOX")
    assert :ok = Engine.sync_now(slug)
    assert_receive {:mail_sync_finished, ^slug, _}, 2_000
    assert Engine.status(slug).state == "mailbox_replaced"
  end

  test "readopt/1 refuses (:not_blocked) when the engine isn't stuck on mailbox_replaced", %{
    root: root
  } do
    start_engine!(root, 61, "mara")
    open(root, 61)
    assert Engine.readopt("mara") == {:error, :not_blocked}
  end

  # -- supervisor rehash --------------------------------------------------------

  test "Valea.Mail.Supervisor.reload_settings_all/1 starts a fresh engine for a newly-valid account while leaving an already-running one (and its credential) untouched",
       %{root: root} do
    :ok =
      Settings.upsert_account!(root, "mara", %{
        host: "imap.fastmail.com",
        port: 993,
        username: "mara@example.com"
      })

    start_supervised!({MailSupervisor, %{root: root, generation: 1}})
    open(root, 1)

    assert Engine.status("mara") != nil
    assert Engine.status("priya") == nil

    :ok = Engine.set_credential("mara", "mara-secret")

    :ok =
      Settings.upsert_account!(root, "priya", %{
        host: "imap.other.com",
        port: 993,
        username: "priya@example.com"
      })

    assert :ok = MailSupervisor.reload_settings_all(root)

    # "mara" untouched: still credentialed (a restart would have wiped it).
    assert Engine.status("mara").credential == "present"

    # "priya" exists now, and self-activated immediately (no workspace_opened
    # broadcast is coming for it mid-session).
    priya = Engine.status("priya")
    assert priya != nil
    assert priya.state == "idle"
    assert priya.account == "priya"
  end

  test "Valea.Mail.Supervisor.reload_settings_all/1 stops the engine for a removed account", %{
    root: root
  } do
    :ok =
      Settings.upsert_account!(root, "mara", %{
        host: "imap.fastmail.com",
        port: 993,
        username: "mara@example.com"
      })

    start_supervised!({MailSupervisor, %{root: root, generation: 1}})
    open(root, 1)
    assert Engine.status("mara") != nil

    :ok = Settings.remove_account!(root, "mara")
    assert :ok = MailSupervisor.reload_settings_all(root)

    assert Engine.status("mara") == nil
  end

  test "Valea.Mail.Supervisor boots with NO engine for an invalid account entry", %{root: root} do
    File.write!(Path.join(root, "config/mail.yaml"), """
    version: 4
    accounts:
      mara:
        provider: generic
        imap:
          host: ""
          username: "mara@example.com"
    safety:
      never_expunge: true
      outbound: push_drafts_only
    """)

    start_supervised!({MailSupervisor, %{root: root, generation: 1}})
    assert Engine.status("mara") == nil
  end

  test "Valea.Mail.Supervisor.reload_settings_all/1 restarts an engine whose settings changed",
       %{root: root} do
    :ok =
      Settings.upsert_account!(root, "mara", %{
        host: "imap.fastmail.com",
        port: 993,
        username: "mara@example.com"
      })

    start_supervised!({MailSupervisor, %{root: root, generation: 1}})
    open(root, 1)
    :ok = Engine.set_credential("mara", "mara-secret")
    assert Engine.status("mara").credential == "present"

    :ok =
      Settings.upsert_account!(root, "mara", %{
        host: "imap.fastmail.com",
        port: 994,
        username: "mara@example.com"
      })

    assert :ok = MailSupervisor.reload_settings_all(root)

    # Restarted with fresh settings: the in-RAM credential from before the
    # restart is gone, and it self-activated immediately (mid-session).
    status = Engine.status("mara")
    assert status != nil
    assert status.credential == "missing"
    assert status.state == "idle"
  end

  # -- Push-to-Drafts serialization (Task 15) ----------------------------------

  defp write_draft!(root, slug, name, body) do
    dir = Path.join([root, "sources", "mail", slug, "drafts"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
    body
  end

  @draft_md """
  ---
  to: [alex@example.com]
  subject: "Re: Kickoff"
  status: draft
  ---
  Hello Alex.
  """

  test "push_draft claims+spools+APPENDs end-to-end and returns pushed", %{root: root} do
    slug = "mara"
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "Drafts")

    Application.put_env(:valea, :mail_transport, ModelMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 80, slug, connect_opts: [name: name])
    open(root, 80)
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)
    hash = Valea.Mail.DraftFile.content_hash(@draft_md)

    assert {:ok, "pushed"} = Engine.push_draft(slug, "reply.md", hash)
    assert [msg] = ModelMailTransport.messages(name, "Drafts")
    assert msg.raw =~ "Message-ID: <valea.push."
  end

  # Important #1 (fix wave): a raise in the local prepare phase (disk full,
  # `database is locked`) must NEVER fell the Engine — a supervisor restart
  # would erase the RAM-only credential closure and silently stop syncing.
  test "a prepare_push crash (unwritable spool) rejects cleanly; Engine survives with its credential",
       %{root: root} do
    slug = "mara"
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "Drafts")

    Application.put_env(:valea, :mail_transport, ModelMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 82, slug, connect_opts: [name: name])
    open(root, 82)
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)
    hash = Valea.Mail.DraftFile.content_hash(@draft_md)

    # Sabotage: `spool` exists as a regular FILE, so the fsynced spool write
    # raises inside the local prepare phase.
    spool = Path.join([root, "sources", "mail", slug, "spool"])
    File.write!(spool, "not a directory")

    pid_before = GenServer.whereis(Engine.via(slug))
    assert {:error, "push_failed"} = Engine.push_draft(slug, "reply.md", hash)

    # Engine alive (same pid — no supervisor restart), credential intact,
    # status still answering.
    assert GenServer.whereis(Engine.via(slug)) == pid_before
    status = Engine.status(slug)
    assert status.state == "idle"
    assert status.credential == "present"

    # The claimed op was terminated rejected — nothing blocks a retry.
    assert [%{state: "rejected"}] = Store.ops_by_origin(slug, "drafts/reply.md")

    # Retry after fixing the spool: the full push succeeds.
    File.rm!(spool)
    assert {:ok, "pushed"} = Engine.push_draft(slug, "reply.md", hash)
    assert [_msg] = ModelMailTransport.messages(name, "Drafts")
  end

  test "push_draft rides the serialized work slot: no second connection while a pass runs", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    slug = "mara"
    start_engine!(root, 81, slug)
    open(root, 81)
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)
    hash = Valea.Mail.DraftFile.content_hash(@draft_md)

    # A sync pass is hung at connect.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}

    # push_draft arrives mid-pass: the LOCAL claim/spool runs, but the APPEND
    # must NOT open a second connection while the pass holds the slot.
    test_pid = self()
    spawn(fn -> send(test_pid, {:push_reply, Engine.push_draft(slug, "reply.md", hash)}) end)
    refute_receive {:connect_called, _concurrent}, 200

    # Release the pass; only THEN does the queued push connect + APPEND.
    send(pass_pid, {:release, {:error, :done}})
    assert_receive {:connect_called, push_pid}, 2_000
    send(push_pid, {:release, {:ok, push_pid}})
    assert_receive {:push_reply, {:ok, "pushed"}}, 2_000
  end
end
