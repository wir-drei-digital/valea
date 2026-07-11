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

defmodule Valea.Mail.EngineTest do
  use ExUnit.Case, async: false

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
             account: nil
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
end
