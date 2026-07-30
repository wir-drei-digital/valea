defmodule ValeaWeb.MailRpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint ValeaWeb.Endpoint

  alias Valea.Mail.Account
  alias Valea.Mail.Index
  alias Valea.Mail.Maildir
  alias Valea.Mail.MessageFile
  alias Valea.Mail.Settings
  alias Valea.Mail.Store
  alias Valea.Mail.Views
  alias Valea.Workspace.Manager

  @mail_fixtures_dir Path.expand("../fixtures/mail", __DIR__)

  # The 69-byte 1x1 RGBA PNG `cid_image.eml` carries, and the `data:` URI it
  # must inline to. Tiny on purpose: the caps below are exercised by growing
  # a LANDED file in the test, never by committing a megabyte fixture.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNkYGAAAAAFAAENCi20AAAAAElFTkSuQmCC"
  @png_data_uri "data:image/png;base64," <> @png_b64

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

  # `plant_message!` with an explicit `Message-ID` and, for a reply, the
  # `In-Reply-To`/`References` pair a conforming mailer sends — the headers
  # `thread_key` is derived from. `flags:` takes maildir flag LETTERS
  # (`["S"]` = already read); the default is an unread delivery.
  defp plant_threaded!(root, account, folder_abs, uid, opts) do
    threading =
      case Keyword.get(opts, :parent) do
        nil -> ""
        parent -> "In-Reply-To: #{parent}\r\nReferences: #{parent}\r\n"
      end

    raw =
      "From: Priya Nair <priya@example.com>\r\n" <>
        "Subject: #{Keyword.fetch!(opts, :subject)}\r\n" <>
        "Date: #{Keyword.fetch!(opts, :date)}\r\n" <>
        "Message-ID: #{Keyword.fetch!(opts, :message_id)}\r\n" <>
        threading <>
        "\r\nBody of #{Keyword.fetch!(opts, :subject)}.\r\n"

    flags = opts |> Keyword.get(:flags, []) |> MapSet.new()

    {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
    Maildir.deliver!(folder_abs, Maildir.encode_filename(msg_id, uid, flags, ":"), raw)
    msg_id
  end

  defp plant_html_message!(root, account, folder_abs, uid) do
    raw =
      "From: Priya Nair <priya@example.com>\r\n" <>
        "To: Mara Lindt <mara@example.com>\r\n" <>
        "Subject: Formatted update\r\n" <>
        "Date: Fri, 10 Jul 2026 09:15:00 +0000\r\n" <>
        "Message-ID: <html-rpc-#{System.unique_integer([:positive])}@example.com>\r\n" <>
        "MIME-Version: 1.0\r\n" <>
        "Content-Type: multipart/alternative; boundary=\"BB\"\r\n" <>
        "\r\n" <>
        "--BB\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n" <>
        "\r\n" <>
        "Plain version.\r\n" <>
        "--BB\r\n" <>
        "Content-Type: text/html; charset=utf-8\r\n" <>
        "\r\n" <>
        "<p>Hello <b>Mara</b></p><img src=\"https://tracker.example/p.gif\">" <>
        "<script>evil()</script>\r\n" <>
        "--BB--\r\n"

    {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
    filename = Maildir.encode_filename(msg_id, uid, MapSet.new(), ":")
    Maildir.deliver!(folder_abs, filename, raw)
    msg_id
  end

  defp mail_fixture(name), do: File.read!(Path.join(@mail_fixtures_dir, name))

  defp plant_raw!(root, account, folder_abs, uid, raw) do
    {:ok, %{msg_id: msg_id}} = Views.land(root, account, raw)
    Maildir.deliver!(folder_abs, Maildir.encode_filename(msg_id, uid, MapSet.new(), ":"), raw)
    msg_id
  end

  # A `multipart/related` message: one text/html part plus one inline part per
  # `{content_id, filename}` in `images`, each carrying the 1x1 PNG. `html`
  # defaults to one `<img src="cid:…">` per image, in order; a test that needs
  # its own markup (a dangling cid, a hostile one, a repeat) passes it.
  defp cid_message(images, html \\ nil) do
    html =
      html || Enum.map_join(images, "", fn {cid, _f} -> ~s[<img src="cid:#{cid}">] end)

    parts =
      Enum.map_join(images, "", fn {cid, filename} ->
        "--RB\r\n" <>
          "Content-Type: image/png; name=\"#{filename}\"\r\n" <>
          "Content-ID: <#{cid}>\r\n" <>
          "Content-Disposition: inline; filename=\"#{filename}\"\r\n" <>
          "Content-Transfer-Encoding: base64\r\n" <>
          "\r\n" <> @png_b64 <> "\r\n"
      end)

    "From: Priya Nair <priya@example.com>\r\n" <>
      "To: Mara Lindt <mara@example.com>\r\n" <>
      "Subject: Inline images\r\n" <>
      "Date: Tue, 14 Jul 2026 08:30:00 +0000\r\n" <>
      "Message-ID: <cid-rpc-#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\n" <>
      "Content-Type: multipart/related; boundary=\"RB\"\r\n" <>
      "\r\n" <>
      "--RB\r\n" <>
      "Content-Type: text/html; charset=utf-8\r\n" <>
      "\r\n" <> html <> "\r\n" <> parts <> "--RB--\r\n"
  end

  defp attachment_abs(root, account, msg_id, filename),
    do: Path.join([root, "sources", "mail", account, "views", "attachments", msg_id, filename])

  defp read_message!(msg_id) do
    assert %{"success" => true, "data" => %{"message" => message}} =
             rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

    message
  end

  # Every `src` of the returned html, decoded — the tree the frontend's iframe
  # would actually see, not a substring of the serialized markup.
  defp html_srcs(html) do
    {:ok, doc} = Floki.parse_document(html)
    doc |> Floki.find("[src]") |> Floki.attribute("src")
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

    # The M5-task-13 notification opt-in: an ordinary boolean argument that
    # lands in `config/mail.yaml` and comes back out on the account's status.
    test "the notifications arg writes the flag and surfaces it on mail_status", %{
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
                   "notifications" => true,
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert {:ok, %{accounts: %{"mara" => account}}} = Settings.load(workspace)
      assert account.notifications == true

      status = await_engine_active!("mara")
      assert status["notifications"] == true
    end

    test "omitting the notifications arg leaves the flag off", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")

      assert {:ok, %{accounts: %{"mara" => account}}} = Settings.load(workspace)
      assert account.notifications == false

      status = await_engine_active!("mara")
      assert status["notifications"] == false
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

      # The falsy-map-field rule's ONE verified exception (this module's
      # moduledoc cites this line): an atom-keyed boolean on an ITEM of an
      # `{:array, :map}` survives as a real `false` rather than being nulled,
      # which is why `has_attachments`/`thread_unread` don't need string keys.
      assert Enum.map(page1, & &1["hasAttachments"]) == [false, false]

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

  # -- threading (list_mail_messages threaded: true / get_mail_thread) -----------

  # The flat shape plus the two fields only a collapsed conversation row
  # carries.
  @threaded_fields [
    %{
      "messages" => [
        "msgId",
        "subject",
        "date",
        "uid",
        "flags",
        "threadKey",
        "threadCount",
        "threadUnread"
      ]
    }
  ]

  # `get_mail_thread` rows are the flat shape plus `folder` — a thread spans
  # folders, so each message says where it lives.
  @thread_fields [
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
        "viewPath",
        "folder"
      ]
    }
  ]

  describe "list_mail_messages threaded" do
    setup %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")

      root =
        plant_threaded!(workspace, "mara", inbox_abs, 1,
          date: "Wed, 01 Jul 2026 09:00:00 +0000",
          subject: "Roadmap",
          message_id: "<root@example.com>"
        )

      reply =
        plant_threaded!(workspace, "mara", inbox_abs, 2,
          date: "Thu, 02 Jul 2026 09:00:00 +0000",
          subject: "Re: Roadmap",
          message_id: "<reply@example.com>",
          parent: "<root@example.com>"
        )

      lunch =
        plant_threaded!(workspace, "mara", inbox_abs, 3,
          date: "Thu, 02 Jul 2026 12:00:00 +0000",
          subject: "Lunch",
          message_id: "<lunch@example.com>"
        )

      {:ok, 3} = Index.rebuild(workspace, "mara")

      %{root_id: root, reply_id: reply, lunch_id: lunch, inbox_abs: inbox_abs}
    end

    test "collapses the folder by thread, newest first, with a per-thread count", %{
      reply_id: reply_id,
      lunch_id: lunch_id
    } do
      assert %{"success" => true, "data" => %{"messages" => [lunch, conversation]}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX", "threaded" => true},
                 @threaded_fields
               )

      assert lunch["msgId"] == lunch_id
      assert lunch["threadKey"] == "<lunch@example.com>"
      assert lunch["threadCount"] == 1

      # The newest message of the thread represents it.
      assert conversation["msgId"] == reply_id
      assert conversation["subject"] == "Re: Roadmap"
      assert conversation["threadKey"] == "<root@example.com>"
      assert conversation["threadCount"] == 2
    end

    test "without the flag the listing is flat — every occurrence, unchanged", %{
      root_id: root_id,
      reply_id: reply_id,
      lunch_id: lunch_id
    } do
      assert %{"success" => true, "data" => %{"messages" => messages}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX"},
                 @messages_fields
               )

      assert Enum.map(messages, & &1["msgId"]) == [lunch_id, reply_id, root_id]

      # The flat projection is exactly what it was before threading existed.
      assert messages |> hd() |> Map.keys() |> Enum.sort() ==
               ~w(date flags fromEmail fromName hasAttachments msgId path subject uid viewPath)

      # ...and asking for the thread fields cannot widen it: they are not in
      # the flat rows at all, so a caller that forgets the flag gets the old
      # payload rather than a row with two null columns bolted on.
      assert %{"success" => true, "data" => %{"messages" => [flat | _]}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX"},
                 @threaded_fields
               )

      refute Map.has_key?(flat, "threadKey")
      refute Map.has_key?(flat, "threadCount")
      refute Map.has_key?(flat, "threadUnread")

      # `threaded: false` is the same path as omitting it.
      assert %{"success" => true, "data" => %{"messages" => same}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX", "threaded" => false},
                 @messages_fields
               )

      assert same == messages
    end

    test "thread_unread answers for the whole conversation, not the row it rides on", %{
      workspace: workspace
    } do
      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      archive_abs = setup_folder!(maildir_root, "Archive", "Archive")

      # A conversation whose OLDEST message is unread and whose NEWEST — the
      # message that will represent it — has been read. The representative's
      # own `flags` say "read"; the thread is not.
      plant_threaded!(workspace, "mara", archive_abs, 1,
        date: "Wed, 01 Jul 2026 09:00:00 +0000",
        subject: "Budget",
        message_id: "<budget@example.com>"
      )

      plant_threaded!(workspace, "mara", archive_abs, 2,
        date: "Thu, 02 Jul 2026 09:00:00 +0000",
        subject: "Re: Budget",
        message_id: "<budget-reply@example.com>",
        parent: "<budget@example.com>",
        flags: ["S"]
      )

      # ...and one where every member has been read.
      plant_threaded!(workspace, "mara", archive_abs, 3,
        date: "Thu, 02 Jul 2026 12:00:00 +0000",
        subject: "Invoice",
        message_id: "<invoice@example.com>",
        flags: ["S"]
      )

      plant_threaded!(workspace, "mara", archive_abs, 4,
        date: "Thu, 02 Jul 2026 13:00:00 +0000",
        subject: "Re: Invoice",
        message_id: "<invoice-reply@example.com>",
        parent: "<invoice@example.com>",
        flags: ["S"]
      )

      {:ok, _} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"messages" => [invoice, budget]}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "Archive", "threaded" => true},
                 @threaded_fields
               )

      assert budget["subject"] == "Re: Budget"
      assert budget["flags"] == "S"
      assert budget["threadUnread"] == true

      # A genuine `false` has to survive the wire, not arrive as `null` —
      # the falsy-map-field bug binds top-level fields, and this is an item
      # field like `hasAttachments` beside it.
      assert invoice["subject"] == "Re: Invoice"
      assert invoice["threadUnread"] == false
      refute is_nil(invoice["threadUnread"])

      # The setup's INBOX threads were delivered with no flags at all.
      assert %{"success" => true, "data" => %{"messages" => inbox}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX", "threaded" => true},
                 @threaded_fields
               )

      assert Enum.all?(inbox, &(&1["threadUnread"] == true))
    end

    test "limit + before page over conversations", %{lunch_id: lunch_id, reply_id: reply_id} do
      assert %{"success" => true, "data" => %{"messages" => [first]}} =
               rpc(
                 "list_mail_messages",
                 %{"account" => "mara", "folder" => "INBOX", "threaded" => true, "limit" => 1},
                 @threaded_fields
               )

      assert first["msgId"] == lunch_id

      assert %{"success" => true, "data" => %{"messages" => [second]}} =
               rpc(
                 "list_mail_messages",
                 %{
                   "account" => "mara",
                   "folder" => "INBOX",
                   "threaded" => true,
                   "limit" => 1,
                   "before" => first["date"]
                 },
                 @threaded_fields
               )

      assert second["msgId"] == reply_id
    end
  end

  describe "get_mail_thread" do
    setup %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")
      archive_abs = setup_folder!(maildir_root, "Archive", "Archive")

      root =
        plant_threaded!(workspace, "mara", archive_abs, 5,
          date: "Wed, 01 Jul 2026 09:00:00 +0000",
          subject: "Roadmap",
          message_id: "<root@example.com>"
        )

      reply =
        plant_threaded!(workspace, "mara", inbox_abs, 2,
          date: "Thu, 02 Jul 2026 09:00:00 +0000",
          subject: "Re: Roadmap",
          message_id: "<reply@example.com>",
          parent: "<root@example.com>"
        )

      plant_threaded!(workspace, "mara", inbox_abs, 3,
        date: "Thu, 02 Jul 2026 12:00:00 +0000",
        subject: "Lunch",
        message_id: "<lunch@example.com>"
      )

      {:ok, 3} = Index.rebuild(workspace, "mara")

      %{root_id: root, reply_id: reply, inbox_abs: inbox_abs}
    end

    test "returns the whole conversation across folders, oldest first", %{
      root_id: root_id,
      reply_id: reply_id
    } do
      assert %{"success" => true, "data" => %{"messages" => [first, second]}} =
               rpc(
                 "get_mail_thread",
                 %{"account" => "mara", "thread_key" => "<root@example.com>"},
                 @thread_fields
               )

      assert first["msgId"] == root_id
      assert first["subject"] == "Roadmap"
      assert first["folder"] == "Archive"
      assert first["fromEmail"] == "priya@example.com"
      assert first["hasAttachments"] == false
      assert first["viewPath"] =~ "views/messages/"

      assert second["msgId"] == reply_id
      assert second["folder"] == "INBOX"
    end

    test "a message occurring in two folders is ONE entry in the thread", %{root_id: root_id} do
      # The same message, a second occurrence — the INBOX copy of a message
      # already filed in Archive.
      Store.upsert_index_row(%{
        account: "mara",
        folder: "INBOX",
        uid: 77,
        msg_id: root_id,
        message_id: "<root@example.com>",
        subject: "Roadmap",
        date: "2026-07-01T09:00:00Z",
        path: Path.join(["sources", "mail", "mara", "maildir", "INBOX", "cur", "x"])
      })

      assert %{"success" => true, "data" => %{"messages" => messages}} =
               rpc(
                 "get_mail_thread",
                 %{"account" => "mara", "thread_key" => "<root@example.com>"},
                 @thread_fields
               )

      assert Enum.count(messages, &(&1["msgId"] == root_id)) == 1
      # Rendered through whichever occurrence sorts first by folder.
      assert Enum.find(messages, &(&1["msgId"] == root_id))["folder"] == "Archive"
    end

    test "an unknown thread key is an empty list, not an error" do
      assert %{"success" => true, "data" => %{"messages" => []}} =
               rpc(
                 "get_mail_thread",
                 %{"account" => "mara", "thread_key" => "<nobody@example.com>"},
                 @thread_fields
               )
    end

    test "an invalid slug is rejected before any lookup" do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "get_mail_thread",
                 %{"account" => "../x", "thread_key" => "<root@example.com>"},
                 @thread_fields
               )

      assert inspect(errors) =~ "invalid_slug"
    end
  end

  # `search_mail` returns the SAME per-row shape as `list_mail_messages`,
  # plus `snippet` — the search UI renders hits through the same list
  # components.
  @search_fields [
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
        "viewPath",
        "snippet"
      ]
    }
  ]

  describe "search_mail" do
    setup %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")

      plant_message!(
        workspace,
        "mara",
        inbox_abs,
        1,
        "Wed, 01 Jul 2026 09:00:00 +0000",
        "Roadmap"
      )

      plant_message!(workspace, "mara", inbox_abs, 2, "Thu, 02 Jul 2026 09:00:00 +0000", "Picnic")

      {:ok, 2} = Index.rebuild(workspace, "mara")

      :ok
    end

    test "returns full summary rows plus a body snippet" do
      assert %{"success" => true, "data" => %{"messages" => [hit]}} =
               rpc("search_mail", %{"account" => "mara", "query" => "roadmap"}, @search_fields)

      assert hit["subject"] == "Roadmap"
      assert hit["fromName"] == "Priya Nair"
      assert hit["fromEmail"] == "priya@example.com"
      assert hit["uid"] == 1
      assert hit["hasAttachments"] == false
      assert hit["viewPath"] =~ "views/messages/"
      assert hit["path"] =~ "maildir/INBOX/cur/"
      assert hit["snippet"] =~ "Roadmap"
    end

    test "a prefix matches, and limit caps the result set" do
      assert %{"success" => true, "data" => %{"messages" => [hit]}} =
               rpc("search_mail", %{"account" => "mara", "query" => "roadm"}, @search_fields)

      assert hit["subject"] == "Roadmap"

      # Both messages carry the sender's address; the limit trims to one.
      assert %{"success" => true, "data" => %{"messages" => both}} =
               rpc("search_mail", %{"account" => "mara", "query" => "priya"}, @search_fields)

      assert length(both) == 2

      assert %{"success" => true, "data" => %{"messages" => [_one]}} =
               rpc(
                 "search_mail",
                 %{"account" => "mara", "query" => "priya", "limit" => 1},
                 @search_fields
               )
    end

    test "an empty query returns no rows rather than everything" do
      assert %{"success" => true, "data" => %{"messages" => []}} =
               rpc("search_mail", %{"account" => "mara", "query" => ""}, @search_fields)

      assert %{"success" => true, "data" => %{"messages" => []}} =
               rpc("search_mail", %{"account" => "mara", "query" => "   "}, @search_fields)
    end

    test "hostile query strings are searched as literal words, never as FTS5 syntax" do
      # Each of these would broaden, redirect, or syntax-error the query if
      # any of it reached FTS5; as literal terms every one of them demands a
      # word no message contains.
      for query <- [
            "roadmap OR picnic",
            "subject:roadmap",
            ~s[roadmap" OR "picnic],
            "-roadmap NEAR/2 picnic",
            "{subject body}:roadmap",
            String.duplicate("roadmap ", 200)
          ] do
        assert %{"success" => true, "data" => %{"messages" => messages}} =
                 rpc("search_mail", %{"account" => "mara", "query" => query}, @search_fields),
               "search_mail failed for #{inspect(query)}"

        assert messages == [], "unexpected hits for #{inspect(query)}"
      end

      # Punctuation is dropped, not escaped and not fatal: an unbalanced
      # quote is a syntax error to FTS5 but just a separator here, so the
      # word beside it still searches normally.
      for query <- [~s["roadmap], ~s[roadmap"], "^roadmap", "roadmap*"] do
        assert %{"success" => true, "data" => %{"messages" => [hit]}} =
                 rpc("search_mail", %{"account" => "mara", "query" => query}, @search_fields),
               "search_mail failed for #{inspect(query)}"

        assert hit["subject"] == "Roadmap"
      end
    end

    test "an invalid slug is rejected before any lookup" do
      assert %{"success" => false, "errors" => errors} =
               rpc("search_mail", %{"account" => "../x", "query" => "roadmap"}, @search_fields)

      assert inspect(errors) =~ "invalid_slug"
    end
  end

  # `mail_search` is the one table that persists message BODY TEXT, so the
  # two teardown actions have to take its rows with them — a purged account
  # whose files are gone must not still answer `search_mail` with body
  # snippets. (Its own describe rather than a case inside `search_mail`
  # above: both actions need a fully-activated-then-removed engine.)
  describe "account teardown clears the search index" do
    setup %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")

      plant_message!(
        workspace,
        "mara",
        inbox_abs,
        1,
        "Wed, 01 Jul 2026 09:00:00 +0000",
        "Roadmap"
      )

      {:ok, 1} = Index.rebuild(workspace, "mara")

      assert [_hit] = Store.search("mara", "roadmap")

      :ok
    end

    test "remove_mail_account drops the rows even though the files stay", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => true} =
               rpc("remove_mail_account", %{"account" => "mara", "generation" => generation}, [
                 "removed"
               ])

      assert Store.search("mara", "roadmap") == []

      assert %{"success" => true, "data" => %{"messages" => []}} =
               rpc("search_mail", %{"account" => "mara", "query" => "roadmap"}, @search_fields)

      # Removal is not a purge: the view files — the source of truth a
      # re-added account rebuilds its index from — are untouched.
      assert File.exists?(Path.join([workspace, "sources", "mail", "mara", "views"]))
    end

    test "purge_mail_account_files drops the rows with the files", %{
      workspace: workspace,
      generation: generation
    } do
      assert %{"success" => true} =
               rpc("remove_mail_account", %{"account" => "mara", "generation" => generation}, [
                 "removed"
               ])

      # Re-feed from the surviving view files, so this test exercises PURGE
      # clearing the index rather than inheriting an index the removal
      # already emptied. (This is also the real state a straggler engine
      # activation would leave behind between the two actions.)
      {:ok, 1} = Index.rebuild(workspace, "mara")
      assert [_hit] = Store.search("mara", "roadmap")

      assert %{"success" => true, "data" => %{"purged" => true}} =
               rpc(
                 "purge_mail_account_files",
                 %{"account" => "mara", "confirmation" => "mara", "generation" => generation},
                 ["purged"]
               )

      refute File.exists?(Path.join([workspace, "sources", "mail", "mara"]))

      # The body text is gone from app.sqlite too — the files were the last
      # other copy.
      assert Store.search("mara", "roadmap") == []

      assert %{"success" => true, "data" => %{"messages" => []}} =
               rpc("search_mail", %{"account" => "mara", "query" => "roadmap"}, @search_fields)
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

  # -- get_mail_account_settings / mail_autoconfig ------------------------------

  describe "get_mail_account_settings" do
    test "returns the non-secret config for the edit form; smtp null without a block", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara", host: "imap.fastmail.com", port: 993)

      assert %{"success" => true, "data" => data} =
               rpc("get_mail_account_settings", %{"account" => "mara"}, [
                 "notifications",
                 %{
                   "account" => [
                     "host",
                     "port",
                     "username",
                     %{"smtp" => ["host", "port", "security", "username", "from", "fromName"]}
                   ]
                 }
               ])

      account = data["account"]
      assert account["host"] == "imap.fastmail.com"
      assert account["port"] == 993
      assert account["username"] == "mara@example.com"
      assert account["smtp"] == nil
      # `notifications` is TOP-LEVEL and string-keyed for exactly this
      # assertion: a `false` under an atom key arrives as `null` (the
      # falsy-map-field bug), whether at the top level or nested in `account`.
      assert data["notifications"] == false
    end

    test "prefills notifications for an account that opted in", %{generation: generation} do
      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "zoe",
                   "host" => "imap.example.com",
                   "port" => 993,
                   "username" => "zoe@example.com",
                   "notifications" => true,
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert %{"success" => true, "data" => data} =
               rpc("get_mail_account_settings", %{"account" => "zoe"}, [
                 "notifications",
                 %{"account" => ["host"]}
               ])

      assert data["notifications"] == true
    end

    test "includes the smtp block when configured", %{generation: generation} do
      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "zoe",
                   "host" => "imap.example.com",
                   "port" => 993,
                   "username" => "zoe@example.com",
                   "generation" => generation,
                   "smtpHost" => "smtp.example.com",
                   "smtpPort" => 587,
                   "smtpUsername" => "zoe@example.com"
                 },
                 ["saved"]
               )

      assert %{"success" => true, "data" => %{"account" => account}} =
               rpc("get_mail_account_settings", %{"account" => "zoe"}, [
                 %{
                   "account" => [
                     "host",
                     "port",
                     "username",
                     %{"smtp" => ["host", "port", "security", "username", "from", "fromName"]}
                   ]
                 }
               ])

      assert account["smtp"]["host"] == "smtp.example.com"
      assert account["smtp"]["port"] == 587
      assert account["smtp"]["security"] == "starttls"
      assert account["smtp"]["username"] == "zoe@example.com"
    end

    test "auth round-trips: omitted is password, oauth2 comes back as oauth2", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara", host: "imap.fastmail.com", port: 993)

      assert %{"success" => true, "data" => %{"account" => account}} =
               rpc("get_mail_account_settings", %{"account" => "mara"}, [
                 %{"account" => ["host", "auth"]}
               ])

      assert account["auth"] == "password"

      assert %{"success" => true} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "zoe",
                   "host" => "imap.example.com",
                   "port" => 993,
                   "username" => "zoe@example.com",
                   "auth" => "oauth2",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert %{"success" => true, "data" => %{"account" => zoe}} =
               rpc("get_mail_account_settings", %{"account" => "zoe"}, [
                 %{"account" => ["host", "auth"]}
               ])

      assert zoe["auth"] == "oauth2"
    end

    test "an auth mode this backend doesn't know is refused, not defaulted", %{
      generation: generation
    } do
      # A downgrade to `password` would have the engine offer an access token as
      # a LOGIN password, so the whole setup call fails instead.
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "setup_mail_account",
                 %{
                   "account" => "zoe",
                   "host" => "imap.example.com",
                   "port" => 993,
                   "username" => "zoe@example.com",
                   "auth" => "kerberos",
                   "generation" => generation
                 },
                 ["saved"]
               )

      assert inspect(errors) =~ "invalid_auth"

      assert %{"success" => false, "errors" => not_found} =
               rpc("get_mail_account_settings", %{"account" => "zoe"}, [%{"account" => ["host"]}])

      assert inspect(not_found) =~ "not_found"
    end

    test "unknown slug is not_found; bad grammar is invalid_slug" do
      assert %{"success" => false, "errors" => errors} =
               rpc("get_mail_account_settings", %{"account" => "ghost"}, [
                 %{"account" => ["host"]}
               ])

      assert inspect(errors) =~ "not_found"

      assert %{"success" => false, "errors" => errors2} =
               rpc("get_mail_account_settings", %{"account" => "../x"}, [%{"account" => ["host"]}])

      assert inspect(errors2) =~ "invalid_slug"
    end
  end

  describe "mail_autoconfig" do
    test "an address without a usable domain is invalid_email" do
      assert %{"success" => false, "errors" => errors} =
               rpc("mail_autoconfig", %{"email" => "nope"}, ["source"])

      assert inspect(errors) =~ "invalid_email"
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

    test "an HTML message returns the sanitized rendering + external-content flag; trust flows through",
         %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")

      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      inbox_abs = setup_folder!(maildir_root, "INBOX", "INBOX")
      msg_id = plant_html_message!(workspace, "mara", inbox_abs, 7)
      {:ok, 1} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"message" => message}} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

      assert message["html"] =~ "<p>Hello <b>Mara</b></p>"
      refute message["html"] =~ "<script"
      assert message["external_content"] == true
      assert message["sender_trusted"] == false

      # Trust the sender -> the same read now reports trusted; the list RPC
      # reflects it; untrust reverts.
      assert %{"success" => true, "data" => %{"trusted" => true}} =
               rpc(
                 "set_mail_sender_trust",
                 %{"email" => "priya@example.com", "trusted" => true, "generation" => generation},
                 ["trusted"]
               )

      assert %{"success" => true, "data" => %{"message" => %{"sender_trusted" => true}}} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

      assert %{"success" => true, "data" => %{"senders" => ["priya@example.com"]}} =
               rpc("list_trusted_mail_senders", %{}, ["senders"])

      assert %{"success" => true} =
               rpc(
                 "set_mail_sender_trust",
                 %{
                   "email" => "priya@example.com",
                   "trusted" => false,
                   "generation" => generation
                 },
                 ["trusted"]
               )

      assert %{"success" => true, "data" => %{"senders" => []}} =
               rpc("list_trusted_mail_senders", %{}, ["senders"])
    end

    test "a plain-text message reports no html and no external content",
         %{workspace: workspace, generation: generation} do
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
          "Plain"
        )

      {:ok, 1} = Index.rebuild(workspace, "mara")

      assert %{"success" => true, "data" => %{"message" => message}} =
               rpc("get_mail_message", %{"account" => "mara", "msgId" => msg_id}, ["message"])

      assert message["html"] == nil
      assert message["external_content"] == false
    end

    test "set_mail_sender_trust refuses an invalid address", %{generation: generation} do
      assert %{"success" => false, "errors" => errors} =
               rpc(
                 "set_mail_sender_trust",
                 %{"email" => "not-an-address", "trusted" => true, "generation" => generation},
                 ["trusted"]
               )

      assert inspect(errors) =~ "invalid_email"
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

  # -- get_mail_message: `cid:` image inlining ---------------------------------

  describe "get_mail_message — cid: images" do
    setup %{workspace: workspace, generation: generation} do
      setup_account!(generation, account: "mara")
      maildir_root = Path.join([workspace, "sources", "mail", "mara", "maildir"])
      %{inbox: setup_folder!(maildir_root, "INBOX", "INBOX")}
    end

    defp land_and_index!(workspace, inbox, raw) do
      msg_id = plant_raw!(workspace, "mara", inbox, 1, raw)
      {:ok, _count} = Index.rebuild(workspace, "mara")
      msg_id
    end

    # Hand-edit the landed view's `attachments:` line — exactly what a human,
    # or an agent talked into it by the message it is reading, can do to a
    # workspace file. `entries` is a list of keyword lists; binary values are
    # rendered the way `MessageFile.render/2` renders them.
    defp patch_attachments!(workspace, msg_id, entries) do
      rendered =
        Enum.map_join(entries, ", ", fn entry ->
          fields =
            Enum.map_join(entry, ", ", fn
              {key, value} when is_binary(value) ->
                "#{key}: #{MessageFile.yaml_string(value)}"

              {key, value} ->
                "#{key}: #{value}"
            end)

          "{ " <> fields <> " }"
        end)

      path = Path.join(workspace, Views.view_rel_path("mara", msg_id))

      {:ok, patched} =
        MessageFile.patch_frontmatter(File.read!(path), %{"attachments" => "[#{rendered}]"})

      File.write!(path, patched)
    end

    test "the fixture's inline image becomes a data: URI; a dangling cid stays broken",
         %{workspace: workspace, inbox: inbox} do
      msg_id = land_and_index!(workspace, inbox, mail_fixture("cid_image.eml"))

      message = read_message!(msg_id)

      assert html_srcs(message["html"]) == [@png_data_uri, "cid:absent@valea.test"]

      # A `data:` image is not remote content, and the unresolved `cid:` is
      # not either — the remote-content banner must stay down.
      assert message["external_content"] == false
    end

    test "the same cid referenced twice inlines at both sites",
         %{workspace: workspace, inbox: inbox} do
      raw =
        cid_message(
          [{"logo@valea.test", "logo.png"}],
          ~s[<img src="cid:logo@valea.test"><p>and again</p><img src="cid:logo@valea.test">]
        )

      msg_id = land_and_index!(workspace, inbox, raw)

      assert html_srcs(read_message!(msg_id)["html"]) == [@png_data_uri, @png_data_uri]
    end

    test "hostile cid values stay inert: metacharacters match nothing, quotes cannot escape",
         %{workspace: workspace, inbox: inbox} do
      raw =
        cid_message(
          [{~s[a"b>], "one.png"}, {"logo", "two.png"}],
          ~s[<img src="cid:a&quot;b&gt;">] <>
            ~s[<img src="cid:.*">] <>
            ~s[<img src="cid:lo.o">] <>
            ~s[<img src="cid:x&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;">] <>
            ~s[<img src="cid:logo">]
        )

      msg_id = land_and_index!(workspace, inbox, raw)
      html = read_message!(msg_id)["html"]

      # A cid carrying `"` and `>` is matched byte-for-byte and inlined; regex
      # metacharacters match only themselves, so `.*`/`lo.o` resolve to
      # nothing even though `logo` is right there.
      assert html_srcs(html) == [
               @png_data_uri,
               "cid:.*",
               "cid:lo.o",
               ~s[cid:x"><script>alert(1)</script>],
               @png_data_uri
             ]

      # The unresolved hostile value is written back ESCAPED — five images,
      # no script element, nothing spliced out of its attribute.
      refute html =~ "<script"
      {:ok, doc} = Floki.parse_document(html)
      assert length(Floki.find(doc, "img")) == 5
      assert Floki.find(doc, "script") == []
    end

    test "only known image extensions inline — .svg and .txt stay broken",
         %{workspace: workspace, inbox: inbox} do
      raw =
        cid_message([
          {"vec@valea.test", "logo.svg"},
          {"doc@valea.test", "notes.txt"},
          {"ok@valea.test", "logo.png"}
        ])

      msg_id = land_and_index!(workspace, inbox, raw)

      assert html_srcs(read_message!(msg_id)["html"]) == [
               "cid:vec@valea.test",
               "cid:doc@valea.test",
               @png_data_uri
             ]
    end

    test "the per-image cap is exact: 1 MB inlines, one byte more stays broken",
         %{workspace: workspace, inbox: inbox} do
      raw = cid_message([{"big@valea.test", "big.png"}])
      msg_id = land_and_index!(workspace, inbox, raw)
      path = attachment_abs(workspace, "mara", msg_id, "big.png")

      File.write!(path, :binary.copy("x", 1024 * 1024))
      assert [inlined] = html_srcs(read_message!(msg_id)["html"])
      assert inlined == "data:image/png;base64," <> Base.encode64(:binary.copy("x", 1024 * 1024))

      File.write!(path, :binary.copy("x", 1024 * 1024 + 1))
      assert html_srcs(read_message!(msg_id)["html"]) == ["cid:big@valea.test"]
    end

    test "the 4 MB per-message cap stops inlining, in document order",
         %{workspace: workspace, inbox: inbox} do
      images = for i <- 1..5, do: {"img#{i}@valea.test", "img#{i}.png"}
      msg_id = land_and_index!(workspace, inbox, cid_message(images))

      for {_cid, filename} <- images do
        File.write!(
          attachment_abs(workspace, "mara", msg_id, filename),
          :binary.copy("x", 1_000_000)
        )
      end

      srcs = html_srcs(read_message!(msg_id)["html"])

      # 4 x 1_000_000 fits under 4 MB; the fifth would not, so it — and only
      # it — stays a broken `cid:`.
      assert length(srcs) == 5
      assert Enum.all?(Enum.take(srcs, 4), &String.starts_with?(&1, "data:image/png;base64,"))
      assert Enum.at(srcs, 4) == "cid:img5@valea.test"
    end

    test "two attachments sharing a Content-ID: the first in frontmatter order wins",
         %{workspace: workspace, inbox: inbox} do
      raw =
        cid_message(
          [{"dup@valea.test", "one.png"}, {"dup@valea.test", "two.png"}],
          ~s[<img src="cid:dup@valea.test">]
        )

      msg_id = land_and_index!(workspace, inbox, raw)
      File.write!(attachment_abs(workspace, "mara", msg_id, "one.png"), "FIRST")
      File.write!(attachment_abs(workspace, "mara", msg_id, "two.png"), "SECOND")

      assert html_srcs(read_message!(msg_id)["html"]) ==
               ["data:image/png;base64," <> Base.encode64("FIRST")]
    end

    test "a symlink planted at the attachment's name is never followed — inside or outside",
         %{workspace: workspace, inbox: inbox} do
      raw = cid_message([{"logo@valea.test", "logo.png"}, {"other@valea.test", "other.png"}])
      msg_id = land_and_index!(workspace, inbox, raw)

      logo = attachment_abs(workspace, "mara", msg_id, "logo.png")
      other = attachment_abs(workspace, "mara", msg_id, "other.png")

      # Escaping link: refused by containment.
      outside = Path.join(workspace, "secret.png")
      File.write!(outside, "SECRET")
      File.rm!(logo)
      File.ln_s!(outside, logo)

      # Contained link: still refused, by the no-follow read.
      File.write!(other, "NEIGHBOUR")
      neighbour = attachment_abs(workspace, "mara", msg_id, "neighbour.png")
      File.rename!(other, neighbour)
      File.ln_s!(neighbour, other)

      html = read_message!(msg_id)["html"]

      assert html_srcs(html) == ["cid:logo@valea.test", "cid:other@valea.test"]
      refute html =~ Base.encode64("SECRET")
      refute html =~ Base.encode64("NEIGHBOUR")
    end

    # The ANCESTOR case, which the test above does not reach: the final
    # component is a perfectly ordinary regular file, so `lstat` waves it
    # through, and containment based on the attachments dir cannot help
    # because `Valea.Paths.resolve_real/2` physically walks its BASE first —
    # a symlinked `attachments` (or `views`, or `sources/mail/<slug>`) MOVES
    # the boundary to wherever the link points, and every file under it then
    # measures as contained. Only the workspace-root-based call sees it.
    # Same attack, same directory, same reasoning as
    # `ValeaWeb.FilesController.contain_for_serve/2` and its
    # "a symlinked mail attachments DIRECTORY cannot escape the mount" test.
    test "a symlinked attachments DIRECTORY cannot escape the workspace",
         %{workspace: workspace, inbox: inbox} do
      raw = cid_message([{"logo@valea.test", "logo.png"}])
      msg_id = land_and_index!(workspace, inbox, raw)

      # A plausible-looking tree OUTSIDE the workspace, holding a file at
      # exactly the name the frontmatter already points at.
      escape_root =
        Path.join(Path.dirname(workspace), "escape-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(escape_root, msg_id))
      File.write!(Path.join([escape_root, msg_id, "logo.png"]), "SECRET")

      attachments_dir = Path.join([workspace, "sources", "mail", "mara", "views", "attachments"])
      File.rm_rf!(attachments_dir)
      File.ln_s!(escape_root, attachments_dir)

      # The frontmatter is UNTOUCHED — still the ordinary relative path the
      # landing wrote. Only the directory beneath it moved.
      html = read_message!(msg_id)["html"]

      assert html_srcs(html) == ["cid:logo@valea.test"]
      refute html =~ Base.encode64("SECRET")
    end

    test "a hand-edited frontmatter path cannot escape the account's attachments dir",
         %{workspace: workspace, inbox: inbox} do
      raw = cid_message([{"logo@valea.test", "logo.png"}])
      msg_id = land_and_index!(workspace, inbox, raw)

      escaped = Path.join([workspace, "sources", "secret.png"])
      File.write!(escaped, "SECRET")

      patch_attachments!(workspace, msg_id, [
        [
          filename: "logo.png",
          path: "sources/mail/mara/views/attachments/../../../../secret.png",
          bytes: 6,
          content_id: "logo@valea.test"
        ]
      ])

      html = read_message!(msg_id)["html"]
      assert html_srcs(html) == ["cid:logo@valea.test"]
      refute html =~ Base.encode64("SECRET")

      # An absolute path is not under the account's attachments dir either.
      patch_attachments!(workspace, msg_id, [
        [filename: "logo.png", path: escaped, bytes: 6, content_id: "logo@valea.test"]
      ])

      html = read_message!(msg_id)["html"]
      assert html_srcs(html) == ["cid:logo@valea.test"]
      refute html =~ Base.encode64("SECRET")
    end

    test "a view landed before content_id existed simply does not inline (no backfill)",
         %{workspace: workspace, inbox: inbox} do
      raw = cid_message([{"logo@valea.test", "logo.png"}])
      msg_id = land_and_index!(workspace, inbox, raw)

      patch_attachments!(workspace, msg_id, [
        [
          filename: "logo.png",
          path: "sources/mail/mara/views/attachments/#{msg_id}/logo.png",
          bytes: 69
        ]
      ])

      assert html_srcs(read_message!(msg_id)["html"]) == ["cid:logo@valea.test"]
    end

    test "a cid-bearing message with no html part reads normally, with html: nil",
         %{workspace: workspace, inbox: inbox} do
      raw =
        "From: Priya Nair <priya@example.com>\r\n" <>
          "Subject: No html\r\n" <>
          "Date: Tue, 14 Jul 2026 08:30:00 +0000\r\n" <>
          "Message-ID: <cid-nohtml@example.com>\r\n" <>
          "MIME-Version: 1.0\r\n" <>
          "Content-Type: multipart/related; boundary=\"RB\"\r\n" <>
          "\r\n" <>
          "--RB\r\n" <>
          "Content-Type: text/plain; charset=utf-8\r\n" <>
          "\r\n" <>
          "See cid:logo@valea.test\r\n" <>
          "--RB\r\n" <>
          "Content-Type: image/png; name=\"logo.png\"\r\n" <>
          "Content-ID: <logo@valea.test>\r\n" <>
          "Content-Disposition: inline; filename=\"logo.png\"\r\n" <>
          "Content-Transfer-Encoding: base64\r\n" <>
          "\r\n" <> @png_b64 <> "\r\n--RB--\r\n"

      msg_id = land_and_index!(workspace, inbox, raw)
      message = read_message!(msg_id)

      assert message["html"] == nil
      assert message["external_content"] == false
      assert [%{"content_id" => "logo@valea.test"}] = message["frontmatter"]["attachments"]
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

  # -- write_mail_draft (spec E §Drafting & push) ---------------------------------

  describe "write_mail_draft" do
    @write_md """
    ---
    to: [alex@example.com]
    subject: "Re: Kickoff"
    status: draft
    ---
    Hello Alex.
    """

    defp write_draft_rpc(input, generation) do
      rpc(
        "write_mail_draft",
        Map.merge(%{"account" => "mara", "generation" => generation}, input),
        ["name", "saved"]
      )
    end

    defp drafts_path(workspace, name),
      do: Path.join([workspace, "sources", "mail", "mara", "drafts", name])

    test "creates a draft under a minted name and returns it", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => true, "data" => %{"name" => name, "saved" => true}} =
               write_draft_rpc(
                 %{"name" => nil, "content" => @write_md, "baseHash" => nil},
                 generation
               )

      # `YYYYMMDDTHHMMSS-<subject-slug>.md` — the subject slug is taken from
      # the PARSED draft ("Re: Kickoff"), and the `.md` suffix makes the name
      # usable verbatim by every other draft RPC.
      assert name =~ ~r/^\d{8}T\d{6}-re-kickoff\.md$/

      # BYTE-for-byte, trailing newline included: anything the RPC layer
      # trimmed would stop the file hashing to what the caller wrote, and the
      # CAS on the next save would fail against bytes nobody edited.
      assert File.read!(drafts_path(workspace, name)) == @write_md

      # It is a real draft to the rest of the surface immediately.
      assert %{"success" => true, "data" => %{"content" => @write_md}} =
               rpc("get_mail_draft", %{"account" => "mara", "draftName" => name}, ["content"])

      # A second create with the SAME subject in the same second must not
      # clobber the first — it gets a numeric suffix.
      assert %{"success" => true, "data" => %{"name" => second}} =
               write_draft_rpc(
                 %{"name" => nil, "content" => @write_md, "baseHash" => nil},
                 generation
               )

      assert second != name
      assert File.exists?(drafts_path(workspace, name))
    end

    test "a subject with nothing sluggable falls back to the literal draft", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      content = String.replace(@write_md, ~s(subject: "Re: Kickoff"), ~s(subject: "!!! ???"))

      assert %{"success" => true, "data" => %{"name" => name}} =
               write_draft_rpc(
                 %{"name" => nil, "content" => content, "baseHash" => nil},
                 generation
               )

      assert name =~ ~r/^\d{8}T\d{6}-draft\.md$/
    end

    test "updates an existing draft when base_hash matches, refuses when it is stale", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")
      write_rpc_draft!(workspace, "mara", "reply.md", @write_md)

      edited = String.replace(@write_md, "Hello Alex.", "Hello Alex, one more thing.")
      base = Valea.Mail.DraftFile.content_hash(@write_md)

      assert %{"success" => true, "data" => %{"name" => "reply.md", "saved" => true}} =
               write_draft_rpc(
                 %{"name" => "reply.md", "content" => edited, "baseHash" => base},
                 generation
               )

      assert File.read!(drafts_path(workspace, "reply.md")) == edited

      # The SAME base hash is now stale — an agent (or the user's other
      # window) has moved the file on, and this write would discard that.
      assert %{"success" => false, "errors" => [%{"type" => "content_changed"}]} =
               write_draft_rpc(
                 %{"name" => "reply.md", "content" => @write_md, "baseHash" => base},
                 generation
               )

      assert File.read!(drafts_path(workspace, "reply.md")) == edited

      # `base_hash: nil` means CREATE — never a blind overwrite of a draft
      # that is already there.
      assert %{"success" => false, "errors" => [%{"type" => "content_changed"}]} =
               write_draft_rpc(
                 %{"name" => "reply.md", "content" => @write_md, "baseHash" => nil},
                 generation
               )

      assert File.read!(drafts_path(workspace, "reply.md")) == edited
    end

    test "refuses content the draft grammar rejects, writing nothing", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      bad = [
        # no frontmatter block at all
        "Just a body.\n",
        # no recipient
        "---\nsubject: \"Hi\"\n---\nBody.\n",
        # a field the grammar does not know (the sending identity is
        # config-owned — a draft may not set `from`)
        "---\nto: [a@example.com]\nfrom: spoof@example.com\n---\nBody.\n"
      ]

      for content <- bad do
        assert %{"success" => false, "errors" => [%{"type" => "invalid_draft"}]} =
                 write_draft_rpc(
                   %{"name" => nil, "content" => content, "baseHash" => nil},
                   generation
                 )
      end

      # Nothing landed — not the draft, not a `.md.tmp`, not even the
      # directory the write would have created on its way.
      assert File.ls(Path.join([workspace, "sources", "mail", "mara", "drafts"])) in [
               {:error, :enoent},
               {:ok, []}
             ]
    end

    test "refuses empty content as a grammar failure, not a missing argument", %{
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => [%{"type" => "invalid_draft"}]} =
               write_draft_rpc(%{"name" => nil, "content" => "", "baseHash" => nil}, generation)
    end

    test "refuses traversal/separator names and never writes through a symlink", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      for bad <- ["../escape.md", "a/b.md", "..\\x.md", ".md", "no-extension"] do
        assert %{"success" => false, "errors" => [%{"type" => "invalid_draft_name"}]} =
                 write_draft_rpc(
                   %{"name" => bad, "content" => @write_md, "baseHash" => nil},
                   generation
                 )
      end

      refute File.exists?(Path.join(workspace, "escape.md"))

      # A grammar-clean name whose ENTRY is a symlink out of the drafts dir is
      # refused by containment (`Paths.resolve_real/2`) — the target keeps its
      # bytes, and the write does not follow the link.
      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)
      outside = Path.join(workspace, "planted.md")
      File.write!(outside, "sensitive target content")
      File.ln_s!(outside, Path.join(drafts_dir, "link.md"))

      assert %{"success" => false, "errors" => [%{"type" => "link_unsafe"}]} =
               write_draft_rpc(
                 %{"name" => "link.md", "content" => @write_md, "baseHash" => nil},
                 generation
               )

      assert File.read!(outside) == "sensitive target content"
    end

    test "never writes through a symlink planted at the TEMP name", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      # The containment gate covers `<name>.md`, but the temp file is the path
      # actually opened FIRST — and `drafts/` is agent-writable. A predictable
      # `<name>.md.tmp` opened `O_TRUNC` follows this link and overwrites the
      # target (verified: a plain `File.write!` here does clobber it), then
      # renames the link itself into place as the draft. The exclusive create
      # on a unique temp name cannot do either.
      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)
      outside = Path.join(workspace, "secret.txt")
      File.write!(outside, "sensitive target content")
      File.ln_s!(outside, Path.join(drafts_dir, "target.md.tmp"))

      assert %{"success" => true, "data" => %{"name" => "target.md", "saved" => true}} =
               write_draft_rpc(
                 %{"name" => "target.md", "content" => @write_md, "baseHash" => nil},
                 generation
               )

      assert File.read!(outside) == "sensitive target content"

      # What landed is a REGULAR file holding the new bytes — not the planted
      # link renamed over the draft name.
      assert %File.Stat{type: :regular} = File.lstat!(drafts_path(workspace, "target.md"))
      assert File.read!(drafts_path(workspace, "target.md")) == @write_md

      # The only `.tmp` left is the planted one; the write leaked none of its
      # own (a unique temp name is never reused, so an orphan would be
      # permanent).
      assert Enum.filter(File.ls!(drafts_dir), &String.ends_with?(&1, ".tmp")) ==
               ["target.md.tmp"]
    end

    test "a filesystem failure comes back as one stable code, never a raw errno", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      # Read-only drafts dir: the temp create fails `:eacces`, which must NOT
      # reach the client as `"eacces"` — that is a code nothing maps, and it
      # describes the host's filesystem rather than the save.
      drafts_dir = Path.join([workspace, "sources", "mail", "mara", "drafts"])
      File.mkdir_p!(drafts_dir)
      File.chmod!(drafts_dir, 0o555)
      on_exit(fn -> File.chmod(drafts_dir, 0o755) end)

      assert %{"success" => false, "errors" => [%{"type" => "write_failed"}]} =
               write_draft_rpc(
                 %{"name" => "denied.md", "content" => @write_md, "baseHash" => nil},
                 generation
               )

      assert File.ls!(drafts_dir) == []
    end

    test "refuses a draft the ledger says is mid-flight", %{
      workspace: workspace,
      generation: generation
    } do
      # `draft_with_ops!` writes `reply.md` and plants the ledger row; the
      # projection this refusal keys off is the SAME one the listing renders.
      draft =
        draft_with_ops!(workspace, generation, @write_md, [
          {"send", "transmitted", %{inserted_at: "2026-07-26T10:00:00.000000Z"}}
        ])

      assert draft["status_display"] == "sending"

      assert %{"success" => false, "errors" => [%{"type" => "draft_busy"}]} =
               write_draft_rpc(
                 %{
                   "name" => "reply.md",
                   "content" => String.replace(@write_md, "Hello Alex.", "Edited mid-send."),
                   "baseHash" => Valea.Mail.DraftFile.content_hash(@write_md)
                 },
                 generation
               )

      # The bytes the in-flight send is bound to are untouched.
      assert File.read!(drafts_path(workspace, "reply.md")) == @write_md
    end

    test "refuses a draft the ledger says was already sent", %{
      workspace: workspace,
      generation: generation
    } do
      # `sent` is a non-`draft` ledger state too, and the completed op names
      # THIS revision — the pen may not rewrite the bytes underneath it. (An
      # agent editing through its mount still can; that is what the
      # `earlier_revision_sent` display exists for.)
      hash = Valea.Mail.DraftFile.content_hash(@write_md)

      draft =
        draft_with_ops!(workspace, generation, @write_md, [
          {"send", "complete", %{inserted_at: "2026-07-26T10:00:00.000000Z", content_hash: hash}}
        ])

      assert draft["status_display"] == "sent"

      assert %{"success" => false, "errors" => [%{"type" => "draft_busy"}]} =
               write_draft_rpc(
                 %{
                   "name" => "reply.md",
                   "content" => String.replace(@write_md, "Hello Alex.", "Edited after send."),
                   "baseHash" => hash
                 },
                 generation
               )

      assert File.read!(drafts_path(workspace, "reply.md")) == @write_md
    end

    test "refuses an unknown account rather than littering an unconfigured tree", %{
      workspace: workspace,
      generation: generation
    } do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
               rpc(
                 "write_mail_draft",
                 %{
                   "account" => "ghost",
                   "name" => nil,
                   "content" => @write_md,
                   "baseHash" => nil,
                   "generation" => generation
                 },
                 ["name", "saved"]
               )

      refute File.exists?(Path.join([workspace, "sources", "mail", "ghost"]))
    end

    test "rejects a malformed slug and a stale generation", %{generation: generation} do
      setup_account!(generation, account: "mara")
      await_engine_active!("mara")

      assert %{"success" => false, "errors" => [%{"type" => "invalid_slug"}]} =
               rpc(
                 "write_mail_draft",
                 %{
                   "account" => "../x",
                   "name" => nil,
                   "content" => @write_md,
                   "baseHash" => nil,
                   "generation" => generation
                 },
                 ["name", "saved"]
               )

      assert %{"success" => false, "errors" => [%{"type" => "workspace_changed"}]} =
               write_draft_rpc(
                 %{"name" => nil, "content" => @write_md, "baseHash" => nil},
                 generation + 1
               )
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
