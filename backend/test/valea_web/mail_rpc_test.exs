defmodule ValeaWeb.MailRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Account
  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.Settings
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
    filename = Maildir.encode_filename(msg_id, uid, MapSet.new(), ":")
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

    test "the optional smtp_* args write an smtp block and flip smtp_configured", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "smtp_host" => "smtp.fastmail.com",
                   "smtp_port" => 587,
                   "smtp_username" => "mara@example.com",
                   "smtp_from_name" => "Mara",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert {:ok, %{accounts: %{"mara" => account}}} = Settings.load(workspace)

      assert account.smtp == %{
               host: "smtp.fastmail.com",
               port: 587,
               security: :starttls,
               username: "mara@example.com",
               from: "mara@example.com",
               from_name: "Mara"
             }

      status = await_engine_active!("mara")
      assert status["smtp_configured"] == true
      assert status["smtp_credential"] == "missing"
    end

    test "omitting every smtp_* arg leaves a push-only account", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      assert {:ok, %{accounts: %{"mara" => account}}} = Settings.load(workspace)
      assert account.smtp == nil

      status = await_engine_active!("mara")
      assert status["smtp_configured"] == false
      assert status["smtp_credential"] == "n/a"
    end

    test "an invalid smtp block is refused without writing anything", %{
      workspace: workspace,
      generation: generation
    } do
      before_bytes = File.read!(Path.join(workspace, "config/mail.yaml"))

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "smtp_host" => "smtp.fastmail.com",
                   "smtp_port" => 587,
                   "smtp_username" => "mara@example.com",
                   "smtp_from" => "not an addr",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "invalid_smtp"
      assert File.read!(Path.join(workspace, "config/mail.yaml")) == before_bytes
    end

    test "identity mismatch on an existing local subtree refuses without touching config", %{
      workspace: workspace,
      generation: generation
    } do
      :ok =
        Account.write_if_absent!(
          workspace,
          "mara",
          %{
            host: "imap.other.com",
            username: "someone-else@example.com"
          },
          ":"
        )

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

    test "kind: smtp fills the separate smtp slot; the default kind stays imap", %{
      generation: generation
    } do
      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "mara",
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "mara@example.com",
                   "smtp_host" => "smtp.fastmail.com",
                   "smtp_port" => 587,
                   "smtp_username" => "mara@example.com",
                   "generation" => generation
                 },
                 ["saved"]
               )

      await_engine_active!("mara")

      assert %{"success" => true, "data" => %{"accepted" => true}} =
               rpc(
                 "set_mail_credential",
                 %{"account" => "mara", "secret" => "imap-secret", "generation" => generation},
                 ["accepted"]
               )

      status = await_engine_active!("mara")
      assert status["credential"] == "present"
      assert status["smtp_credential"] == "missing"

      assert %{"success" => true, "data" => %{"accepted" => true}} =
               rpc(
                 "set_mail_credential",
                 %{
                   "account" => "mara",
                   "secret" => "smtp-secret",
                   "kind" => "smtp",
                   "generation" => generation
                 },
                 ["accepted"]
               )

      status = await_engine_active!("mara")
      assert status["smtp_credential"] == "present"
      assert status["credential"] == "present"
    end

    test "an unknown kind is rejected", %{generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mail_credential",
                 %{
                   "account" => "mara",
                   "secret" => "x",
                   "kind" => "pop3",
                   "generation" => generation
                 },
                 ["accepted"]
               )

      assert inspect(errors) =~ "invalid_credential_kind"
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
    test "happy path connects and creates the missing folders", %{generation: generation} do
      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:list_folders, :_, {:ok, ["Drafts"]}},
        {:create_folder, [:_, "Sent"], :ok},
        {:create_folder, [:_, "Archive"], :ok},
        {:create_folder, [:_, "Trash"], :ok},
        {:logout, :_, :ok}
      ])

      assert %{"success" => true, "data" => %{"created" => created}} =
               rpc("create_mail_folders", %{"account" => "mara", "generation" => generation}, [
                 "created"
               ])

      assert Enum.sort(created) == Enum.sort(["Sent", "Archive", "Trash"])
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

  # -- send (spec G) ------------------------------------------------------------

  describe "send RPCs (wired to the engine)" do
    defp setup_smtp_account!(generation, opts \\ []) do
      account = Keyword.get(opts, :account, "mara")

      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => account,
                   "host" => "imap.fastmail.com",
                   "port" => 993,
                   "username" => "#{account}@example.com",
                   "smtpHost" => "smtp.fastmail.com",
                   "smtpPort" => 587,
                   "smtpUsername" => "#{account}@example.com",
                   "smtpFromName" => "Mara Ito",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert %{"success" => true} =
               rpc(
                 "set_mail_credential",
                 %{
                   "account" => account,
                   "secret" => "smtp-password",
                   "kind" => "smtp",
                   "generation" => generation
                 },
                 ["accepted"]
               )

      await_engine_active!(account)
      account
    end

    defp write_rpc_draft!(workspace, account, name, body) do
      dir = Path.join([workspace, "sources", "mail", account, "drafts"])
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

    test "get_mail_draft_review returns the one-buffer review snapshot", %{
      workspace: workspace,
      generation: generation
    } do
      setup_smtp_account!(generation)
      write_rpc_draft!(workspace, "mara", "reply.md", @draft_md)

      assert %{"success" => true, "data" => data} =
               rpc(
                 "get_mail_draft_review",
                 %{"account" => "mara", "draftName" => "reply.md"},
                 [
                   "content",
                   "contentHash",
                   "recipients",
                   "subject",
                   "threading",
                   "threadingWarning",
                   "identity",
                   "reviewFingerprint",
                   "smtpConfigured"
                 ]
               )

      assert data["content"] == @draft_md
      assert data["contentHash"] == Valea.Mail.DraftFile.content_hash(@draft_md)
      assert data["recipients"]["to"] == [%{"name" => nil, "email" => "alex@example.com"}]
      assert data["subject"] == "Re: Kickoff"
      assert data["threading"] == nil
      assert data["threadingWarning"] == false
      assert data["identity"]["from"] == "mara@example.com"
      assert data["identity"]["from_name"] == "Mara Ito"
      assert data["smtpConfigured"] == true
      assert is_binary(data["reviewFingerprint"])
    end

    test "get_mail_draft_review on a missing draft surfaces not_found", %{
      generation: generation
    } do
      setup_smtp_account!(generation)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "get_mail_draft_review",
                 %{"account" => "mara", "draftName" => "nope.md"},
                 ["content"]
               )

      assert inspect(errors) =~ "not_found"
    end

    test "send_draft with a stale review fingerprint surfaces re_review_required", %{
      workspace: workspace,
      generation: generation
    } do
      setup_smtp_account!(generation)
      write_rpc_draft!(workspace, "mara", "reply.md", @draft_md)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "send_draft",
                 %{
                   "account" => "mara",
                   "draftName" => "reply.md",
                   "contentHash" => Valea.Mail.DraftFile.content_hash(@draft_md),
                   "reviewFingerprint" => String.duplicate("0", 64),
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "re_review_required"
      # Nothing claimed, nothing composed, nothing transmitted.
      assert Valea.Mail.Store.ops_by_origin("mara", "drafts/reply.md") == []
    end

    test "send_draft on a push-only account surfaces smtp_not_configured", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      write_rpc_draft!(workspace, "mara", "reply.md", @draft_md)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "send_draft",
                 %{
                   "account" => "mara",
                   "draftName" => "reply.md",
                   "contentHash" => Valea.Mail.DraftFile.content_hash(@draft_md),
                   "reviewFingerprint" => "whatever",
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "smtp_not_configured"
    end

    test "send_draft rejects a traversing draft name before any I/O", %{generation: generation} do
      setup_smtp_account!(generation)

      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "send_draft",
                 %{
                   "account" => "mara",
                   "draftName" => "../evil.md",
                   "contentHash" => "deadbeef",
                   "reviewFingerprint" => "x",
                   "generation" => generation
                 },
                 ["state"]
               )

      assert inspect(errors) =~ "invalid_draft_name"
    end

    test "resolve_send_review and retry_sent_copy refuse ops that are not in those states", %{
      generation: generation
    } do
      setup_smtp_account!(generation)
      # Both actions run in the Engine's work slot and open an opportunistic
      # IMAP connection for the Sent copy. Script the refusal so this account's
      # mailbox is cleanly unavailable (the point being that BOTH still answer
      # from the ledger alone).
      FakeMailTransport.script([{:connect, :_, {:error, :nope}}])

      assert %{"success" => false, "errors" => resolve_errors} =
               rpc(
                 "resolve_send_review",
                 %{
                   "account" => "mara",
                   "opId" => "no-such-op",
                   "resolution" => "sent",
                   "generation" => generation
                 },
                 ["resolved"]
               )

      assert inspect(resolve_errors) =~ "not_reviewable"

      assert %{"success" => false, "errors" => retry_errors} =
               rpc(
                 "retry_sent_copy",
                 %{"account" => "mara", "opId" => "no-such-op", "generation" => generation},
                 ["retried"]
               )

      assert inspect(retry_errors) =~ "not_retryable"
    end

    test "resolve_send_review only accepts the two resolutions", %{generation: generation} do
      setup_smtp_account!(generation)

      assert %{"success" => false} =
               rpc(
                 "resolve_send_review",
                 %{
                   "account" => "mara",
                   "opId" => "some-op",
                   "resolution" => "maybe",
                   "generation" => generation
                 },
                 ["resolved"]
               )
    end

    test "every send action takes a generation guard", %{generation: generation} do
      for {action, input, fields} <- [
            {"send_draft",
             %{
               "account" => "mara",
               "draftName" => "reply.md",
               "contentHash" => "h",
               "reviewFingerprint" => "f"
             }, ["state"]},
            {"resolve_send_review", %{"account" => "mara", "opId" => "o", "resolution" => "sent"},
             ["resolved"]},
            {"retry_sent_copy", %{"account" => "mara", "opId" => "o"}, ["retried"]}
          ] do
        assert %{"success" => false, "errors" => errors} =
                 rpc(action, Map.put(input, "generation", generation - 1), fields)

        assert inspect(errors) =~ "workspace_changed", "#{action} must guard the generation"
      end
    end

    # Spec G §Safety invariants — human-only transmission. The send trigger
    # lives on the control-token-gated RPC surface and NOWHERE else: not in the
    # agent session plumbing, not in the ops-file vocabulary, not in the agent
    # briefing the engine materializes into each account root.
    test "the send actions exist only on the control-token RPC surface" do
      send_actions = ["send_draft", "resolve_send_review", "retry_sent_copy"]

      api = File.read!(Path.expand("lib/valea/api/mail.ex"))
      for action <- send_actions, do: assert(api =~ action)

      for source <- [
            "lib/valea/agents/session_server.ex",
            "lib/valea/harnesses/claude_code.ex",
            "lib/valea/agents/env.ex",
            "lib/valea/mail/ops_file.ex",
            "lib/valea/mail/agents_file.ex"
          ] do
        content = File.read!(Path.expand(source))

        for action <- send_actions do
          refute content =~ action, "#{source} must not reference #{action}"
        end
      end
    end
  end

  # -- display projection (spec G §Display projection) ---------------------------

  describe "list_mail_drafts display projection" do
    defp draft_with_ops!(workspace, generation, body, ops) do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "reply.md"), body)

      for {kind, state, attrs} <- ops do
        {:ok, _op} =
          Valea.Mail.Store.create_pending_op(
            Map.merge(
              %{
                kind: kind,
                account: "mara",
                origin: "drafts/reply.md",
                target_folder: "Sent",
                message_id: "<valea.#{kind}.#{System.unique_integer([:positive])}@valea.invalid>",
                msg_id: "reply.md",
                state: state
              },
              attrs
            )
          )
      end

      %{"success" => true, "data" => %{"drafts" => drafts}} =
        rpc("list_mail_drafts", %{}, ["drafts"])

      Enum.find(drafts, &(&1["name"] == "reply.md"))
    end

    @projection_md """
    ---
    to: [alex@example.com]
    subject: "Re: Kickoff"
    status: draft
    ---
    Hello Alex.
    """

    test "a completed push plus a newer rejected send renders draft + the pushed badge", %{
      workspace: workspace,
      generation: generation
    } do
      draft =
        draft_with_ops!(workspace, generation, @projection_md, [
          {"append", "complete", %{inserted_at: "2026-07-26T10:00:00.000000Z"}},
          {"send", "rejected",
           %{
             inserted_at: "2026-07-26T11:00:00.000000Z",
             error: "rejected_recipients: alex@example.com: 550 no such user"
           }}
        ])

      # The push must NOT strand the row as `pushed`: Send/Push both key off
      # the primary state, and this draft is retryable.
      assert draft["status_display"] == "draft"
      assert draft["notice"] =~ "550 no such user"
      assert draft["pushed"] == true
      # A retryable draft has no resolution action to key an op on.
      assert draft["op_id"] == nil
    end

    test "the NEWEST terminal send governs, not the first one found", %{
      workspace: workspace,
      generation: generation
    } do
      hash = Valea.Mail.DraftFile.content_hash(@projection_md)

      draft =
        draft_with_ops!(workspace, generation, @projection_md, [
          {"send", "complete", %{inserted_at: "2026-07-26T10:00:00.000000Z", content_hash: hash}},
          {"send", "rejected",
           %{inserted_at: "2026-07-26T12:00:00.000000Z", error: "send_failed: :auth_failed"}}
        ])

      assert draft["status_display"] == "draft"
      assert draft["notice"] =~ "auth_failed"
      assert draft["pushed"] == false
    end

    test "a completed send renders sent only while the file still hashes to it", %{
      workspace: workspace,
      generation: generation
    } do
      hash = Valea.Mail.DraftFile.content_hash(@projection_md)

      draft =
        draft_with_ops!(workspace, generation, @projection_md, [
          {"send", "complete", %{inserted_at: "2026-07-26T10:00:00.000000Z", content_hash: hash}}
        ])

      assert draft["status_display"] == "sent"
      assert draft["notice"] == nil

      # The human edits the draft after sending: the sent revision is history,
      # and what is on disk now is an unsent draft again.
      File.write!(
        Path.join([workspace, "sources", "mail", "mara", "drafts", "reply.md"]),
        String.replace(@projection_md, "Hello Alex.", "Hello Alex, one more thing.")
      )

      %{"success" => true, "data" => %{"drafts" => drafts}} =
        rpc("list_mail_drafts", %{}, ["drafts"])

      edited = Enum.find(drafts, &(&1["name"] == "reply.md"))
      assert edited["status_display"] == "draft"
      assert edited["notice"] == "earlier_revision_sent"
    end

    test "an in-flight send governs the display and surfaces its notice", %{
      workspace: workspace,
      generation: generation
    } do
      draft =
        draft_with_ops!(workspace, generation, @projection_md, [
          {"send", "transmitted", %{inserted_at: "2026-07-26T10:00:00.000000Z"}}
        ])

      assert draft["status_display"] == "sending"
      assert draft["op_id"] == only_op_id("send")
    end

    test "a parked send renders send_review with its reason", %{
      workspace: workspace,
      generation: generation
    } do
      draft =
        draft_with_ops!(workspace, generation, @projection_md, [
          {"send", "send_review", %{error: "gmail_sent_checked_empty"}}
        ])

      assert draft["status_display"] == "send_review"
      assert draft["notice"] == "gmail_sent_checked_empty"
      # Without this id the panel renders the explanation with no way to
      # answer it — `resolve_send_review` is keyed on the parked op.
      assert draft["op_id"] == only_op_id("send")
    end

    # The projection's `sent` gate compares the completed op's recorded
    # revision against the file's CURRENT hash — and the engine's own stamps
    # move that hash twice (`sending`, then `sent`). Hand-built ledger rows
    # cannot catch a gate that drifts off the real stamp chain, so this one
    # drives a REAL send end to end (executor + engine + both transports) and
    # then reads the projection.
    defp real_send!(workspace, generation, opts) do
      start_supervised!(FakeSmtpTransport)
      Application.put_env(:valea, :mail_smtp_transport, FakeSmtpTransport)
      on_exit(fn -> Application.delete_env(:valea, :mail_smtp_transport) end)
      FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:examine, :_, {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}},
        {:uid_search, :_, {:ok, []}},
        {:append, :_, Keyword.get(opts, :append, {:ok, %{dest_uid: 1}})},
        {:logout, :_, :ok}
      ])

      setup_smtp_account!(generation)
      set_credential!("mara", generation)
      write_rpc_draft!(workspace, "mara", "reply.md", @projection_md)

      %{"success" => true, "data" => review} =
        rpc("get_mail_draft_review", %{"account" => "mara", "draftName" => "reply.md"}, [
          "contentHash",
          "reviewFingerprint"
        ])

      result =
        rpc(
          "send_draft",
          %{
            "account" => "mara",
            "draftName" => "reply.md",
            "contentHash" => review["contentHash"],
            "reviewFingerprint" => review["reviewFingerprint"],
            "generation" => generation
          },
          ["state"]
        )

      assert %{"success" => true, "data" => %{"state" => "sent"}} = result
      # Exactly one transmission for the whole flow.
      assert length(FakeSmtpTransport.calls()) == 1

      listed_draft("reply.md")
    end

    defp listed_draft(name) do
      %{"success" => true, "data" => %{"drafts" => drafts}} =
        rpc("list_mail_drafts", %{}, ["drafts"])

      Enum.find(drafts, &(&1["name"] == name))
    end

    defp only_op_id(kind) do
      [%{id: id}] =
        Valea.Mail.Store.ops_by_origin("mara", "drafts/reply.md")
        |> Enum.filter(&(&1.kind == kind))

      id
    end

    # A REAL push (RPC → Engine → executor → fake IMAP), so the engine's own
    # `pushed` stamp lands on the file exactly as it does in production —
    # which is what the corroboration rule has to recognize.
    defp real_push!(workspace, generation) do
      FakeMailTransport.script([
        {:connect, :_, {:ok, FakeMailTransport}},
        {:examine, :_, {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}},
        {:uid_search, :_, {:ok, []}},
        {:append, :_, {:ok, %{dest_uid: 1}}},
        {:logout, :_, :ok}
      ])

      setup_account!(generation, account: "mara")
      set_credential!("mara", generation)
      await_engine_active!("mara")
      write_rpc_draft!(workspace, "mara", "reply.md", @projection_md)

      assert %{"success" => true, "data" => %{"state" => "pushed"}} =
               rpc(
                 "push_draft_to_mailbox",
                 %{
                   "account" => "mara",
                   "draftName" => "reply.md",
                   "contentHash" => Valea.Mail.DraftFile.content_hash(@projection_md),
                   "generation" => generation
                 },
                 ["state"]
               )

      listed_draft("reply.md")
    end

    test "a REAL push renders draft + the pushed badge, never status_forged", %{
      workspace: workspace,
      generation: generation
    } do
      draft = real_push!(workspace, generation)
      path = Path.join([workspace, "sources", "mail", "mara", "drafts", "reply.md"])

      # The engine stamped the file `pushed`...
      assert File.read!(path) =~ "status: pushed"

      # ...and that stamp is corroborated by its own append op, so it is
      # history, not forgery. `pushed` stays a BADGE: the primary state is
      # `draft`, which is what keeps Send and Push offered on it.
      assert draft["status_display"] == "draft"
      assert draft["notice"] == nil
      assert draft["pushed"] == true
      assert draft["op_id"] == nil

      # Corroboration is KIND-MATCHED: an agent rewriting that stamp to a send
      # status has no send op behind it, so the forgery notice still fires.
      File.write!(path, String.replace(File.read!(path), "status: pushed", "status: sent"))

      forged = listed_draft("reply.md")
      assert forged["status_display"] == "draft"
      assert forged["notice"] == "status_forged"
      assert forged["pushed"] == true
    end

    test "a REAL send renders sent — the engine's own stamps do not read as an edit", %{
      workspace: workspace,
      generation: generation
    } do
      draft = real_send!(workspace, generation, [])

      assert draft["status_display"] == "sent"
      assert draft["notice"] == nil
      assert draft["pushed"] == false
      # The completed send's id — `retry_sent_copy`'s target if its Sent copy
      # had failed (it did not here).
      assert draft["op_id"] == only_op_id("send")

      # Only while the file still hashes to what was sent: a genuine edit
      # afterwards is an unsent draft again, with the earlier revision noted.
      path = Path.join([workspace, "sources", "mail", "mara", "drafts", "reply.md"])
      File.write!(path, String.replace(File.read!(path), "Hello Alex.", "Hello Alex, PS."))

      edited = listed_draft("reply.md")
      assert edited["status_display"] == "draft"
      assert edited["notice"] == "earlier_revision_sent"
    end

    test "a REAL send whose Sent copy failed still renders sent, carrying its notice", %{
      workspace: workspace,
      generation: generation
    } do
      draft = real_send!(workspace, generation, append: {:error, :mailbox_full})

      # The mail IS sent — the notice (and the retry affordance keyed off it)
      # must survive to the panel rather than being swallowed by a stale hash.
      assert draft["status_display"] == "sent"
      assert draft["notice"] == "sent_copy_failed"
      # Without this id the panel's Retry action has nothing to call.
      assert draft["op_id"] == only_op_id("send")
    end

    test "a forged engine-owned status with no ledger op still renders draft", %{
      workspace: workspace,
      generation: generation
    } do
      forged = String.replace(@projection_md, "status: draft", "status: sent")
      draft = draft_with_ops!(workspace, generation, forged, [])

      assert draft["status_display"] == "draft"
      assert draft["notice"] == "status_forged"
      assert draft["pushed"] == false
      assert draft["op_id"] == nil
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

    # Minor #3 (fix wave): listing must take the same no-follow posture as the
    # push path — a symlinked drafts entry is listed as invalid and its target
    # content is NEVER read (the target here is a perfectly VALID draft; had it
    # been read, parsing would have succeeded).
    test "a symlinked draft lists as invalid, target content unread", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)

      outside = Path.join(workspace, "planted.md")

      File.write!(outside, """
      ---
      to: [victim@example.com]
      subject: "Valid if followed"
      ---
      Body.
      """)

      File.ln_s!(outside, Path.join(drafts_dir, "link.md"))

      assert %{"success" => true, "data" => %{"drafts" => drafts}} =
               rpc("list_mail_drafts", %{}, ["drafts"])

      assert [%{"name" => "link.md", "parsed_recipients" => %{"invalid" => "link_unsafe"}}] =
               drafts
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

  describe "get_mail_draft" do
    test "returns the raw draft bytes the push hash must cover", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)

      content = """
      ---
      to: [alex@example.com]
      subject: "Re: Kickoff"
      status: draft
      ---
      Hello Alex.
      """

      File.write!(Path.join(drafts_dir, "reply.md"), content)

      assert %{"success" => true, "data" => %{"content" => ^content, "path" => path}} =
               rpc("get_mail_draft", %{"account" => "mara", "draftName" => "reply.md"}, [
                 "content",
                 "path"
               ])

      assert path == "sources/mail/mara/drafts/reply.md"
    end

    test "rejects traversal/separator draft names before any path construction", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      for bad <- ["../secrets.md", "a/b.md", "..\\x.md", ".md", "no-extension"] do
        assert %{"success" => false, "errors" => [%{"type" => "invalid_draft_name"}]} =
                 rpc("get_mail_draft", %{"account" => "mara", "draftName" => bad}, [
                   "content",
                   "path"
                 ])
      end
    end

    test "a symlinked draft is refused, target content never served", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)

      outside = Path.join(workspace, "planted.md")
      File.write!(outside, "sensitive target content")
      File.ln_s!(outside, Path.join(drafts_dir, "link.md"))

      assert %{"success" => false, "errors" => [%{"type" => "link_unsafe"}]} =
               rpc("get_mail_draft", %{"account" => "mara", "draftName" => "link.md"}, [
                 "content",
                 "path"
               ])
    end

    test "a missing draft is not_found", %{generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
               rpc("get_mail_draft", %{"account" => "mara", "draftName" => "ghost.md"}, [
                 "content",
                 "path"
               ])
    end
  end

  # -- revise_mail_draft (spec G §Request changes) --------------------------------

  describe "revise_mail_draft" do
    # This suite's own setup opens a workspace but mounts no ICM (mail needs
    # none) — the revise flow does: it hosts the session on a primary ICM,
    # with the account's mail mount included.
    defp mount_primary_icm!(workspace) do
      Valea.App.Config.set_harness_command(Valea.AgentCase.fake_cmd("happy"))
      Valea.AgentCase.mount_test_icm!(workspace, name: "Primary")
    end

    defp write_draft!(workspace, account, name) do
      dir = Path.join([workspace, "sources", "mail", account, "drafts"])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, name), """
      ---
      to: [alex@example.com]
      subject: "Re: Kickoff"
      status: draft
      ---
      Hello Alex.
      """)

      Path.join([workspace, "sources", "mail", account, "drafts", name])
    end

    defp revise(input) do
      rpc("revise_mail_draft", input, ["sessionId", "routed"])
    end

    test "routes to the LIVE session whose input locator already names this draft", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      locator = %{"kind" => "workspace", "path" => "sources/mail/mara/drafts/reply.md"}

      {:ok, %{id: existing}} =
        Valea.AgentCase.start_session(workspace, "happy", %{
          input: locator,
          mount_key: icm.mount_key,
          include_mounts: ["mail-mara"]
        })

      on_exit(fn -> Valea.AgentCase.kill_session(existing) end)
      Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> existing)

      assert %{"success" => true, "data" => %{"sessionId" => ^existing, "routed" => "existing"}} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "warmer, and mention Tuesday",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      # The feedback reached that session as a real turn — no new session,
      # no transcript of its own.
      assert_receive {:session_event, _,
                      %{"type" => "message", "role" => "user", "text" => text}},
                     10_000

      assert text =~ "sources/mail/mara/drafts/reply.md"
      assert text =~ "warmer, and mention Tuesday"
      assert text =~ "do not touch the status field"
    end

    test "with no live session on the draft, starts one carrying the mail mount, the input locator, and the prompt",
         %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      assert %{"success" => true, "data" => %{"sessionId" => id, "routed" => "new"}} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "shorter please",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      on_exit(fn -> Valea.AgentCase.kill_session(id) end)

      meta =
        Path.join([workspace, "logs", "sessions", id <> ".jsonl"])
        |> File.stream!()
        |> Enum.at(0)
        |> Jason.decode!()

      assert meta["kind"] == "chat"
      assert meta["icm_mount"] == icm.mount_key
      assert meta["include_mounts"] == ["mail-mara"]

      assert meta["input"] == %{
               "kind" => "workspace",
               "path" => "sources/mail/mara/drafts/reply.md"
             }

      # The session is scoped exactly like any other mail session — the
      # account mounted read-only, plus the one exact read grant for the
      # draft. Nothing here is a path to sending.
      pid = GenServer.whereis({:via, Registry, {Valea.Agents.SessionRegistry, id}})
      ctx = :sys.get_state(pid).policy_ctx
      assert [mail_root] = ctx.mail_roots_in_scope
      assert String.ends_with?(mail_root, "sources/mail/mara")
      assert Enum.any?(ctx.read_roots, &String.ends_with?(&1, "drafts/reply.md"))

      # And the feedback was seeded server-side, with no prompt call at all.
      Phoenix.PubSub.subscribe(Valea.PubSub, "agent_session:" <> id)

      assert_receive {:session_event, _,
                      %{"type" => "message", "role" => "user", "text" => text}},
                     10_000

      assert text =~ "shorter please"
    end

    # Correlation matches the path a session DECLARED, never where that path
    # currently points. Resolve-based matching followed symlinks, so anything
    # able to write a live session's input file could redirect it at a draft
    # and absorb that draft's feedback — the human's words in an unrelated
    # session's transcript, behind a "Sent to session" link to the wrong
    # place. The decoy here is that exact move.
    test "a live session whose input file was replaced by a symlink to the draft does NOT match",
         %{
           workspace: workspace,
           generation: generation
         } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      decoy_dir = Path.join([workspace, "sources", "notes"])
      File.mkdir_p!(decoy_dir)
      decoy = Path.join(decoy_dir, "decoy.md")
      File.write!(decoy, "an ordinary note")

      {:ok, %{id: decoy_session}} =
        Valea.AgentCase.start_session(workspace, "happy", %{
          input: %{"kind" => "workspace", "path" => "sources/notes/decoy.md"},
          mount_key: icm.mount_key
        })

      on_exit(fn -> Valea.AgentCase.kill_session(decoy_session) end)

      # The redirect: the declared path now RESOLVES to the draft.
      File.rm!(decoy)
      File.ln_s!(Path.join([workspace, "sources", "mail", "mara", "drafts", "reply.md"]), decoy)

      assert {:ok, resolved} =
               Valea.Icm.Locator.resolve(workspace, %{
                 "kind" => "workspace",
                 "path" => "sources/notes/decoy.md"
               })

      assert String.ends_with?(resolved, "sources/mail/mara/drafts/reply.md")

      assert %{"success" => true, "data" => %{"sessionId" => id, "routed" => "new"}} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "warmer please",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      on_exit(fn -> Valea.AgentCase.kill_session(id) end)
      refute id == decoy_session
    end

    # A dead session must never absorb feedback. Its registry entry OUTLIVES
    # it — the Registry reaps on a `DOWN` its partition still has to process
    # — and a `GenServer.cast/2` to a dead pid is silently `:ok`, so nothing
    # downstream would notice. Suspending the partition holds the tree in
    # exactly that state deterministically, instead of racing a window that
    # is real but only microseconds wide in practice.
    test "a session whose registry entry outlives it is not routed to", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      {:ok, %{id: dead}} =
        Valea.AgentCase.start_session(workspace, "happy", %{
          input: %{"kind" => "workspace", "path" => "sources/mail/mara/drafts/reply.md"},
          mount_key: icm.mount_key,
          include_mounts: ["mail-mara"]
        })

      assert Enum.any?(Valea.Agents.list_running_session_inputs(), &(elem(&1, 0) == dead))

      # Freeze reaping. Registration is a direct ETS insert and keeps working
      # while the partition is suspended, so the session this call goes on to
      # start still registers normally.
      [{_name, partition, _type, _mods} | _] =
        Supervisor.which_children(Valea.Agents.SessionRegistry)

      :sys.suspend(partition)
      on_exit(fn -> :sys.resume(partition) end)

      Valea.AgentCase.kill_session(dead)
      # The stale entry is genuinely still in the table — this is the state
      # under test, not an assumption about timing.
      assert [{stale_pid, _value}] = Registry.lookup(Valea.Agents.SessionRegistry, dead)
      refute Process.alive?(stale_pid)

      assert %{"success" => true, "data" => %{"sessionId" => id, "routed" => "new"}} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "shorter please",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      on_exit(fn -> Valea.AgentCase.kill_session(id) end)
      refute id == dead

      # The replacement is real and live, with its own transcript.
      assert File.regular?(Path.join([workspace, "logs", "sessions", id <> ".jsonl"]))
      assert Enum.any?(Valea.Agents.list_running_session_inputs(), &(elem(&1, 0) == id))
    end

    test "an unusable mount_key surfaces no_icm_available", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      assert %{"success" => false, "errors" => errors} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "nope",
                 "mountKey" => "not-a-mount",
                 "generation" => generation
               })

      assert inspect(errors) =~ "no_icm_available"
    end

    test "a missing draft is not_found and starts nothing", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)

      assert %{"success" => false, "errors" => errors} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "ghost.md",
                 "feedback" => "nope",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      assert inspect(errors) =~ "not_found"
      assert Valea.Agents.list_running_session_inputs() == []
    end

    test "a symlinked draft is refused, no session started", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)

      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)
      outside = Path.join(workspace, "planted.md")
      File.write!(outside, "sensitive target content")
      File.ln_s!(outside, Path.join(drafts_dir, "link.md"))

      assert %{"success" => false, "errors" => errors} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "link.md",
                 "feedback" => "nope",
                 "mountKey" => icm.mount_key,
                 "generation" => generation
               })

      assert inspect(errors) =~ "link_unsafe"
      assert Valea.Agents.list_running_session_inputs() == []
    end

    test "a stale generation surfaces workspace_changed", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      icm = mount_primary_icm!(workspace)
      write_draft!(workspace, "mara", "reply.md")

      assert %{"success" => false, "errors" => errors} =
               revise(%{
                 "account" => "mara",
                 "draftName" => "reply.md",
                 "feedback" => "nope",
                 "mountKey" => icm.mount_key,
                 "generation" => generation - 1
               })

      assert inspect(errors) =~ "workspace_changed"
      assert Valea.Agents.list_running_session_inputs() == []
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
