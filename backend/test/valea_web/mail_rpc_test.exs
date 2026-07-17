defmodule ValeaWeb.MailRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Account
  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.Views
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    # The Runtime's per-account Engines read this at init, so it must be set
    # before the workspace opens.
    Application.put_env(:valea, :mail_transport, FakeMailTransport)
    {:ok, _} = FakeMailTransport.start_link()

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
      Application.delete_env(:valea, :mail_transport)
    end)

    {:ok, ws} = Manager.create("W")
    %{"data" => %{"generation" => generation}} = rpc("get_workspace", %{})

    %{workspace: ws.path, generation: generation}
  end

  defp rpc(action, input, fields \\ []) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-valea-token", "valea-dev-token")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => fields})
    |> json_response(200)
  end

  # -- fixtures ---------------------------------------------------------------

  defp setup_account!(generation, opts) do
    account = Keyword.get(opts, :account, "mara")
    host = Keyword.get(opts, :host, "imap.fastmail.com")
    port = Keyword.get(opts, :port, 993)
    username = Keyword.get(opts, :username, "#{account}@example.com")

    assert %{"success" => true} =
             rpc(
               "setup_mail_account",
               %{
                 "account" => account,
                 "host" => host,
                 "port" => port,
                 "username" => username,
                 "generation" => generation
               },
               ["saved"]
             )

    account
  end

  defp set_credential!(account, generation, secret \\ "app-password") do
    assert %{"success" => true} =
             rpc(
               "set_mail_credential",
               %{"account" => account, "secret" => secret, "generation" => generation},
               ["accepted"]
             )

    :ok
  end

  # Waits for an account's Engine to leave "inactive" — a fresh
  # `setup_mail_account` self-activates its Engine asynchronously
  # (`Valea.Mail.Supervisor`'s "Rehashing" — no `:workspace_opened` broadcast
  # is coming for a mid-session account), so a request landing immediately
  # after can otherwise race it.
  defp await_engine_active!(account) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case rpc("mail_status", %{}, ["accounts"]) do
        %{"success" => true, "data" => %{"accounts" => accounts}} ->
          case Enum.find(accounts, &(&1["account"] == account)) do
            %{"state" => "inactive"} ->
              Process.sleep(5)
              {:cont, nil}

            %{} = found ->
              {:halt, found}

            nil ->
              Process.sleep(5)
              {:cont, nil}
          end
      end
    end)
  end

  defp setup_folder!(maildir_root, dir_name, imap_name) do
    abs = Path.join(maildir_root, dir_name)
    Maildir.mailbox_dirs(abs)
    Maildir.write_folder_identity!(abs, imap_name)
    abs
  end

  defp plant_message!(root, account, folder_abs, uid, date, subject) do
    raw = """
    From: Priya Nair <priya@example.com>\r
    Subject: #{subject}\r
    Date: #{date}\r
    Message-ID: <#{System.unique_integer([:positive])}@example.com>\r
    \r
    Body of #{subject}.\r
    """

    {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
    filename = Maildir.encode_filename(msg_id, uid, MapSet.new())
    Maildir.deliver!(folder_abs, filename, raw)
    msg_id
  end

  # -- mail_status --------------------------------------------------------------

  describe "mail_status" do
    test "no accounts configured -> empty accounts list" do
      assert %{"success" => true, "data" => %{"accounts" => []}} =
               rpc("mail_status", %{}, ["accounts"])
    end

    test "lists a valid, running account plus an invalid-config entry, sorted by slug", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "zeta")
      await_engine_active!("zeta")

      # Hand-append a structurally-invalid entry (imap.host missing) straight
      # into the file — `Settings.upsert_account!/3` always re-renders the
      # WHOLE file from its valid-only accounts map, so this must happen
      # AFTER the last `setup_mail_account` call in this test, or it would be
      # dropped on the next rewrite.
      path = Path.join(workspace, "config/mail.yaml")
      doc = File.read!(path)

      broken =
        String.replace(
          doc,
          "safety:",
          "  alpha:\n    provider: generic\n    imap:\n      username: \"nohost@example.com\"\nsafety:"
        )

      File.write!(path, broken)

      assert %{"success" => true, "data" => %{"accounts" => accounts}} =
               rpc("mail_status", %{}, ["accounts"])

      by_account = Map.new(accounts, &{&1["account"], &1})

      assert by_account["zeta"]["valid"] == true
      assert by_account["zeta"]["state"] in ["inactive", "idle"]
      assert by_account["zeta"]["credential"] == "missing"

      assert by_account["alpha"]["valid"] == false
      assert is_binary(by_account["alpha"]["reason"])
      refute Map.has_key?(by_account["alpha"], "credential")

      assert Enum.map(accounts, & &1["account"]) == Enum.sort(Enum.map(accounts, & &1["account"]))
    end
  end

  # -- setup_mail_account ---------------------------------------------------------

  describe "setup_mail_account" do
    test "happy path writes config/mail.yaml and flips mail_status to configured", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      assert File.exists?(Path.join(workspace, "config/mail.yaml"))

      status = await_engine_active!("mara")
      assert status["account"] == "mara"
      assert status["username"] == "mara@example.com"
      assert status["configured"] == true
    end

    test "an invalid slug (path traversal) is rejected before any write", %{
      workspace: workspace,
      generation: generation
    } do
      before_bytes = File.read!(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "../x",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "invalid_slug"
      assert File.read!(Path.join(workspace, "config/mail.yaml")) == before_bytes
    end

    test "a stale generation surfaces workspace_changed and does not write", %{
      workspace: workspace,
      generation: generation
    } do
      before = File.read!(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara",
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

    test "identity mismatch on an existing local subtree refuses without touching config", %{
      workspace: workspace,
      generation: generation
    } do
      :ok =
        Account.write_if_absent!(workspace, "mara", %{
          host: "imap.other.com",
          username: "someone-else@example.com"
        })

      before = File.read!(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "identity_mismatch"
      assert File.read!(Path.join(workspace, "config/mail.yaml")) == before
    end
  end

  # -- remove_mail_account / purge_mail_account_files ---------------------------

  describe "remove_mail_account" do
    test "happy path removes the config entry and stops the engine; files stay", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      setup_folder!(maildir_root, "INBOX", "INBOX")

      assert %{"success" => true, "data" => %{"removed" => true}} =
               rpc("remove_mail_account", %{"account" => "mara", "generation" => generation}, [
                 "removed"
               ])

      assert %{"success" => true, "data" => %{"accounts" => accounts}} =
               rpc("mail_status", %{}, ["accounts"])

      refute Enum.any?(accounts, &(&1["account"] == "mara"))
      assert File.dir?(maildir_root)
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "remove_mail_account",
                 %{"account" => "mara", "generation" => generation - 1},
                 ["removed"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  describe "purge_mail_account_files" do
    test "requires the confirmation to exactly match the account slug", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "purge_mail_account_files",
                 %{"account" => "mara", "confirmation" => "not-mara", "generation" => generation},
                 ["purged"]
               )

      assert inspect(errors) =~ "confirmation_mismatch"
    end

    test "refuses while a healthy engine is actively running", %{generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "purge_mail_account_files",
                 %{"account" => "mara", "confirmation" => "mara", "generation" => generation},
                 ["purged"]
               )

      assert inspect(errors) =~ "account_active"
    end

    test "succeeds once the account has been removed from config first", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      setup_folder!(maildir_root, "INBOX", "INBOX")

      assert %{"success" => true} =
               rpc("remove_mail_account", %{"account" => "mara", "generation" => generation}, [
                 "removed"
               ])

      assert %{"success" => true, "data" => %{"purged" => true}} =
               rpc(
                 "purge_mail_account_files",
                 %{"account" => "mara", "confirmation" => "mara", "generation" => generation},
                 ["purged"]
               )

      refute File.exists?(Path.join([workspace, "sources", "mail", "mara"]))
    end
  end

  # -- readopt_mail_account / discard_held_folder --------------------------------

  describe "readopt_mail_account" do
    test "not_blocked when the account isn't stuck on mailbox_replaced", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "readopt_mail_account",
                 %{"account" => "mara", "confirmation" => "mara", "generation" => generation},
                 ["readopted"]
               )

      assert inspect(errors) =~ "not_blocked"
    end

    test "requires the confirmation to exactly match the account slug", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "readopt_mail_account",
                 %{"account" => "mara", "confirmation" => "nope", "generation" => generation},
                 ["readopted"]
               )

      assert inspect(errors) =~ "confirmation_mismatch"
    end
  end

  describe "discard_held_folder" do
    test "not_held when the folder isn't currently held", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "discard_held_folder",
                 %{
                   "account" => "mara",
                   "folder" => "Work",
                   "confirmation" => "Work",
                   "generation" => generation
                 },
                 ["discarded"]
               )

      assert inspect(errors) =~ "not_held"
    end

    test "requires the confirmation to exactly match the folder name", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "discard_held_folder",
                 %{
                   "account" => "mara",
                   "folder" => "Work",
                   "confirmation" => "wrong",
                   "generation" => generation
                 },
                 ["discarded"]
               )

      assert inspect(errors) =~ "confirmation_mismatch"
    end
  end

  # -- set_mail_credential --------------------------------------------------------

  describe "set_mail_credential" do
    test "happy path accepts the credential for the given account and never echoes it back", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      secret = "hunter2-super-secret-password"

      response =
        rpc(
          "set_mail_credential",
          %{"account" => "mara", "secret" => secret, "generation" => generation},
          ["accepted"]
        )

      assert %{"success" => true, "data" => %{"accepted" => true}} = response
      refute inspect(response) =~ secret

      status = await_engine_active!("mara")
      assert status["credential"] == "present"
    end

    test "an unknown account surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mail_credential",
                 %{"account" => "ghost", "secret" => "x", "generation" => generation},
                 ["accepted"]
               )

      assert inspect(errors) =~ "not_found"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mail_credential",
                 %{"account" => "mara", "secret" => "x", "generation" => generation - 1},
                 ["accepted"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- mail_sync_now --------------------------------------------------------------

  describe "mail_sync_now" do
    test "happy path returns started: true", %{generation: generation} do
      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)

      FakeMailTransport.script([{:connect, :_, {:error, :test_stop}}])

      assert %{"success" => true, "data" => %{"started" => true}} =
               rpc("mail_sync_now", %{"account" => "mara", "generation" => generation}, [
                 "started"
               ])
    end

    test "an unknown account surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_sync_now", %{"account" => "ghost", "generation" => generation}, [
                 "started"
               ])

      assert inspect(errors) =~ "not_found"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "mail_sync_now",
                 %{"account" => "mara", "generation" => generation - 1},
                 ["started"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- mail_doctor --------------------------------------------------------------

  describe "mail_doctor" do
    test "happy path returns checks and an overall ok flag for the given account", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      assert %{"success" => true, "data" => %{"ok" => ok, "checks" => checks}} =
               rpc("mail_doctor", %{"account" => "mara", "generation" => generation}, [
                 "ok",
                 "checks"
               ])

      assert is_boolean(ok)
      assert is_list(checks)
      assert Enum.any?(checks, &(&1["id"] == "config_present"))
      assert Enum.any?(checks, &(&1["id"] == "maildir_writable"))
    end

    test "an unknown account surfaces not_found", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_doctor", %{"account" => "ghost", "generation" => generation}, [
                 "ok",
                 "checks"
               ])

      assert inspect(errors) =~ "not_found"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "mail_doctor",
                 %{"account" => "mara", "generation" => generation - 1},
                 ["ok", "checks"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- create_mail_folders --------------------------------------------------------

  describe "create_mail_folders" do
    test "happy path connects and creates the missing AI folders", %{generation: generation} do
      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, ["Drafts"]}},
        {:create_folder, [:_, "AI/Review"], :ok},
        {:create_folder, [:_, "AI/Processed"], :ok},
        {:logout, :_, :ok}
      ])

      assert %{"success" => true, "data" => %{"created" => created}} =
               rpc("create_mail_folders", %{"account" => "mara", "generation" => generation}, [
                 "created"
               ])

      assert Enum.sort(created) == Enum.sort(["AI/Review", "AI/Processed"])
    end

    test "no credential surfaces no_credential", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc("create_mail_folders", %{"account" => "mara", "generation" => generation}, [
                 "created"
               ])

      assert inspect(errors) =~ "no_credential"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "create_mail_folders",
                 %{"account" => "mara", "generation" => generation - 1},
                 ["created"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  # -- list_mail_messages / list_mail_folders ------------------------------------

  @messages_fields [
    %{
      "messages" => [
        "msgId",
        "fromName",
        "fromEmail",
        "subject",
        "date",
        "flags",
        "hasAttachments",
        "uid",
        "path",
        "viewPath"
      ]
    }
  ]

  describe "list_mail_messages" do
    test "paginates via limit + before, newest date first", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")

      plant_message!(workspace, "mara", inbox_abs, 1, "Wed, 01 Jul 2026 09:00:00 +0000", "One")
      plant_message!(workspace, "mara", inbox_abs, 2, "Thu, 02 Jul 2026 09:00:00 +0000", "Two")
      plant_message!(workspace, "mara", inbox_abs, 3, "Fri, 03 Jul 2026 09:00:00 +0000", "Three")

      {:ok, 3} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"messages" => page1}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX", "limit" => 2},
                 @messages_fields
               )

      assert length(page1) == 2
      assert Enum.map(page1, & &1["subject"]) == ["Three", "Two"]
      assert Enum.all?(page1, &(&1["viewPath"] =~ "views/messages/"))

      oldest_date = List.last(page1)["date"]

      assert %{"success" => true, "data" => %{"messages" => page2}} =
               rpc(
                 "list_mail_messages",
                 %{
                   "account" => "mara",
                   "folder" => "INBOX",
                   "limit" => 2,
                   "before" => oldest_date
                 },
                 @messages_fields
               )

      assert Enum.map(page2, & &1["subject"]) == ["One"]
    end

    test "an invalid slug is rejected", %{generation: _generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "../x", "folder" => "INBOX"},
                 @messages_fields
               )

      assert inspect(errors) =~ "invalid_slug"
    end
  end

  describe "list_mail_folders" do
    test "reports each folder's dir/held/backfill_complete/message_count", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")
      plant_message!(workspace, "mara", inbox_abs, 1, "Wed, 01 Jul 2026 09:00:00 +0000", "One")
      {:ok, 1} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"folders" => folders}} =
               rpc("list_mail_folders", %{"account" => "mara"}, [
                 %{"folders" => ["name", "dir", "held", "messageCount", "backfillComplete"]}
               ])

      assert [folder] = folders
      assert folder["name"] == "INBOX"
      assert folder["dir"] == "INBOX"
      assert folder["held"] == false
      assert folder["messageCount"] == 1
      assert folder["backfillComplete"] == false
    end
  end

  # -- get_mail_message --------------------------------------------------------

  describe "get_mail_message" do
    test "happy path reads the view: frontmatter + body + path", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")

      msg_id =
        plant_message!(
          workspace,
          "mara",
          inbox_abs,
          1,
          "Wed, 01 Jul 2026 09:00:00 +0000",
          "Hello"
        )

      {:ok, 1} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"message" => message}} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

      assert message["path"] == Views.view_rel_path("mara", msg_id)
      assert message["frontmatter"]["id"] == msg_id
      assert message["body"] =~ "Body of Hello."
    end

    test "a msg_id containing a path traversal segment is rejected before any file I/O" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => "../../../etc/passwd"}, [
                 "message"
               ])

      assert inspect(errors) =~ "invalid_msg_id"
    end

    test "an absolute-path msg_id is rejected before any file I/O" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => "/etc/passwd"}, [
                 "message"
               ])

      assert inspect(errors) =~ "invalid_msg_id"
    end

    test "a symlinked view file is rejected — never followed, even though the msg_id is well-formed",
         %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")
      msg_id = "2026-07-09-attacker-deadbeef12345678"

      views_dir = Path.join([workspace, "sources", "mail", "mara", "views", "messages"])
      File.mkdir_p!(views_dir)

      outside = Path.join(workspace, "secret.md")
      File.write!(outside, "---\nid: leaked\n---\nShould never be read.\n")
      File.ln_s!(outside, Path.join(views_dir, "#{msg_id}.md"))

      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

      assert inspect(errors) =~ "not_found"
    end

    test "an unknown (but well-formed) msg_id surfaces not_found", %{generation: generation} do
      setup_account!(generation, account: "mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "get_mail_message",
                 %{"account" => "mara", "msgId" => "2026-07-09-nobody-deadbeef12345678"},
                 ["message"]
               )

      assert inspect(errors) =~ "not_found"
    end
  end

  # -- stubs: mail_apply_ops / push_draft_to_mailbox / list_mail_drafts ----------

  describe "mail_apply_ops (wired to the executor)" do
    # The executor itself is exercised end-to-end against `ModelMailTransport`
    # in `Valea.Mail.OpsExecutorTest`; here we prove the RPC is WIRED to it
    # (no longer the `ops_executor_not_wired` stub) and returns the frozen
    # per-op results shape. An activated-but-uncredentialed engine can't run
    # the batch, so every op comes back rejected `no_credential` — one result
    # per op, in order — which the stub could never produce.
    test "routes ops through the account's engine and returns per-op results", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => true, "data" => %{"results" => results}} =
               rpc(
                 "mail_apply_ops",
                 %{
                   "account" => "mara",
                   "ops" => [
                     %{"op" => "move", "msg_id" => "m", "from" => "INBOX", "to" => "Archive"},
                     %{
                       "op" => "flag",
                       "msg_id" => "m",
                       "folder" => "INBOX",
                       "add" => ["S"],
                       "remove" => []
                     }
                   ],
                   "generation" => generation
                 },
                 [%{"results" => ["op", "result", "reason"]}]
               )

      assert results == [
               %{"op" => 0, "result" => "rejected", "reason" => "no_credential"},
               %{"op" => 1, "result" => "rejected", "reason" => "no_credential"}
             ]
    end
  end

  describe "push_draft_to_mailbox (wired to the engine)" do
    # The end-to-end claim→spool→APPEND→pushed path is exercised against
    # `ModelMailTransport` in `Valea.Mail.OpsExecutorTest`/`EngineTest`; here we
    # prove the RPC is WIRED to `Engine.push_draft/3` (no longer the
    # `not_implemented` stub) and threads its gate/validation failures back as
    # the frozen `state` action's errors.
    test "an activated-but-uncredentialed account surfaces no_credential", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "push_draft_to_mailbox",
                 %{
                   "account" => "mara",
                   "draftName" => "reply.md",
                   "contentHash" => "deadbeef",
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "no_credential"
    end

    test "a missing draft (credentialed, local-only prepare) surfaces not_found", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "push_draft_to_mailbox",
                 %{
                   "account" => "mara",
                   "draftName" => "nope.md",
                   "contentHash" => "deadbeef",
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "not_found"
    end

    test "a draft_name with a path separator is rejected before any I/O", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "push_draft_to_mailbox",
                 %{
                   "account" => "mara",
                   "draftName" => "../evil.md",
                   "contentHash" => "deadbeef",
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "invalid_draft_name"
    end

    test "a stale generation surfaces workspace_changed", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "push_draft_to_mailbox",
                 %{
                   "account" => "mara",
                   "draftName" => "reply.md",
                   "contentHash" => "deadbeef",
                   "generation" => generation - 1
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "workspace_changed"
    end
  end

  describe "list_mail_drafts" do
    test "returns an empty list when no drafts exist" do
      assert %{"success" => true, "data" => %{"drafts" => []}} =
               rpc("list_mail_drafts", %{}, ["drafts"])
    end

    test "lists an account's drafts with parsed recipients and a ledger-derived state", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)

      File.write!(Path.join(drafts_dir, "reply.md"), """
      ---
      to: [alex@example.com]
      subject: "Re: Kickoff"
      status: draft
      ---
      Hello Alex.
      """)

      # An agent-forged pushed status with NO ledger op must render as draft.
      File.write!(Path.join(drafts_dir, "forged.md"), """
      ---
      to: [b@example.com]
      subject: "Faked"
      status: pushed
      ---
      Body.
      """)

      # `drafts` is an unconstrained `{:array, :map}` — the raw string-keyed
      # maps pass through verbatim (same as `mail_status`'s `accounts`).
      assert %{"success" => true, "data" => %{"drafts" => drafts}} =
               rpc("list_mail_drafts", %{}, ["drafts"])

      by_name = Map.new(drafts, &{&1["name"], &1})

      assert by_name["reply.md"]["account"] == "mara"
      assert by_name["reply.md"]["status_display"] == "draft"

      assert by_name["reply.md"]["parsed_recipients"]["to"] == [
               %{"name" => nil, "email" => "alex@example.com"}
             ]

      assert by_name["forged.md"]["status_display"] == "draft"
      assert by_name["forged.md"]["notice"] == "status_forged"
    end

    test "surfaces a parse error as invalid", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)
      File.write!(Path.join(drafts_dir, "bad.md"), "no frontmatter here\n")

      assert %{"success" => true, "data" => %{"drafts" => drafts}} =
               rpc("list_mail_drafts", %{}, ["drafts"])

      assert [%{"name" => "bad.md", "parsed_recipients" => %{"invalid" => reason}}] = drafts
      assert is_binary(reason)
    end
  end

  # -- mail_inbox: removed ------------------------------------------------------

  describe "mail_inbox (removed)" do
    test "the removed action no longer resolves" do
      assert %{"success" => false, "errors" => errors} = rpc("mail_inbox", %{}, [])
      assert inspect(errors) =~ "action_not_found"
    end
  end

  # -- read-only actions without an open workspace -------------------------------

  describe "read-only actions without an open workspace" do
    setup do
      Manager.close()
      :ok
    end

    test "mail_status surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} = rpc("mail_status", %{}, ["accounts"])
      assert inspect(errors) =~ "workspace_not_open"
    end

    test "list_mail_messages surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX"},
                 @messages_fields
               )

      assert inspect(errors) =~ "workspace_not_open"
    end

    test "get_mail_message surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "get_mail_message",
                 %{"account" => "mara", "msgId" => "2026-07-09-x-deadbeef12345678"},
                 ["message"]
               )

      assert inspect(errors) =~ "workspace_not_open"
    end

    test "list_mail_drafts surfaces workspace_not_open" do
      assert %{"success" => false, "errors" => errors} = rpc("list_mail_drafts", %{}, ["drafts"])
      assert inspect(errors) =~ "workspace_not_open"
    end
  end
end
