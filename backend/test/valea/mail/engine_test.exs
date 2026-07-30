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
  # No IDLE: `supports?/2` above is `false`, so the watcher's capability gate
  # stops before these. They satisfy the behaviour, nothing more.
  @impl true
  def idle_start(_conn), do: {:error, :no_idle}
  @impl true
  def idle_await(_conn, _idle, _timeout_ms), do: {:error, :no_idle}
  @impl true
  def idle_done(_conn, _idle), do: {:error, :no_idle}
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
  # No IDLE: `supports?/2` above is `false`, so the watcher's capability gate
  # stops before these. They satisfy the behaviour, nothing more.
  @impl true
  def idle_start(_conn), do: {:error, :no_idle}
  @impl true
  def idle_await(_conn, _idle, _timeout_ms), do: {:error, :no_idle}
  @impl true
  def idle_done(_conn, _idle), do: {:error, :no_idle}
end

# A `Transport` double for the IDLE lifecycle tests. `connect/3` announces
# itself to the probe pid and blocks until released — exactly like
# `HangingTransport` above — so a test can tell the WATCHER's connection apart
# from a sync pass's (they run in different processes) and answer each with the
# result it wants. Once connected the IDLE conversation simply PARKS: it
# advertises IDLE, accepts the read-only EXAMINE and the IDLE, then sleeps out
# every await deadline. That is what a quiet mailbox looks like, and it keeps
# the watcher alive and observable for as long as a lifecycle test needs.
defmodule Valea.Mail.EngineTest.IdleTransport do
  @behaviour Valea.Mail.Transport

  @impl true
  def connect(_config, credential, _opts) do
    probe = Application.get_env(:valea, :engine_sync_probe)
    # Additively reported (nothing else matches this shape) so a test can also
    # see WHAT the watcher's credential closure resolved to — for an oauth2
    # account, an engine-minted access token.
    send(probe, {:connect_credential, credential})
    send(probe, {:connect_called, self()})

    receive do
      {:release, result} -> result
    end
  end

  @impl true
  def supports?(_conn, :idle), do: true
  def supports?(_conn, _capability), do: false

  @impl true
  def examine(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}

  @impl true
  def idle_start(_conn), do: {:ok, %{}}

  @impl true
  def idle_await(_conn, idle, timeout_ms) do
    Process.sleep(timeout_ms)
    {:ok, [], idle}
  end

  @impl true
  def idle_done(_conn, _idle), do: {:ok, []}

  @impl true
  def capabilities(_conn), do: {:ok, ["IDLE"]}
  @impl true
  def list_folders(_conn), do: {:ok, []}
  @impl true
  def create_folder(_conn, _folder), do: :ok
  @impl true
  def select(_conn, _folder), do: {:ok, %{uidvalidity: 1, uidnext: 1, highestmodseq: nil}}
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
  def logout(_conn), do: :ok
end

# A `Transport` double that reports the CREDENTIAL it was handed to the probe
# pid and then refuses the connection. It is how a test sees what a worker's
# zero-arity credential closure actually resolved to at the `connect/3`
# boundary — for an oauth2 account, the engine-minted access token.
defmodule Valea.Mail.EngineTest.CredentialProbeTransport do
  def connect(_config, credential, _opts) do
    send(Application.get_env(:valea, :engine_sync_probe), {:connect_credential, credential})
    {:error, :closed}
  end
end

# A transport whose `connect/3` RAISES — standing in for any unexpected raise
# inside the push Task (`OpsExecutor.execute_append/2`'s cross-account op-id
# guard raises exactly the same way, one call further in). Deliberately NOT a
# `@behaviour Valea.Mail.Transport`: nothing past `connect/3` is reachable, and
# stubbing twenty unreachable callbacks would only obscure that.
defmodule Valea.Mail.EngineTest.RaisingConnectTransport do
  def connect(_config, _credential, _opts) do
    raise ArgumentError, "op 42 belongs to account other, engine ctx is mara"
  end
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

  defp smtp_settings do
    %{
      host: "smtp.fastmail.com",
      port: 587,
      security: :starttls,
      username: "mara@example.com",
      from: "mara@example.com",
      from_name: nil
    }
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

  test "activation materializes the account-root AGENTS.md briefing + CLAUDE.md link", %{
    root: root
  } do
    start_engine!(root, 57, "mara")
    open(root, 57)

    assert Engine.status("mara").state == "idle"

    agents = Path.join([root, "sources", "mail", "mara", "AGENTS.md"])
    assert File.read!(agents) =~ "Mail account `mara`"

    claude = Path.join([root, "sources", "mail", "mara", "CLAUDE.md"])
    assert File.read_link(claude) == {:ok, "AGENTS.md"}
  end

  test "identity mismatch blocks the briefing too: nothing is materialized", %{root: root} do
    :ok =
      Account.write_if_absent!(root, "mara", %{host: "other.example.com", username: "x@y.z"}, ":")

    start_engine!(root, 58, "mara")
    open(root, 58)

    assert Engine.status("mara").state == "identity_mismatch"
    refute File.exists?(Path.join([root, "sources", "mail", "mara", "AGENTS.md"]))
  end

  test "identity mismatch: a pre-written .account with a DIFFERENT identity blocks activation entirely",
       %{root: root} do
    :ok =
      Account.write_if_absent!(
        root,
        "mara",
        %{
          host: "imap.other.com",
          username: "someone-else@example.com"
        },
        ":"
      )

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

  # -- maildir separator (windows-support spec C1) ------------------------------

  test "claiming a slug records the HOST's separator; every later activation reads it back",
       %{root: root} do
    expected = if Valea.Paths.host_platform() == :windows, do: ";", else: ":"

    start_engine!(root, 53, "mara")
    open(root, 53)

    assert Engine.status("mara").state == "idle"
    assert File.read!(Account.account_path(root, "mara")) =~ ~s(maildir_separator: "#{expected}")
    assert Account.separator(root, "mara") == {:ok, expected}
  end

  test "an existing store's recorded separator wins over the host — the pass writes `;` names",
       %{root: root} do
    slug = "mara"

    # A store provisioned on Windows, now being opened here: `.account` says
    # `;`, so every filename this pass writes must say `;` too. The engine
    # must never re-derive the separator from the host it happens to run on.
    :ok =
      Account.write_if_absent!(
        root,
        slug,
        %{host: "imap.fastmail.com", username: "mara@example.com"},
        ";"
      )

    raw =
      "From: A <a@example.com>\r\nSubject: Hi\r\nDate: Wed, 15 Jul 2026 09:00:00 +0000\r\n" <>
        "Message-ID: <sep@example.com>\r\n\r\nBody\r\n"

    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "INBOX")
    ModelMailTransport.put_message(name, "INBOX", raw)

    Application.put_env(:valea, :mail_transport, ModelMailTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    start_engine!(root, 54, slug, connect_opts: [name: name])
    open(root, 54)

    assert Engine.status(slug).state == "idle"
    :ok = Engine.set_credential(slug, "app-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:mail_sync_finished, ^slug, %{errors: []}}, 2_000

    dir = elem(Store.get_sync_state(slug, "INBOX"), 1).dir
    files = File.ls!(Path.join([root, "sources", "mail", slug, "maildir", dir, "cur"]))

    assert files != []
    assert Enum.all?(files, &String.contains?(&1, ";2,"))
    refute Enum.any?(files, &String.contains?(&1, ":2,"))
  end

  test "an invalid maildir_separator blocks activation exactly like an identity mismatch",
       %{root: root} do
    path = Account.account_path(root, "mara")
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      ~s(host: "imap.fastmail.com"\nusername: "mara@example.com"\nmaildir_separator: "|"\n)
    )

    start_engine!(root, 55, "mara")
    open(root, 55)

    status = Engine.status("mara")
    assert status.state == "identity_mismatch"
    assert status.last_error == "invalid maildir_separator in .account"
    assert Engine.sync_now("mara") == {:error, :inactive}

    # Same fail-closed posture as a mismatched identity: nothing indexed.
    assert Store.folders("mara") == []
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
    # The status names the account's on-disk store — settings-card display.
    assert status.root == Path.join([root, "sources", "mail", "mara"])
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

  # -- smtp credential (v5) ------------------------------------------------------

  test "set_credential/3 with :smtp fills a SEPARATE slot; the 2-arity call stays imap-only", %{
    root: root
  } do
    start_engine!(root, 90, "mara", settings: settings("mara", %{smtp: smtp_settings()}))
    open(root, 90)

    status = Engine.status("mara")
    assert status["smtp_configured"] == true
    assert status["smtp_credential"] == "missing"
    assert status.credential == "missing"

    # The 2-arity call is still exactly `:imap` — it must not fill the smtp slot.
    assert :ok = Engine.set_credential("mara", "imap-secret")
    status = Engine.status("mara")
    assert status.credential == "present"
    assert status["smtp_credential"] == "missing"

    assert :ok = Engine.set_credential("mara", "s3", :smtp)
    status = Engine.status("mara")
    assert status["smtp_credential"] == "present"
    assert status.credential == "present"
  end

  test "an account with no smtp block reports smtp_configured false and credential n/a", %{
    root: root
  } do
    start_engine!(root, 91, "mara")
    open(root, 91)

    status = Engine.status("mara")
    assert status["smtp_configured"] == false
    assert status["smtp_credential"] == "n/a"
  end

  test "env fallback: VALEA_MAIL_SMTP_PASSWORD_<SLUG> seeds the smtp credential at activation", %{
    root: root
  } do
    System.put_env("VALEA_MAIL_SMTP_PASSWORD_MARA", "smtp-dev-fallback")
    on_exit(fn -> System.delete_env("VALEA_MAIL_SMTP_PASSWORD_MARA") end)

    start_engine!(root, 92, "mara", settings: settings("mara", %{smtp: smtp_settings()}))
    open(root, 92)

    status = Engine.status("mara")
    assert status["smtp_credential"] == "present"
    # The IMAP slot has its OWN env var and stays empty.
    assert status.credential == "missing"
  end

  test "redaction: the smtp secret never appears in :sys.get_state", %{root: root} do
    start_engine!(root, 93, "mara", settings: settings("mara", %{smtp: smtp_settings()}))
    open(root, 93)

    secret = "smtp-super-duper-secret-XYZ"
    :ok = Engine.set_credential("mara", secret, :smtp)

    dump =
      Engine.via("mara")
      |> GenServer.whereis()
      |> :sys.get_state()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute dump =~ secret
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

  # A sending account's doctor run must reach the SMTP transport with the
  # engine's OWN smtp credential slot — the wiring that makes the three SMTP
  # checks real rather than theoretical.
  test "doctor/1 on a sending account probes SMTP through the configured smtp transport", %{
    root: root
  } do
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
    Application.put_env(:valea, :mail_smtp_transport, FakeSmtpTransport)

    on_exit(fn ->
      Application.delete_env(:valea, :mail_transport)
      Application.delete_env(:valea, :mail_smtp_transport)
    end)

    {:ok, _} = FakeMailTransport.start_link()
    {:ok, _} = FakeSmtpTransport.start_link()

    smtp = %{smtp_settings() | host: "localhost", port: port}

    start_engine!(root, 94, "mara",
      settings:
        settings("mara", %{
          imap: %{host: "localhost", port: port, username: "mara@example.com"},
          smtp: smtp
        })
    )

    open(root, 94)
    :ok = Engine.set_credential("mara", "app-password")
    :ok = Engine.set_credential("mara", "smtp-password", :smtp)

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:list_folders, :_, {:ok, ["Drafts", "Sent", "Archive", "Trash"]}},
      {:capabilities, :_, {:ok, ["IMAP4rev1", "MOVE"]}},
      {:logout, :_, :ok}
    ])

    FakeSmtpTransport.script([{:check_auth, :_, :ok}])

    assert {:ok, %{ok: true, checks: checks}} = Engine.doctor("mara")
    assert Enum.map(checks, & &1["id"]) |> Enum.take(-3) == ["smtp_tcp", "smtp_tls", "smtp_auth"]

    # The smtp block PLUS the account's SASL mode (`Settings.smtp_config/1`,
    # M6 task 15): what the transport authenticates WITH is what the doctor
    # must probe with.
    expected_config = Map.put(smtp, :auth, :password)
    assert [{:check_auth, [^expected_config, "smtp-password", _opts]}] = FakeSmtpTransport.calls()
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

  # Every Engine in a workspace is started by the same supervisor within
  # milliseconds of each other, so a bare `interval * 60_000` would have N
  # accounts poll in lockstep forever. `poll_delay_ms/1` is the (pure,
  # timer-free) stagger — asserted here rather than through the timer.
  describe "poll_delay_ms" do
    test "adds the configured jitter to the interval (the test seam)" do
      on_exit(fn -> Application.delete_env(:valea, :mail_poll_jitter) end)

      Application.put_env(:valea, :mail_poll_jitter, 0)
      assert Engine.poll_delay_ms(15) == 15 * 60_000

      Application.put_env(:valea, :mail_poll_jitter, 1234)
      assert Engine.poll_delay_ms(15) == 15 * 60_000 + 1234
    end

    test "jitters within [interval, interval + 60s] by default, and actually varies" do
      Application.delete_env(:valea, :mail_poll_jitter)

      base = 15 * 60_000
      delays = for _ <- 1..50, do: Engine.poll_delay_ms(15)

      assert Enum.all?(delays, &(&1 in base..(base + 60_000)))
      assert length(Enum.uniq(delays)) >= 2
    end
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

  test "a pass reporting :reauth_required goes sticky under its OWN state, and pauses polling",
       %{root: root} do
    # The OAuth2 twin of the test above (M6 task 15): same sticky, poll-paused
    # posture, but its own status and its own error sentence — "authentication
    # failed" would send the user hunting for a password to re-type.
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 25, "mara")
    open(root, 25)

    :ok = Engine.set_credential("mara", "ya29.TOKEN")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, task_pid}

    send(task_pid, {:release, {:error, :reauth_required}})

    assert_receive {:mail_sync_finished, "mara", %{new_messages: 0, errors: ["sign-in expired"]}}

    status = Engine.status("mara")
    assert status.state == "reauth_required"
    assert status.last_error == "sign-in expired"

    pid = GenServer.whereis(Engine.via("mara"))
    assert %{poll_timer: nil, sync_task: nil} = :sys.get_state(pid)

    # Sticky: the automatic triggers stay backed off...
    send(pid, :poll)
    assert %{poll_timer: nil} = :sys.get_state(pid)
    assert Engine.status("mara").state == "reauth_required"

    # ...and a fresh token clears it and re-arms polling, exactly like a fresh
    # password clears `auth_failed`.
    assert :ok = Engine.set_credential("mara", "ya29.FRESH")
    state_after = :sys.get_state(pid)
    assert state_after.status == "idle"
    assert state_after.poll_timer != nil
    assert Engine.status("mara").state == "idle"
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
    version: 5
    accounts:
      mara:
        provider: generic
        imap:
          host: ""
          username: "mara@example.com"
    safety:
      never_expunge: true
      outbound: human_send_and_push
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

  # The push Task rescues everything so a raise can't fell the Engine — but a
  # rescue that returns a display string and says nothing is how a wiring bug
  # (a cross-account op id) becomes an op that retries every pass forever with
  # no trace. The caller still gets `"pushing"`; the raise must reach the log.
  test "an unexpected raise inside the push is logged, not silently swallowed", %{root: root} do
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.RaisingConnectTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)

    slug = "mara"
    start_engine!(root, 83, slug)
    open(root, 83)
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)
    hash = Valea.Mail.DraftFile.content_hash(@draft_md)

    log =
      capture_log(fn ->
        assert {:ok, "pushing"} = Engine.push_draft(slug, "reply.md", hash)
      end)

    assert log =~ "mail push failed (account mara, op "
    assert log =~ "op 42 belongs to account other, engine ctx is mara"
    # The credential never rides along into the log.
    refute log =~ "app-password"

    # Durable and untouched: the op is still pending for the next pass.
    assert [%{state: "pending"}] = Store.ops_by_origin(slug, "drafts/reply.md")
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

  # -- Send serialization + settings pinning (Task 4, spec G §Send pipeline) ----

  defp draft_hash, do: Valea.Mail.DraftFile.content_hash(@draft_md)

  defp read_draft_status(root, slug, name) do
    {:ok, %{status: status}} =
      Path.join([root, "sources", "mail", slug, "drafts", name])
      |> File.read!()
      |> Valea.Mail.DraftFile.parse_and_validate()

    status
  end

  defp use_transports!(imap) do
    Application.put_env(:valea, :mail_transport, imap)
    Application.put_env(:valea, :mail_smtp_transport, FakeSmtpTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :mail_smtp_transport) end)
    start_supervised!(FakeSmtpTransport)
  end

  defp credential_pair!(slug) do
    :ok = Engine.set_credential(slug, "app-password")
    :ok = Engine.set_credential(slug, "smtp-password", :smtp)
  end

  defp smtp_account_attrs(from_name) do
    %{
      host: "imap.fastmail.com",
      port: 993,
      username: "mara@example.com",
      smtp: %{
        host: "smtp.fastmail.com",
        port: 587,
        username: "mara@example.com",
        from: "mara@example.com",
        from_name: from_name
      }
    }
  end

  # The queued send's ledger state, or nil — `prepare_send/4` creates the row
  # `claimed` and transitions it to `pending` once both spool payloads are
  # fsynced, so a test that only waits for the row to EXIST can observe the
  # claim mid-flight.
  defp queued_send_state(slug) do
    case Store.ops_by_origin(slug, "drafts/reply.md") do
      [%{state: state}] -> state
      _none_or_many -> nil
    end
  end

  defp wait_until(fun, remaining \\ 200) do
    cond do
      fun.() -> :ok
      remaining == 0 -> flunk("condition never became true")
      true -> Process.sleep(5) && wait_until(fun, remaining - 1)
    end
  end

  test "draft_review is the atomic review snapshot the send binds to", %{root: root} do
    slug = "mara"
    use_transports!(ModelMailTransport)
    start_engine!(root, 90, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 90)

    write_draft!(root, slug, "reply.md", @draft_md)

    assert {:ok, review} = Engine.draft_review(slug, "reply.md")
    assert review["content"] == @draft_md
    assert review["content_hash"] == draft_hash()
    assert review["recipients"]["to"] == [%{"name" => nil, "email" => "alex@example.com"}]
    assert review["recipients"]["cc"] == []
    assert review["subject"] == "Re: Kickoff"
    assert review["threading"] == nil
    assert review["threading_warning"] == false

    assert review["identity"] == %{
             "from" => "mara@example.com",
             "from_name" => nil,
             "account" => "mara"
           }

    assert is_binary(review["review_fingerprint"])
    assert review["smtp_configured"] == true

    assert {:error, "not_found"} = Engine.draft_review(slug, "nope.md")
  end

  test "send_draft transmits exactly once and files the Sent copy", %{root: root} do
    slug = "mara"
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "Sent")

    use_transports!(ModelMailTransport)
    FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

    start_engine!(root, 91, slug,
      settings: settings(slug, %{smtp: smtp_settings()}),
      connect_opts: [name: name]
    )

    open(root, 91)
    credential_pair!(slug)

    write_draft!(root, slug, "reply.md", @draft_md)
    {:ok, review} = Engine.draft_review(slug, "reply.md")

    assert {:ok, "sent"} =
             Engine.send_draft(slug, "reply.md", draft_hash(), review["review_fingerprint"])

    assert [{:send, [_config, credential, envelope, data, _opts]}] = FakeSmtpTransport.calls()
    assert credential == "smtp-password"
    assert envelope == %{from: "mara@example.com", rcpt: ["alex@example.com"]}
    assert data =~ "Message-ID: <valea.send."

    assert [filed] = ModelMailTransport.messages(name, "Sent")
    assert filed.raw =~ "Message-ID: <valea.send."
  end

  test "send_draft refuses a push-only account before anything is claimed", %{root: root} do
    slug = "mara"
    use_transports!(ModelMailTransport)
    start_engine!(root, 92, slug)
    open(root, 92)
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)

    assert {:error, :smtp_not_configured} =
             Engine.send_draft(slug, "reply.md", draft_hash(), nil)

    assert Store.ops_by_origin(slug, "drafts/reply.md") == []
    assert FakeSmtpTransport.calls() == []
  end

  test "send_draft refuses when the SMTP credential slot is empty", %{root: root} do
    slug = "mara"
    use_transports!(ModelMailTransport)
    start_engine!(root, 93, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 93)
    # IMAP credentialed, SMTP not — the two slots are independent.
    :ok = Engine.set_credential(slug, "app-password")

    write_draft!(root, slug, "reply.md", @draft_md)

    assert {:error, :no_smtp_credential} =
             Engine.send_draft(slug, "reply.md", draft_hash(), nil)

    assert Store.ops_by_origin(slug, "drafts/reply.md") == []
  end

  test "send_draft rides the serialized work slot; a second click sees the first op", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    use_transports!(Valea.Mail.EngineTest.HangingTransport)
    FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

    slug = "mara"
    start_engine!(root, 94, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 94)
    credential_pair!(slug)

    write_draft!(root, slug, "reply.md", @draft_md)
    {:ok, review} = Engine.draft_review(slug, "reply.md")
    fingerprint = review["review_fingerprint"]

    # A sync pass is hung at connect — it holds the single work slot.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}

    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:send_reply, Engine.send_draft(slug, "reply.md", draft_hash(), fingerprint)}
      )
    end)

    # The LOCAL claim/spool runs inline, but nothing connects and — the point —
    # NOTHING is transmitted while the send waits for the slot. (`pending`, not
    # merely present: the claim is born `claimed` and transitions once spooled.)
    wait_until(fn -> queued_send_state(slug) == "pending" end)
    refute_receive {:connect_called, _concurrent}, 200
    assert FakeSmtpTransport.calls() == []

    # ...and the caller is answered RIGHT NOW, while the pass still holds the
    # slot. The op is durable, so holding the reply until the slot frees would
    # time the call out on a long pass and report failure — on the one
    # irreversible action — for a message that will transmit regardless.
    assert_receive {:send_reply, {:ok, "sending"}}, 1_000

    # A second click carrying the PRE-STAMP hash is refused outright (the
    # engine's own `sending` stamp moved the file, and the review binding is
    # exact by design) — and a re-reviewed second click sees the in-flight op
    # rather than claiming a second one. Neither transmits.
    assert {:error, "content_changed"} =
             Engine.send_draft(slug, "reply.md", draft_hash(), fingerprint)

    {:ok, restamped} = Engine.draft_review(slug, "reply.md")

    assert {:ok, "sending"} =
             Engine.send_draft(
               slug,
               "reply.md",
               restamped["content_hash"],
               restamped["review_fingerprint"]
             )

    assert [%{kind: "send"}] = Store.pending_ops(slug)

    # Release the pass; only THEN does the send transmit and file its copy.
    send(pass_pid, {:release, {:error, :done}})
    assert_receive {:connect_called, send_pid}, 2_000
    send(send_pid, {:release, {:ok, send_pid}})

    # It runs to completion exactly once — and the already-answered caller is
    # never replied to a second time.
    wait_until(fn -> queued_send_state(slug) == "complete" end)
    refute_receive {:send_reply, _second}, 200
    assert length(FakeSmtpTransport.calls()) == 1
  end

  # Settings-reload interleave, ordering 1: the reload lands BEFORE the send
  # call, so the restarted Engine holds the new identity and must refuse the
  # fingerprint the human's modal was rendered from.
  test "a review fingerprint from the pre-reload settings is refused after a settings reload", %{
    root: root
  } do
    slug = "mara"
    use_transports!(ModelMailTransport)
    :ok = Settings.upsert_account!(root, slug, smtp_account_attrs("Mara Ito"))

    start_supervised!({MailSupervisor, %{root: root, generation: 1}})
    open(root, 1)
    credential_pair!(slug)

    write_draft!(root, slug, "reply.md", @draft_md)
    {:ok, review} = Engine.draft_review(slug, "reply.md")
    reviewed_fingerprint = review["review_fingerprint"]

    # A second tab changes the sending identity; the engine hot-restarts.
    :ok = Settings.upsert_account!(root, slug, smtp_account_attrs("M. Ito"))
    assert :ok = MailSupervisor.reload_settings_all(root)
    credential_pair!(slug)

    assert {:error, "re_review_required"} =
             Engine.send_draft(slug, "reply.md", draft_hash(), reviewed_fingerprint)

    assert Store.ops_by_origin(slug, "drafts/reply.md") == []
    assert FakeSmtpTransport.calls() == []

    # Re-reviewing under the new identity is all it takes.
    {:ok, fresh} = Engine.draft_review(slug, "reply.md")
    assert fresh["review_fingerprint"] != reviewed_fingerprint
  end

  # Ordering 2: the config file changes with no reload — the Engine still holds
  # the reviewed settings, and the composed message must come from THOSE, never
  # from a re-read of `config/mail.yaml`.
  test "composition uses the Engine's captured settings, not the config file on disk", %{
    root: root
  } do
    slug = "mara"
    name = :"model_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ModelMailTransport.start_link(name: name)
    ModelMailTransport.put_folder(name, "Sent")

    use_transports!(ModelMailTransport)
    FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

    reviewed = %{smtp_settings() | from_name: "Mara Ito"}

    start_engine!(root, 95, slug,
      settings: settings(slug, %{smtp: reviewed}),
      connect_opts: [name: name]
    )

    open(root, 95)
    credential_pair!(slug)

    write_draft!(root, slug, "reply.md", @draft_md)
    {:ok, review} = Engine.draft_review(slug, "reply.md")

    # Another tab rewrites the account's identity on disk. No reload yet.
    :ok = Settings.upsert_account!(root, slug, smtp_account_attrs("Someone Else"))

    assert {:ok, "sent"} =
             Engine.send_draft(slug, "reply.md", draft_hash(), review["review_fingerprint"])

    assert [{:send, [_config, _credential, envelope, data, _opts]}] = FakeSmtpTransport.calls()
    assert envelope.from == "mara@example.com"
    assert data =~ "From: Mara Ito <mara@example.com>"
    refute data =~ "Someone Else"
  end

  # A send can be QUEUED behind a pass and then find the account no longer
  # sendable when the slot frees (here: the pass reports the mailbox was
  # replaced). Dropping the entry silently would strand the op `pending`
  # forever — `recover_sends` deliberately skips `pending`, and the
  # classification pass only runs at activation — with the draft's claim held
  # on the widened outbound index: no Send, no Resolve, stuck on `sending`.
  test "a queued send dropped at drain is terminated, and the draft claims cleanly again", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    use_transports!(Valea.Mail.EngineTest.HangingTransport)
    FakeSmtpTransport.script([{:send, :_, {:ok, :accepted}}])

    slug = "mara"
    start_engine!(root, 97, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 97)
    credential_pair!(slug)

    write_draft!(root, slug, "reply.md", @draft_md)
    {:ok, review} = Engine.draft_review(slug, "reply.md")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}

    test_pid = self()

    spawn(fn ->
      send(
        test_pid,
        {:send_reply,
         Engine.send_draft(slug, "reply.md", draft_hash(), review["review_fingerprint"])}
      )
    end)

    wait_until(fn -> queued_send_state(slug) == "pending" end)
    assert [queued] = Store.ops_by_origin(slug, "drafts/reply.md")

    # Queued, therefore already answered — before the drop is even knowable.
    assert_receive {:send_reply, {:ok, "sending"}}, 1_000

    # The pass comes back mailbox_replaced: the account goes sticky-blocked and
    # the queued send is dropped at drain. The termination still happens (that
    # is the point of the drop); only the second reply is skipped, and the UI
    # learns the outcome from the ledger-derived draft state below.
    send(pass_pid, {:release, {:error, :mailbox_replaced}})
    wait_until(fn -> read_draft_status(root, slug, "reply.md") == "draft" end)
    refute_receive {:send_reply, _second}, 200

    assert {:ok, %{state: "rejected", error: "abandoned_before_transmit"}} =
             Store.op_by_id(queued.id)

    # Provably un-transmitted, and the draft is a draft again.
    assert FakeSmtpTransport.calls() == []
    assert read_draft_status(root, slug, "reply.md") == "draft"
    assert Store.pending_ops(slug) == []

    # ...so once the block is cleared, a fresh click claims and sends normally.
    assert :ok = Engine.readopt(slug)
    {:ok, fresh} = Engine.draft_review(slug, "reply.md")

    spawn(fn ->
      send(
        test_pid,
        {:send_reply,
         Engine.send_draft(slug, "reply.md", fresh["content_hash"], fresh["review_fingerprint"])}
      )
    end)

    assert_receive {:connect_called, send_pid}, 2_000
    send(send_pid, {:release, {:ok, send_pid}})
    assert_receive {:send_reply, {:ok, "sent"}}, 2_000
    assert length(FakeSmtpTransport.calls()) == 1
  end

  # A resolve/retry can be queued behind a pass and then dropped at drain, the
  # same way a send can — but unlike a send it has NO durable half: the
  # executor was never called, so nothing was reviewed and nothing was filed.
  # Answering `:ok` there (the send-side fallback's shape) would have the RPC
  # report `{"resolved" => true}` / `{"retried" => true}` for work that
  # provably did not happen.
  test "a queued resolve/retry dropped at drain is answered honestly, never :ok", %{root: root} do
    Application.put_env(:valea, :engine_sync_probe, self())
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    use_transports!(Valea.Mail.EngineTest.HangingTransport)

    slug = "mara"

    {:ok, parked} =
      Store.create_pending_op(%{
        kind: "send",
        account: slug,
        origin: "drafts/parked.md",
        target_folder: "Sent",
        message_id: "<valea.send.parked@valea.invalid>",
        msg_id: "parked.md",
        state: "send_review"
      })

    {:ok, uncopied} =
      Store.create_pending_op(%{
        kind: "send",
        account: slug,
        origin: "drafts/uncopied.md",
        target_folder: "Sent",
        message_id: "<valea.send.uncopied@valea.invalid>",
        msg_id: "uncopied.md",
        state: "complete",
        error: "sent_copy_failed"
      })

    start_engine!(root, 98, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 98)
    credential_pair!(slug)

    engine = GenServer.whereis(Engine.via(slug))

    # A hung pass holds the single work slot.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}

    test_pid = self()

    spawn(fn ->
      send(test_pid, {:resolve_reply, Engine.resolve_send_review(slug, parked.id, :sent)})
    end)

    spawn(fn -> send(test_pid, {:retry_reply, Engine.retry_sent_copy(slug, uncopied.id)}) end)

    wait_until(fn -> length(:sys.get_state(engine).ops_queue) == 2 end)

    assert [{:resolve, _, :sent}, {:retry, _}] =
             :sys.get_state(engine).ops_queue
             |> Enum.map(& &1.send_work)
             |> Enum.sort_by(&elem(&1, 0))

    # The pass reports mailbox_replaced: the account goes sticky-blocked and
    # BOTH queued entries are dropped at drain, untouched by the executor.
    send(pass_pid, {:release, {:error, :mailbox_replaced}})

    assert_receive {:resolve_reply, {:error, :not_reviewable}}, 2_000
    assert_receive {:retry_reply, {:error, :not_retryable}}, 2_000

    # Proof the executor never ran: a real resolve would have moved the parked
    # op on, and a real retry would have cleared the notice.
    assert {:ok, %{state: "send_review"}} = Store.op_by_id(parked.id)
    assert {:ok, %{state: "complete", error: "sent_copy_failed"}} = Store.op_by_id(uncopied.id)
  end

  # Spec G §Crash recovery: the classification pass runs at ACTIVATION and
  # needs no network at all — a send stranded pre-transmit must not stay
  # blocked behind a paused or failing IMAP sync.
  test "activation classifies a stranded send with no connection whatsoever", %{root: root} do
    slug = "mara"

    {:ok, stranded} =
      Store.create_pending_op(%{
        kind: "send",
        account: slug,
        origin: "drafts/reply.md",
        target_folder: "Sent",
        message_id: "<valea.send.deadbeef@valea.invalid>",
        msg_id: "reply.md",
        state: "pending"
      })

    # No transport, no credential, no server: activation alone must resolve it.
    start_engine!(root, 96, slug, settings: settings(slug, %{smtp: smtp_settings()}))
    open(root, 96)
    # A synchronous call behind the broadcast: activation has finished by the
    # time this returns.
    assert Engine.status(slug).state == "idle"

    assert {:ok, %{state: "rejected", error: "crashed_before_transmit"}} =
             Store.op_by_id(stranded.id)
  end

  # -- IMAP IDLE lifecycle -----------------------------------------------------
  #
  # The watcher's own conversation is covered wire-level in
  # `idle_watcher_test.exs`; what these tests own is the Engine's half — WHEN a
  # watcher exists, and what happens to it when the account's ability to sync
  # changes underneath it. Read off `state.idle_watcher` via `:sys.get_state`
  # (the idiom this file already uses for `poll_timer`/`sync_task`) rather than
  # through new production introspection.

  defp idle_watcher(slug) do
    :sys.get_state(GenServer.whereis(Engine.via(slug))).idle_watcher
  end

  # `config/test.exs` turns IDLE off for every other suite (a second connection
  # through a scripted transport would perturb them); these tests turn it back
  # on and restore the value they found — never `delete_env`, which would leave
  # the production default ON for whatever runs next.
  defp enable_idle! do
    previous = Application.get_env(:valea, :mail_idle)
    Application.put_env(:valea, :mail_idle, true)
    on_exit(fn -> restore_idle_env(previous) end)
  end

  defp restore_idle_env(nil), do: Application.delete_env(:valea, :mail_idle)
  defp restore_idle_env(previous), do: Application.put_env(:valea, :mail_idle, previous)

  defp probe! do
    Application.put_env(:valea, :engine_sync_probe, self())
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
  end

  defp idle_engine!(root, generation, slug) do
    probe!()
    use_transports!(Valea.Mail.EngineTest.IdleTransport)
    start_engine!(root, generation, slug)
    open(root, generation)
  end

  # Releases the watcher's blocked `connect/3` with a working connection, so it
  # goes on to park in IDLE.
  # The generous timeouts on every `{:connect_called, _}` below are deliberate:
  # the connect happens in ANOTHER process (the watcher, or a pass Task), so
  # `assert_receive`'s 100ms default would make these tests hostages to
  # scheduler luck under a loaded suite.
  defp connect_watcher!(watcher) do
    assert_receive {:connect_called, ^watcher}, 2_000
    send(watcher, {:release, {:ok, :idle_conn}})
  end

  test "an activated account with NO credential gets no watcher at all", %{root: root} do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 200, slug)

    # `validate_sync/1` is the whole gate: nothing to connect with, nothing to
    # start. No connection is attempted either.
    assert Engine.status(slug).state == "idle"
    assert idle_watcher(slug) == nil
    refute_received {:connect_called, _pid}
  end

  test "set_credential starts a watcher, which opens its OWN connection", %{root: root} do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 201, slug)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, ref} = idle_watcher(slug)
    assert is_pid(watcher) and is_reference(ref)

    # The connect happens in the WATCHER's process — never in the Engine loop,
    # and never on a sync pass's connection.
    assert_receive {:connect_called, connect_pid}, 2_000
    assert connect_pid == watcher
    send(watcher, {:release, {:ok, :idle_conn}})

    # Parked in IDLE, still alive, and the Engine still answers instantly.
    assert Engine.status(slug).state == "idle"
    assert Process.alive?(watcher)
  end

  test "IDLE needs no configuration: with :mail_idle unset entirely, a watcher still starts", %{
    root: root
  } do
    previous = Application.get_env(:valea, :mail_idle)
    Application.delete_env(:valea, :mail_idle)
    on_exit(fn -> restore_idle_env(previous) end)

    slug = "mara"
    idle_engine!(root, 202, slug)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, _ref} = idle_watcher(slug)
    connect_watcher!(watcher)
  end

  test "rotating the IMAP credential REBUILDS the watcher", %{root: root} do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 203, slug)

    assert :ok = Engine.set_credential(slug, "old-password")
    assert {first, _ref} = idle_watcher(slug)
    connect_watcher!(first)

    # The connection `first` is holding authenticated with the OLD secret, so a
    # rotation cannot leave it running.
    assert :ok = Engine.set_credential(slug, "new-password")
    assert {second, _ref} = idle_watcher(slug)
    refute second == first
    wait_until(fn -> not Process.alive?(first) end)

    # The replacement opens its own connection with the new credential.
    connect_watcher!(second)
  end

  test "a pass reporting auth_failed stops the watcher; a fresh credential brings it back", %{
    root: root
  } do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 204, slug)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, _ref} = idle_watcher(slug)
    connect_watcher!(watcher)

    # The pass's connect is a DIFFERENT process (the pass Task), which is how
    # this test answers the two connections differently.
    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}, 2_000
    refute pass_pid == watcher
    send(pass_pid, {:release, {:error, :auth_failed}})

    wait_until(fn -> Engine.status(slug).state == "auth_failed" end)

    # The credential the watcher is holding is the one that just failed: its own
    # reconnects would hammer the server with the same bad password.
    assert idle_watcher(slug) == nil
    wait_until(fn -> not Process.alive?(watcher) end)

    assert :ok = Engine.set_credential(slug, "new-password")
    assert {revived, _ref} = idle_watcher(slug)
    refute revived == watcher
    connect_watcher!(revived)
  end

  test "a pass reporting mailbox_replaced stops the watcher; readopt brings it back", %{
    root: root
  } do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 207, slug)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, _ref} = idle_watcher(slug)
    connect_watcher!(watcher)

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, pass_pid}, 2_000
    send(pass_pid, {:release, {:error, :mailbox_replaced}})

    wait_until(fn -> Engine.status(slug).state == "mailbox_replaced" end)

    # Sticky-blocked: polling is paused, and an IDLE trigger could only produce
    # passes this Engine refuses to run.
    assert idle_watcher(slug) == nil
    wait_until(fn -> not Process.alive?(watcher) end)

    assert :ok = Engine.readopt(slug)
    assert {revived, _ref} = idle_watcher(slug)
    refute revived == watcher
    connect_watcher!(revived)
  end

  test "stopping the engine takes the watcher down with it", %{root: root} do
    enable_idle!()
    slug = "mara"
    idle_engine!(root, 205, slug)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, _ref} = idle_watcher(slug)
    connect_watcher!(watcher)

    ref = Process.monitor(watcher)
    stop_supervised!(:engine_mara)

    # Through the link on the Engine-owned supervisor — no explicit teardown
    # anywhere, which is the point of hanging it off the Engine.
    assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, 1_000
  end

  test "a watcher that stops itself (server without IDLE) clears the slot and is not replaced", %{
    root: root
  } do
    enable_idle!()
    probe!()
    # `HangingTransport.supports?/2` is `false` for every capability, so the
    # watcher's own capability gate takes the clean-exit path.
    use_transports!(Valea.Mail.EngineTest.HangingTransport)

    slug = "mara"
    start_engine!(root, 206, slug)
    open(root, 206)

    assert :ok = Engine.set_credential(slug, "app-password")
    assert {watcher, _ref} = idle_watcher(slug)
    connect_watcher!(watcher)

    wait_until(fn -> not Process.alive?(watcher) end)
    # The monitor is what tells the Engine; nothing re-races a server whose
    # answer cannot change.
    wait_until(fn -> idle_watcher(slug) == nil end)
    refute_receive {:connect_called, _pid}, 100

    # And the account is otherwise untouched — still idle, still polling.
    assert Engine.status(slug).state == "idle"
  end

  # -- OAuth2: authorization flow, minting, single-flight (M6 task 16) --------

  @oauth_client "valea-test.apps.googleusercontent.com"

  defp oauth_settings(slug, overrides \\ %{}) do
    settings(
      slug,
      Map.merge(
        %{
          provider: :gmail,
          auth: :oauth2,
          oauth_client_id: @oauth_client,
          imap: %{host: "imap.gmail.com", port: 993, username: "#{slug}@gmail.com"}
        },
        overrides
      )
    )
  end

  defp start_oauth_engine!(root, generation, slug, overrides \\ %{}) do
    start_engine!(root, generation, slug, settings: oauth_settings(slug, overrides))
    open(root, generation)
    GenServer.whereis(Engine.via(slug))
  end

  # Scripts the token endpoint. `reply` is either a literal answer or
  # `{:block, probe}`, in which case the fake POST announces itself and waits —
  # which is what lets a test observe a refresh WHILE it is in flight.
  defp stub_token_endpoint!(reply) do
    probe = self()

    Application.put_env(:valea, :mail_oauth_http_post, fn _url, body ->
      send(probe, {:token_post, self(), IO.iodata_to_binary(body)})

      case reply do
        :block -> receive do: ({:release, answer} -> answer)
        answer -> answer
      end
    end)

    on_exit(fn -> Application.delete_env(:valea, :mail_oauth_http_post) end)
  end

  defp token_reply(fields) do
    {:ok, 200,
     Jason.encode!(Map.merge(%{"access_token" => "at-1", "expires_in" => 3600}, fields))}
  end

  test "an oauth2 account with no refresh token has NO credential, and cannot sync", %{root: root} do
    slug = "mara"
    start_oauth_engine!(root, 300, slug)

    status = Engine.status(slug)
    assert status.auth == "oauth2"
    assert status.credential == "missing"
    assert Engine.sync_now(slug) == {:error, :no_credential}

    # The PASSWORD slot is not this account's credential: filling it changes
    # nothing about whether it can sync.
    assert :ok = Engine.set_credential(slug, "a-password")
    assert Engine.status(slug).credential == "missing"
    assert Engine.sync_now(slug) == {:error, :no_credential}

    # The oauth slot is.
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    assert Engine.status(slug).credential == "present"
  end

  test "a password account still reports auth: password", %{root: root} do
    start_engine!(root, 301, "mara")
    open(root, 301)
    assert Engine.status("mara").auth == "password"
  end

  test "the credential closure handed to a pass resolves to the MINTED access token", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.CredentialProbeTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.MINTED"}))

    slug = "mara"
    start_oauth_engine!(root, 302, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)

    assert :ok = Engine.sync_now(slug)

    # The whole point of the closure contract: the worker asked for a secret at
    # its connect boundary and got a token the Engine minted for it, with
    # nothing in `SyncPass` aware that a refresh happened.
    assert_receive {:connect_credential, "ya29.MINTED"}, 2_000
    assert_receive {:token_post, _pid, body}
    params = URI.decode_query(body)
    assert params["grant_type"] == "refresh_token"
    assert params["refresh_token"] == "refresh-1"
    assert params["client_id"] == @oauth_client
  end

  test "N concurrent token requests produce exactly ONE refresh, and every caller is served", %{
    root: root
  } do
    stub_token_endpoint!(:block)

    slug = "mara"
    engine = start_oauth_engine!(root, 303, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)

    callers = for _ <- 1..6, do: Task.async(fn -> Engine.mint_access_token(engine) end)

    assert_receive {:token_post, poster, _body}, 2_000
    # THE single-flight assertion: five more callers arrived behind the first
    # and none of them started a second token request.
    refute_receive {:token_post, _pid, _body}, 200

    send(poster, {:release, token_reply(%{"access_token" => "ya29.ONE"})})

    assert Enum.map(callers, &Task.await(&1, 2_000)) == List.duplicate("ya29.ONE", 6)
    # ...and still only one.
    refute_receive {:token_post, _pid, _body}, 100
  end

  test "a cached token is reused until it nears expiry, then re-minted", %{root: root} do
    # 30s of life is inside the 60s refresh skew, so this token is never
    # handed out at all — a session opened with it could outlive it.
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.SHORT", "expires_in" => 30}))

    slug = "mara"
    engine = start_oauth_engine!(root, 304, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)

    assert Engine.mint_access_token(engine) == "ya29.SHORT"
    assert_receive {:token_post, _pid, _body}
    assert Engine.mint_access_token(engine) == "ya29.SHORT"
    assert_receive {:token_post, _pid, _body}

    # A long-lived one is cached: the second mint costs no request.
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.LONG"}))
    assert :ok = Engine.set_credential(slug, "refresh-2", :oauth)
    assert Engine.mint_access_token(engine) == "ya29.LONG"
    assert_receive {:token_post, _pid, _body}
    assert Engine.mint_access_token(engine) == "ya29.LONG"
    refute_receive {:token_post, _pid, _body}, 100
  end

  test "a new refresh token drops the cached access token minted from the old one", %{root: root} do
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.FIRST"}))

    slug = "mara"
    engine = start_oauth_engine!(root, 305, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    assert Engine.mint_access_token(engine) == "ya29.FIRST"
    assert_receive {:token_post, _pid, _first_body}

    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.SECOND"}))
    assert :ok = Engine.set_credential(slug, "refresh-2", :oauth)

    assert Engine.mint_access_token(engine) == "ya29.SECOND"
    assert_receive {:token_post, _pid, body}
    assert URI.decode_query(body)["refresh_token"] == "refresh-2"
  end

  test "invalid_grant clears the cache AND the refresh token, and parks reauth_required", %{
    root: root
  } do
    stub_token_endpoint!({:ok, 400, Jason.encode!(%{"error" => "invalid_grant"})})
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    slug = "mara"
    engine = start_oauth_engine!(root, 306, slug)
    assert :ok = Engine.set_credential(slug, "revoked-refresh", :oauth)
    assert Engine.status(slug).credential == "present"

    # The contract holds even here: the caller gets a binary, not a raise.
    assert Engine.mint_access_token(engine) == ""

    status = Engine.status(slug)
    assert status.state == "reauth_required"
    assert status.last_error == "sign-in expired"
    assert status.credential == "missing"

    state = :sys.get_state(engine)
    assert state.oauth_refresh == nil
    assert state.oauth_token == nil
    assert state.poll_timer == nil

    # Sticky, exactly like a refused password...
    send(engine, :poll)
    assert %{poll_timer: nil} = :sys.get_state(engine)

    # ...and a new sign-in clears it.
    stub_token_endpoint!(token_reply(%{}))
    assert :ok = Engine.set_credential(slug, "fresh-refresh", :oauth)
    assert Engine.status(slug).state == "idle"
    assert :sys.get_state(engine).poll_timer != nil
  end

  test "a TRANSIENT token failure keeps the refresh token and never parks the account", %{
    root: root
  } do
    stub_token_endpoint!(:error)

    slug = "mara"
    engine = start_oauth_engine!(root, 307, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)

    assert Engine.mint_access_token(engine) == ""

    status = Engine.status(slug)
    # The token endpoint being unreachable says NOTHING about the sign-in.
    assert status.state == "idle"
    assert status.credential == "present"
    assert :sys.get_state(engine).oauth_refresh != nil
  end

  test "a ROTATED refresh token replaces the stored one and is pushed for the keychain", %{
    root: root
  } do
    stub_token_endpoint!(token_reply(%{"refresh_token" => "rotated-refresh"}))
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    slug = "mara"

    engine =
      start_oauth_engine!(root, 308, slug, %{
        provider: :microsoft,
        imap: %{host: "outlook.office365.com", port: 993, username: "mara@contoso.com"}
      })

    assert :ok = Engine.set_credential(slug, "original-refresh", :oauth)
    assert Engine.mint_access_token(engine) == "at-1"

    # Without this push the keychain keeps a token Microsoft has already
    # invalidated, and the next restart resupplies a dead one.
    assert_receive {:mail_oauth_token, ^slug, "rotated-refresh"}
    assert :sys.get_state(engine).oauth_refresh.() == "rotated-refresh"
  end

  test "store_oauth_refresh_token stores AND pushes; a plain resupply only stores", %{root: root} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    slug = "mara"
    engine = start_oauth_engine!(root, 309, slug)

    assert :ok = Engine.store_oauth_refresh_token(slug, "authorized-refresh")
    assert_receive {:mail_oauth_token, ^slug, "authorized-refresh"}
    assert :sys.get_state(engine).oauth_refresh.() == "authorized-refresh"

    # The restart path hands back what the keychain already holds — there is
    # nothing new for the client to persist.
    assert :ok = Engine.set_credential(slug, "resupplied-refresh", :oauth)
    refute_receive {:mail_oauth_token, _slug, _token}, 100
    assert :sys.get_state(engine).oauth_refresh.() == "resupplied-refresh"
  end

  test "no secret reaches last_error or the log when a token-bearing connect fails", %{root: root} do
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.LeakyConnectTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.LEAKY-TOKEN-VALUE"}))
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    slug = "mara"
    start_oauth_engine!(root, 310, slug)
    assert :ok = Engine.set_credential(slug, "refresh-secret-value", :oauth)

    log =
      capture_log(fn ->
        assert :ok = Engine.sync_now(slug)
        assert_receive {:mail_sync_finished, ^slug, %{errors: [error]}}, 2_000
        refute error =~ "ya29.LEAKY-TOKEN-VALUE"
        refute error =~ "refresh-secret-value"
      end)

    refute log =~ "ya29.LEAKY-TOKEN-VALUE"
    refute log =~ "refresh-secret-value"
    status = Engine.status(slug)
    refute status.last_error =~ "ya29.LEAKY-TOKEN-VALUE"
  end

  # -- the spans-tasks hazard: a stale pass must not park a fresh credential ---

  test "an auth failure from a pass whose credential was REPLACED mid-flight does not go sticky",
       %{root: root} do
    # The hazard (task 15 review, spans-tasks): `set_credential/3` cannot clear
    # a failure that hasn't happened yet, so before the credential epoch this
    # sequence left the account sticky `auth_failed` WITH the fresh secret
    # already in its slot, and nothing re-armed until another
    # `set_credential/3`. Engine-minted tokens make it routine.
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    start_engine!(root, 311, "mara")
    open(root, 311)
    :ok = Engine.set_credential("mara", "stale-password")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now("mara")
    assert_receive {:connect_called, task_pid}

    # The user re-types their password while the doomed pass is still running.
    assert :ok = Engine.set_credential("mara", "fresh-password")

    send(task_pid, {:release, {:error, :auth_failed}})
    assert_receive {:mail_sync_finished, "mara", %{errors: ["authentication failed"]}}

    status = Engine.status("mara")
    # Reported, not acted on: the verdict was about the OLD password.
    assert status.last_error == "authentication failed"
    assert status.state == "idle"
    assert status.credential == "present"

    # And polling is armed, so the fresh password is actually tried.
    assert :sys.get_state(GenServer.whereis(Engine.via("mara"))).poll_timer != nil
  end

  test "a reauth_required from a pass that ran on an UNMINTABLE token does not go sticky", %{
    root: root
  } do
    # The oauth2 shape of the same hazard: the token endpoint was briefly
    # unreachable, so the pass connected with `""` and the server refused it.
    # That refusal is about an empty string this Engine never stood behind.
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    stub_token_endpoint!(:error)

    slug = "mara"
    engine = start_oauth_engine!(root, 312, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, task_pid}, 2_000
    send(task_pid, {:release, {:error, :reauth_required}})

    assert_receive {:mail_sync_finished, ^slug, %{errors: ["sign-in expired"]}}

    status = Engine.status(slug)
    assert status.state == "idle"
    assert status.credential == "present"
    assert :sys.get_state(engine).poll_timer != nil
  end

  test "an invalid_grant park is NOT undone by the stale pass it caused", %{root: root} do
    # `invalid_grant` parks the account directly, mid-pass; the pass then fails
    # auth with the `""` it was handed and its epoch is stale. The stale
    # classification must leave the park alone rather than reset it to idle.
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    stub_token_endpoint!({:ok, 400, Jason.encode!(%{"error" => "invalid_grant"})})

    slug = "mara"
    engine = start_oauth_engine!(root, 313, slug)
    assert :ok = Engine.set_credential(slug, "revoked", :oauth)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, task_pid}, 2_000
    send(task_pid, {:release, {:error, :reauth_required}})

    assert_receive {:mail_sync_finished, ^slug, %{errors: ["sign-in expired"]}}

    assert Engine.status(slug).state == "reauth_required"
    assert %{poll_timer: nil, sync_task: nil} = :sys.get_state(engine)
  end

  test "a sign-in re-arms polling after a park was un-parked by a pass that finished OK", %{
    root: root
  } do
    # The dead-backstop sequence (M6 task 16 review). `park_reauth_required/1`
    # cancels the poll timer without touching `sync_task` — a pass may be in
    # flight — and that pass can then SUCCEED, because it authenticated before
    # the refresh token was revoked and its connection is still good.
    # `finish_pass/2`'s ok-clause puts the status back to "idle" and re-arms
    # nothing, so the account ends up un-parked AND timerless, with
    # `set_credential/3`'s `clear_auth_failure/1` finding nothing to clear.
    # Before `rearm_stopped_poll/1` that account never polled again until the
    # app restarted.
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)

    # Deliberately short-lived: the PASS mints its token from this stub, and
    # every later mint has to go back to the endpoint (the cache sits inside
    # `@token_skew_ms` of expiry) — which is what lets the revocation below
    # land while the pass is still connected on the token it already has.
    stub_token_endpoint!(token_reply(%{"expires_in" => 30}))

    slug = "mara"
    engine = start_oauth_engine!(root, 324, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, task_pid}, 2_000

    # The provider revokes the refresh token mid-pass: the next mint comes back
    # `invalid_grant`, which parks the account right here.
    stub_token_endpoint!({:ok, 400, Jason.encode!(%{"error" => "invalid_grant"})})
    assert Engine.mint_access_token(engine) == ""
    assert Engine.status(slug).state == "reauth_required"
    assert :sys.get_state(engine).poll_timer == nil

    # The in-flight pass finishes fine on its already-authenticated connection,
    # which un-parks the account — and leaves it with no timer at all.
    send(task_pid, {:release, {:ok, :conn}})
    # `errors: []` is the point: this is `finish_pass/2`'s OK clause, not one
    # of the failure clauses that pause or re-arm on their own.
    assert_receive {:mail_sync_finished, ^slug, %{errors: []}}, 2_000
    assert Engine.status(slug).state == "idle"
    assert :sys.get_state(engine).poll_timer == nil

    # The user signs in again. THIS is where the backstop has to come back:
    # the account is "idle", so nothing else in `set_credential/3` would.
    stub_token_endpoint!(token_reply(%{}))
    assert :ok = Engine.set_credential(slug, "refresh-2", :oauth)
    assert Engine.status(slug).state == "idle"
    assert :sys.get_state(engine).poll_timer != nil
  end

  test "an authoritative auth failure is STILL sticky (the guard is not a blanket pardon)", %{
    root: root
  } do
    Application.put_env(:valea, :engine_sync_probe, self())
    Application.put_env(:valea, :mail_transport, Valea.Mail.EngineTest.HangingTransport)
    on_exit(fn -> Application.delete_env(:valea, :mail_transport) end)
    on_exit(fn -> Application.delete_env(:valea, :engine_sync_probe) end)
    stub_token_endpoint!(token_reply(%{}))

    slug = "mara"
    engine = start_oauth_engine!(root, 314, slug)
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")

    assert :ok = Engine.sync_now(slug)
    assert_receive {:connect_called, task_pid}, 2_000
    # Nothing touched the credential: a successfully minted token was refused,
    # which means the sign-in really is no good.
    send(task_pid, {:release, {:error, :reauth_required}})

    assert_receive {:mail_sync_finished, ^slug, %{errors: ["sign-in expired"]}}
    assert Engine.status(slug).state == "reauth_required"
    assert %{poll_timer: nil} = :sys.get_state(engine)
  end

  # -- start_oauth / claim_oauth_flow ------------------------------------------

  test "start_oauth mints a consent URL and parks exactly one pending flow", %{root: root} do
    slug = "mara"
    engine = start_oauth_engine!(root, 315, slug)

    assert {:ok, url} = Engine.start_oauth(slug)
    assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["client_id"] == @oauth_client
    assert query["redirect_uri"] == "http://127.0.0.1:4002/oauth/callback"
    assert query["code_challenge_method"] == "S256"
    assert query["login_hint"] == "mara@gmail.com"

    pending = :sys.get_state(engine).oauth_pending
    assert pending.state == query["state"]
    # The CHALLENGE travels; the verifier stays here.
    assert Valea.Mail.OAuth.challenge_for(pending.verifier) == query["code_challenge"]
    refute String.contains?(url, pending.verifier)

    # A second start replaces the first rather than adding a second live state.
    assert {:ok, _second} = Engine.start_oauth(slug)
    replaced = :sys.get_state(engine).oauth_pending
    refute replaced.state == pending.state
    assert Engine.claim_oauth_flow(pending.state) == {:error, :no_flow}
  end

  test "start_oauth refuses an account that is not an oauth2 account", %{root: root} do
    start_engine!(root, 316, "mara")
    open(root, 316)
    assert Engine.start_oauth("mara") == {:error, :not_oauth}
  end

  test "start_oauth refuses a host with no provider preset", %{root: root} do
    slug = "mara"

    start_oauth_engine!(root, 317, slug, %{
      provider: :generic,
      oauth_client_id: nil,
      imap: %{host: "imap.fastmail.com", port: 993, username: "mara@fastmail.com"}
    })

    assert Engine.start_oauth(slug) == {:error, :oauth_unsupported}
  end

  test "start_oauth refuses when no client id is configured anywhere", %{root: root} do
    previous = Application.get_env(:valea, :mail_oauth)
    Application.put_env(:valea, :mail_oauth, gmail: [client_id: nil])
    on_exit(fn -> Application.put_env(:valea, :mail_oauth, previous) end)

    slug = "mara"
    start_oauth_engine!(root, 318, slug, %{oauth_client_id: nil})
    assert Engine.start_oauth(slug) == {:error, :oauth_not_configured}
  end

  test "start_oauth on an unknown slug is :not_found" do
    assert Engine.start_oauth("nobody") == {:error, :not_found}
  end

  test "a claimed flow is single-use, and a mismatched state finds nothing", %{root: root} do
    slug = "mara"
    engine = start_oauth_engine!(root, 319, slug)
    assert {:ok, _url} = Engine.start_oauth(slug)
    state_token = :sys.get_state(engine).oauth_pending.state

    assert Engine.claim_oauth_flow("not-the-state") == {:error, :no_flow}
    # A miss leaves the flow intact — a guess must not be able to burn it.
    assert :sys.get_state(engine).oauth_pending != nil

    assert {:ok, flow} = Engine.claim_oauth_flow(state_token)
    assert flow.account == slug
    assert flow.provider == :gmail
    assert flow.client_id == @oauth_client
    assert flow.redirect_uri == "http://127.0.0.1:4002/oauth/callback"
    assert is_binary(flow.verifier)
    # The state token does not travel onward with the flow.
    refute Map.has_key?(flow, :state)

    # Replayed: consumed.
    assert Engine.claim_oauth_flow(state_token) == {:error, :no_flow}
    assert :sys.get_state(engine).oauth_pending == nil
  end

  test "an expired flow is refused AND consumed", %{root: root} do
    slug = "mara"
    engine = start_oauth_engine!(root, 320, slug)
    assert {:ok, _url} = Engine.start_oauth(slug)

    # Age the pending flow past its TTL rather than waiting ten minutes for it.
    # `oauth_pending`'s shape is documented in `Engine.init/1`. Relative to
    # `System.monotonic_time/1`, whose zero point is arbitrary (and negative on
    # a fresh BEAM) — a literal `-1` would still be in the future.
    :sys.replace_state(engine, fn state ->
      aged = System.monotonic_time(:millisecond) - 1
      %{state | oauth_pending: %{state.oauth_pending | expires_at: aged}}
    end)

    state_token = :sys.get_state(engine).oauth_pending.state
    assert Engine.claim_oauth_flow(state_token) == {:error, :expired}
    assert :sys.get_state(engine).oauth_pending == nil
  end

  test "a state token is redeemable only against the account that minted it", %{root: root} do
    mara = start_oauth_engine!(root, 321, "mara")

    start_engine!(root, 321, "other", settings: oauth_settings("other"))
    other = GenServer.whereis(Engine.via("other"))

    assert {:ok, _url} = Engine.start_oauth("mara")
    assert {:ok, _url} = Engine.start_oauth("other")

    mara_state = :sys.get_state(mara).oauth_pending.state
    other_state = :sys.get_state(other).oauth_pending.state

    assert {:ok, %{account: "mara"}} = Engine.claim_oauth_flow(mara_state)
    # The other account's flow is untouched by its sibling's redemption.
    assert :sys.get_state(other).oauth_pending != nil
    assert {:ok, %{account: "other"}} = Engine.claim_oauth_flow(other_state)
  end

  # -- the other two consumers of the minting closure --------------------------

  test "the IDLE watcher's credential closure MINTS, so an expiring token is recoverable", %{
    root: root
  } do
    # A watcher holds one long-lived connection; its token WILL expire during
    # that session. What makes that survivable is that the closure it was handed
    # mints on every call, so its own reconnect gets a fresh token — a token
    # resolved once at start would strand it (see `IdleWatcher`'s §Credential).
    enable_idle!()
    probe!()
    use_transports!(Valea.Mail.EngineTest.IdleTransport)
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.WATCHER"}))

    slug = "mara"
    start_engine!(root, 322, slug, settings: oauth_settings(slug))
    open(root, 322)

    # No refresh token yet, so no watcher: `validate_sync/1` is the whole gate.
    assert idle_watcher(slug) == nil

    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)
    assert {watcher, _ref} = idle_watcher(slug)

    assert_receive {:connect_credential, "ya29.WATCHER"}, 2_000
    connect_watcher!(watcher)
  end

  test "the doctor's ctx carries the minting closure, callable from a FOREIGN process", %{
    root: root
  } do
    # `Engine.doctor/1` runs the probing in the CALLER's process, so the closure
    # built in `doctor_ctx/1` is resolved outside the Engine — the one consumer
    # that isn't a Task the Engine spawned. Exercised through `:doctor_ctx`
    # rather than `Engine.doctor/1` so the assertion needs no network.
    stub_token_endpoint!(token_reply(%{"access_token" => "ya29.DOCTOR"}))

    slug = "mara"
    engine = start_oauth_engine!(root, 323, slug, %{smtp: smtp_settings()})
    assert :ok = Engine.set_credential(slug, "refresh-1", :oauth)

    ctx = GenServer.call(engine, :doctor_ctx)

    assert is_function(ctx.credential, 0)
    assert ctx.credential.() == "ya29.DOCTOR"
    # ONE authorization covers both protocols: the send side resolves to the
    # very same token, from the cache the first call filled.
    assert ctx.smtp_credential.() == "ya29.DOCTOR"
    assert_receive {:token_post, _pid, _body}
    refute_receive {:token_post, _pid, _body}, 100
  end
end
