defmodule ValeaWeb.MailRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Index
  alias Valea.Mail.Message
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Store
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    # The Runtime's Mail.Engine reads this at init, so it must be set before
    # the workspace opens — see `Valea.Mail.EngineMailboxOpsTest`'s setup.
    Application.put_env(:valea, :mail_transport, FakeMailTransport)
    {:ok, _} = FakeMailTransport.start_link()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
      Application.delete_env(:valea, :mail_transport)
    end)

    parent = Path.join(dir, "workspaces")
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: Path.join(parent, "W"), generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  # -- fixtures ---------------------------------------------------------------

  defp setup_account!(generation, opts \\ []) do
    assert %{"success" => true} =
             rpc(
               "setup_mail_account",
               %{
                 "account" => "mara@example.com",
                 "host" => Keyword.get(opts, :host, "imap.fastmail.com"),
                 "port" => Keyword.get(opts, :port, 993),
                 "username" => "mara@example.com",
                 "generation" => generation
               },
               ["saved"]
             )

    :ok
  end

  defp set_credential!(generation, secret \\ "app-password") do
    assert %{"success" => true} =
             rpc(
               "set_mail_credential",
               %{"secret" => secret, "generation" => generation},
               ["accepted"]
             )

    :ok
  end

  defp plant_message(root, suffix, uid) do
    msg_id = "2026-07-09-priya-#{suffix}"
    rel = Path.join(["sources", "mail", "messages", "#{msg_id}.md"])
    abs = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(abs))

    message = %Message{
      message_id: "<orig-#{suffix}@mail.example.com>",
      from: %{name: "Priya Nair", email: "priya@example.com"},
      subject: "Inquiry",
      date: ~U[2026-07-09 10:00:00Z],
      body_text: "Original inquiry body.\n"
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
    {:ok, _count} = Index.rebuild(root)
    %{msg_id: msg_id, rel: rel, abs: abs}
  end

  defp plant_decided_envelope(root, run_id, dir, ops, source_rel) do
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

  # -- mail_status --------------------------------------------------------------

  describe "mail_status" do
    test "raw status map reflects a freshly opened, not-yet-configured workspace" do
      assert %{"success" => true, "data" => %{"status" => status}} =
               rpc("mail_status", %{}, ["status"])

      assert status["state"] == "idle"
      assert status["configured"] == false
      assert status["credential"] == "missing"
      assert status["account"] == nil
      assert status["username"] == nil
      assert is_binary(status["workspace_id"])
    end
  end

  # -- setup_mail_account ---------------------------------------------------------

  describe "setup_mail_account" do
    test "happy path writes config/mail.yaml and flips mail_status to configured", %{
      workspace: workspace,
      generation: generation
    } do
      # account (display label) deliberately differs from username (the IMAP
      # login) — status must surface BOTH, since the frontend's keychain
      # lookup keys on the username (spec §Credentials).
      assert %{"success" => true, "data" => %{"saved" => true}} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "Mara's mail",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert File.exists?(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => true, "data" => %{"status" => status}} =
               rpc("mail_status", %{}, ["status"])

      assert status["configured"] == true
      assert status["account"] == "Mara's mail"
      assert status["username"] == "mara@example.com"
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      # Every scaffolded workspace ships config/mail.yaml with a placeholder
      # host already — a rejected setup must leave those bytes untouched.
      before = File.read!(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara@example.com",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "generation" => generation - 1
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "workspace_changed"
      assert File.read!(Path.join(workspace, "config/mail.yaml")) == before
    end
  end

  # -- set_mail_credential --------------------------------------------------------

  describe "set_mail_credential" do
    test "happy path accepts the credential and never echoes it back in the response", %{
      generation: generation
    } do
      secret = "hunter2-super-secret-password"

      response =
        rpc("set_mail_credential", %{"secret" => secret, "generation" => generation}, [
          "accepted"
        ])

      assert %{"success" => true, "data" => %{"accepted" => true}} = response
      refute inspect(response) =~ secret

      assert %{"success" => true, "data" => %{"status" => status}} =
               rpc("mail_status", %{}, ["status"])

      assert status["credential"] == "present"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mail_credential",
                 %{"secret" => "x", "generation" => generation - 1},
                 ["accepted"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- mail_sync_now --------------------------------------------------------------

  describe "mail_sync_now" do
    test "happy path returns started: true", %{generation: generation} do
      setup_account!(generation)
      set_credential!(generation)

      FakeMailTransport.script([{:connect, :_, {:error, :test_stop}}])

      assert %{"success" => true, "data" => %{"started" => true}} =
               rpc("mail_sync_now", %{"generation" => generation}, ["started"])
    end

    test "not yet configured surfaces not_configured", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_sync_now", %{"generation" => generation}, ["started"])

      assert inspect(errors) =~ "not_configured"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_sync_now", %{"generation" => generation - 1}, ["started"])

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- mail_doctor --------------------------------------------------------------

  describe "mail_doctor" do
    test "happy path returns checks and an overall ok flag", %{generation: generation} do
      assert %{"success" => true, "data" => %{"ok" => ok, "checks" => checks}} =
               rpc("mail_doctor", %{"generation" => generation}, ["ok", "checks"])

      assert is_boolean(ok)
      assert is_list(checks)
      assert Enum.any?(checks, &(&1["id"] == "config_present"))
      assert ok == false
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_doctor", %{"generation" => generation - 1}, ["ok", "checks"])

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- create_mail_folders --------------------------------------------------------

  describe "create_mail_folders" do
    test "happy path connects and creates the missing AI folders", %{generation: generation} do
      setup_account!(generation)
      set_credential!(generation)

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, ["Drafts"]}},
        {:create_folder, [:_, "AI/Review"], :ok},
        {:create_folder, [:_, "AI/Processed"], :ok},
        {:logout, :_, :ok}
      ])

      assert %{"success" => true, "data" => %{"created" => created}} =
               rpc("create_mail_folders", %{"generation" => generation}, ["created"])

      assert Enum.sort(created) == Enum.sort(["AI/Review", "AI/Processed"])
    end

    test "no credential surfaces no_credential", %{generation: generation} do
      setup_account!(generation)

      assert %{"success" => false, "errors" => errors} =
               rpc("create_mail_folders", %{"generation" => generation}, ["created"])

      assert inspect(errors) =~ "no_credential"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("create_mail_folders", %{"generation" => generation - 1}, ["created"])

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- list_mail_messages --------------------------------------------------------

  @messages_fields [
    %{
      "messages" => [
        "msgId",
        "fromName",
        "fromEmail",
        "subject",
        "date",
        "status",
        "hasAttachments",
        "uid",
        "path"
      ]
    }
  ]

  describe "list_mail_messages" do
    test "happy path lists an indexed message", %{workspace: workspace} do
      plant = plant_message(workspace, "seed1", 42)

      assert %{"success" => true, "data" => %{"messages" => messages}} =
               rpc("list_mail_messages", %{}, @messages_fields)

      assert msg = Enum.find(messages, &(&1["msgId"] == plant.msg_id))
      assert msg["fromEmail"] == "priya@example.com"
      assert msg["fromName"] == "Priya Nair"
      assert msg["hasAttachments"] == false
      assert msg["uid"] == 42
      assert msg["path"] == plant.rel
    end

    test "includes the workspace template's seed message by default" do
      # A synchronous round-trip through the Engine (any RPC action that
      # calls it) guarantees its earlier `workspace_opened` activation —
      # which indexes every `sources/mail/messages/*.md` file, including the
      # template's seed message — has already been processed: Engine's
      # mailbox is FIFO, so this call cannot be handled before that earlier
      # broadcast is.
      assert %{"success" => true} = rpc("mail_status", %{}, ["status"])

      assert %{"success" => true, "data" => %{"messages" => messages}} =
               rpc("list_mail_messages", %{}, @messages_fields)

      assert Enum.any?(messages, &(&1["msgId"] == "2026-07-09-priya-nair-seed0001"))
    end
  end

  # -- get_mail_message --------------------------------------------------------

  describe "get_mail_message" do
    test "happy path reads the file: frontmatter + body + path, and inbox:false", %{
      workspace: workspace
    } do
      plant = plant_message(workspace, "seed2", 43)

      assert %{"success" => true, "data" => %{"message" => message, "inbox" => false}} =
               rpc("get_mail_message", %{"msgId" => plant.msg_id}, ["message", "inbox"])

      assert message["path"] == plant.rel
      assert message["frontmatter"]["id"] == plant.msg_id
      assert message["body"] =~ "Original inquiry body."
    end

    test "an unknown msg_id surfaces not_found" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_message", %{"msgId" => "does-not-exist"}, ["message", "inbox"])

      assert inspect(errors) =~ "not_found"
    end
  end

  # -- mail_inbox --------------------------------------------------------------

  @entries_fields [%{"entries" => ["uid", "fromText", "subject", "date"]}]

  describe "mail_inbox" do
    test "happy path lists inbox header entries" do
      Store.put_inbox_header(%{
        uid: 99,
        from_text: "Priya <priya@example.com>",
        subject: "Hi",
        date: "2026-07-09T10:00:00Z"
      })

      assert %{"success" => true, "data" => %{"entries" => entries}} =
               rpc("mail_inbox", %{}, @entries_fields)

      assert entry = Enum.find(entries, &(&1["uid"] == 99))
      assert entry["fromText"] == "Priya <priya@example.com>"
      assert entry["subject"] == "Hi"
    end

    test "returns an empty list when nothing has synced yet" do
      assert %{"success" => true, "data" => %{"entries" => []}} =
               rpc("mail_inbox", %{}, @entries_fields)
    end
  end

  # -- retry_mailbox_ops --------------------------------------------------------

  describe "retry_mailbox_ops" do
    test "happy path re-runs a failed op to done", %{workspace: workspace, generation: generation} do
      setup_account!(generation)
      set_credential!(generation)

      plant = plant_message(workspace, "retry1", 74)
      run_id = "20260710T000000Z-retry1"

      plant_decided_envelope(
        workspace,
        run_id,
        "rejected",
        %{"archive_source" => %{"status" => "failed", "error" => "prior timeout"}},
        plant.rel
      )

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:select, [:_, "AI/Review"], {:ok, %{uidvalidity: 1, uidnext: 50}}},
        {:uid_move, :_, :ok},
        {:logout, :_, :ok}
      ])

      Phoenix.PubSub.subscribe(Valea.PubSub, "mail_ops")

      assert %{"success" => true, "data" => %{"accepted" => true}} =
               rpc(
                 "retry_mailbox_ops",
                 %{"runId" => run_id, "generation" => generation},
                 ["accepted"]
               )

      assert_receive {:mailbox_ops_updated, ^run_id}, 2000
    end

    test "no credential surfaces no_credential", %{generation: generation} do
      setup_account!(generation)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "retry_mailbox_ops",
                 %{"runId" => "whatever", "generation" => generation},
                 ["accepted"]
               )

      assert inspect(errors) =~ "no_credential"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "retry_mailbox_ops",
                 %{"runId" => "whatever", "generation" => generation - 1},
                 ["accepted"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- read-only actions without an open workspace -------------------------------

  describe "read-only actions without an open workspace" do
    setup do
      Manager.close()
      :ok
    end

    test "mail_status surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} = rpc("mail_status", %{}, ["status"])
      assert inspect(errors) =~ "workspace_not_open"
    end

    test "list_mail_messages surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc("list_mail_messages", %{}, @messages_fields)

      assert inspect(errors) =~ "workspace_not_open"
    end

    test "get_mail_message surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_message", %{"msgId" => "whatever"}, ["message", "inbox"])

      assert inspect(errors) =~ "workspace_not_open"
    end

    test "mail_inbox surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} = rpc("mail_inbox", %{}, @entries_fields)
      assert inspect(errors) =~ "workspace_not_open"
    end
  end
end
