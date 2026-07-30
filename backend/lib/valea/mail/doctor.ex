defmodule Valea.Mail.Doctor do
  @moduledoc """
  Connection preflight for the mail account (mail design spec, §Account
  setup + doctor). Same shape and spirit as `Valea.Agents.Doctor` — a fixed
  list of checks, each with a status and a copyable remedy — but this
  pipeline is *sequential*: later checks build on earlier ones (you can't
  probe TCP reachability without a host, can't log in without a reachable
  server, can't list folders without being logged in), so a failure
  anywhere in the chain marks every check after it `"unknown"` rather than
  attempting (and misreporting on) work that cannot meaningfully run.

  Check ids, in order:

    1. `config_present` — is `config/mail.yaml` configured (loaded
       `Settings`, handed in via `ctx.settings`)?
    2. `credential_present` — is a credential held in RAM (`ctx.credential`)?
       Gated on 1.
    3. `maildir_writable` — can this account's local maildir tree
       (`sources/mail/<account>/maildir/`) actually be written to? `mkdir -p`
       it, then write + remove a small probe file. Gated on 1 (needs
       `ctx.account` to build the path; independent of the credential — this
       is a LOCAL filesystem check, no network/server involved at all).
    4. `tcp_reachable` — a raw `:gen_tcp.connect/4` probe (no TLS, no
       login), 5s timeout. Gated on 1 + 2.
    5. `tls_ok` + `login_ok` + `folders` + `move_capability` — derived from
       ONE `ctx.transport.connect/3` call, gated on 4:
       * `tls_ok` is `"ok"` whenever the connect got far enough to
         AUTHENTICATE (i.e. it returned `{:ok, _}` or specifically
         `{:error, :auth_failed}` / `{:error, :reauth_required}` — the
         credential is only ever offered over the TLS layer, so either
         rejection proves the layer came up); any other connect error means
         the client never got a working transport layer, so `tls_ok` is
         `"failed"` and `login_ok`/`folders`/`move_capability` are
         `"unknown"` (the login was never attempted).
       * `login_ok` is `"ok"` on `{:ok, conn}` and `"failed"` on either
         rejection — `{:error, :auth_failed}` (a refused password) or
         `{:error, :reauth_required}` (a refused OAuth2 token, M6 task 15,
         whose remedy is a reconnect rather than a re-typed password) — and
         is gated on `tls_ok`.
       * `folders` (`ctx.transport.list_folders/1`) and `move_capability`
         (`ctx.transport.capabilities/1`) are siblings computed off the
         same live `conn` once `login_ok` is `"ok"` — one's result never
         gates the other.
    6. `smtp_tcp` + `smtp_tls` + `smtp_auth` — appended ONLY for a sending
       account (`ctx.settings.smtp` present; a push-only account's report
       is exactly the eight checks above, unchanged). Same sequential
       shape one protocol over: a raw TCP probe of the submission host,
       then `smtp_tls`/`smtp_auth` derived from ONE
       `ctx.smtp_transport.check_auth/3` call gated on it — one session,
       because some providers rate-limit AUTH, and `check_auth/3` never
       issues `MAIL FROM`, so running the doctor can never enqueue a
       message. A missing SMTP credential fails `smtp_auth` with the
       resupply remedy rather than opening a session that cannot succeed.

  `run/1` never raises: every transport call is caught, and an unexpected
  crash anywhere in the pipeline becomes a `"failed"` check with the
  exception message, never an exception that reaches the caller. The
  credential is a zero-arity closure (or a raw secret in a hand-built test
  ctx) dereferenced ONLY at the `connect/3` boundary, exactly like
  `SyncPass` — no check's `detail`/`remedy` string ever interpolates it.
  """

  alias Valea.Mail.Redact
  alias Valea.Mail.Settings

  @type check :: %{String.t() => String.t() | nil}

  @type ctx :: %{
          root: String.t(),
          account: String.t(),
          settings: Valea.Mail.Settings.t() | nil,
          credential: (-> String.t()) | String.t() | nil,
          transport: module(),
          smtp_credential: (-> String.t()) | String.t() | nil,
          smtp_transport: module()
        }

  @gen_tcp_timeout_ms 5_000

  @gate_detail "not checked — an earlier check failed."

  @config_remedy "Set up your mail account (host, port, username) in Mail settings."
  @credential_remedy "Enter your mailbox password to connect."
  # The oauth2 counterpart (M6 task 16): there is no password to type for one
  # of these accounts, and telling the user to enter one sends them looking
  # for a field the setup form deliberately hides.
  @signin_remedy "Sign in to this mailbox from Mail settings to connect."
  @maildir_remedy "Check filesystem permissions for this workspace's sources/mail/ directory."
  @tcp_remedy "Check the host and port, and your network connection."
  @tls_remedy "Confirm the host/port support implicit TLS (IMAPS, usually port 993)."
  @login_remedy "Double-check the mailbox username and password."
  @reauth_remedy "This account signs in with OAuth, and its sign-in has expired — " <>
                   "reconnect the account to refresh it."
  @folders_transport_remedy "Check server connectivity and try again."
  @move_remedy "Your server supports neither MOVE nor UIDPLUS — " <>
                 "move ops will be rejected; flags and draft pushes still work."

  @smtp_tcp_remedy "Check the SMTP host and port (587 for STARTTLS, 465 for TLS), " <>
                     "and your network connection."
  @smtp_tls_remedy "Confirm the SMTP port and security mode — 587 is STARTTLS, " <>
                     "465 is implicit TLS. Valea never sends without verified TLS."
  @smtp_auth_remedy "Double-check the SMTP username and password."
  @smtp_credential_remedy "Enter your SMTP password to send mail from this account."

  @doc """
  Runs the full check pipeline against `ctx`. Always succeeds — the
  returned `ok:` flag (not an `:error` tuple) is how a caller learns
  whether anything is wrong; see the moduledoc for the "unknown" gating
  rule.
  """
  @spec run(ctx()) :: {:ok, %{checks: [check()], ok: boolean}}
  def run(ctx) do
    {config, config_ok?} = config_present(ctx)
    {credential, credential_ok?} = credential_present(ctx, config_ok?)
    {maildir, _maildir_ok?} = maildir_writable(ctx, config_ok?)
    {tcp, tcp_ok?} = tcp_reachable(ctx, config_ok? and credential_ok?)
    {tls, login, folders, move} = transport_group(ctx, tcp_ok?)

    checks = [config, credential, maildir, tcp, tls, login, folders, move] ++ smtp_checks(ctx)
    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  @doc """
  Connects and creates whichever of the account's four configured special
  folders (`ctx.settings.folders` — drafts/sent/archive/trash) are missing
  on the server — the doctor panel's "Create folders" action. `[Gmail]/*`
  names are never created (see `creatable_folder?/1`: Gmail system folders
  exist only when the account really is Gmail; a plain folder with that
  name wouldn't be special). Returns the folder names actually created; a
  folder whose `create_folder` call itself fails is silently left out of
  that list (the doctor's next run will still report it missing). A
  connect failure is returned as `{:error, reason}` — nothing to create
  without a connection. The reason passes through untouched unless it
  embeds the raw credential, in which case it is stringified with the
  secret scrubbed (same redaction posture as `run/1`'s tls_ok check; this
  error reaches RPC/UI consumers).
  """
  @spec create_folders(ctx()) :: {:ok, [String.t()]} | {:error, term()}
  def create_folders(%{settings: %{} = settings, transport: transport} = ctx) do
    # Same once-at-the-connect-boundary resolution as `transport_group/2`,
    # for the same reason: the connect error's reason term is the one value
    # here that could conceivably embed the secret, and it flows out of
    # this function to callers outside this module.
    secret = resolve_credential(ctx[:credential])

    case do_connect(transport, Settings.imap_config(settings), secret) do
      {:ok, conn} ->
        created = create_missing_special_folders(transport, conn, settings.folders)
        safe_logout(transport, conn)
        {:ok, created}

      {:error, reason} ->
        {:error, Redact.reason(reason, secret)}
    end
  end

  # -- 1. config_present ------------------------------------------------------

  defp config_present(%{settings: nil}) do
    {failed(
       "config_present",
       "Mail account configured",
       "config/mail.yaml is missing or not yet configured.",
       @config_remedy
     ), false}
  end

  defp config_present(%{settings: %{imap: imap}}) do
    {ok(
       "config_present",
       "Mail account configured",
       "config/mail.yaml is configured for #{imap.username}@#{imap.host}."
     ), true}
  end

  # -- 2. credential_present ----------------------------------------------------

  # The label and remedy follow the account's AUTH MODE: an `auth: oauth2`
  # account has no password anywhere in the picture — its credential is a
  # sign-in — so reporting "Password available" for it, with a remedy naming a
  # field the setup form hides for oauth accounts, is simply untrue.
  defp credential_present(ctx, false) do
    {unknown("credential_present", credential_label(ctx), @gate_detail), false}
  end

  defp credential_present(%{credential: nil} = ctx, true) do
    {failed(
       "credential_present",
       credential_label(ctx),
       credential_missing_detail(ctx),
       credential_missing_remedy(ctx)
     ), false}
  end

  defp credential_present(ctx, true) do
    {ok("credential_present", credential_label(ctx), credential_present_detail(ctx)), true}
  end

  defp oauth_account?(%{settings: %{auth: :oauth2}}), do: true
  defp oauth_account?(_ctx), do: false

  defp credential_label(ctx),
    do: if(oauth_account?(ctx), do: "Sign-in available", else: "Password available")

  defp credential_missing_detail(ctx) do
    if oauth_account?(ctx),
      do: "This account has not been signed in yet.",
      else: "No mailbox password has been provided yet."
  end

  defp credential_missing_remedy(ctx),
    do: if(oauth_account?(ctx), do: @signin_remedy, else: @credential_remedy)

  defp credential_present_detail(ctx) do
    if oauth_account?(ctx),
      do: "A sign-in is available; access tokens are renewed automatically.",
      else: "A mailbox password is available."
  end

  # -- 3. maildir_writable --------------------------------------------------

  # Gated on config_present alone (needs `ctx.account`/`ctx.root` to build the
  # path) — deliberately independent of the credential: this is a pure LOCAL
  # filesystem probe, no network/server involved, so there's no reason to
  # withhold it just because a password hasn't been entered yet.
  defp maildir_writable(_ctx, false) do
    {unknown("maildir_writable", "Local maildir writable", @gate_detail), false}
  end

  defp maildir_writable(%{root: root, account: account}, true) do
    dir = Path.join([root, "sources", "mail", account, "maildir"])
    probe = Path.join(dir, ".doctor-probe-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, "ok") do
      File.rm(probe)
      {ok("maildir_writable", "Local maildir writable", "#{dir} is writable."), true}
    else
      {:error, reason} ->
        {failed(
           "maildir_writable",
           "Local maildir writable",
           "Could not write to #{dir}: #{inspect(reason)}",
           @maildir_remedy
         ), false}
    end
  rescue
    e ->
      {failed(
         "maildir_writable",
         "Local maildir writable",
         Exception.message(e),
         @maildir_remedy
       ), false}
  catch
    kind, reason ->
      {failed(
         "maildir_writable",
         "Local maildir writable",
         inspect({kind, reason}),
         @maildir_remedy
       ), false}
  end

  # -- 4. tcp_reachable ----------------------------------------------------------

  defp tcp_reachable(_ctx, false) do
    {unknown("tcp_reachable", "Server reachable", @gate_detail), false}
  end

  defp tcp_reachable(%{settings: %{imap: %{host: host, port: port}}}, true) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], @gen_tcp_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        {ok(
           "tcp_reachable",
           "Server reachable",
           "Connected to #{host}:#{port} over TCP."
         ), true}

      {:error, reason} ->
        {failed(
           "tcp_reachable",
           "Server reachable",
           "Could not open a TCP connection to #{host}:#{port}: #{inspect(reason)}",
           @tcp_remedy
         ), false}
    end
  rescue
    e ->
      {failed("tcp_reachable", "Server reachable", Exception.message(e), @tcp_remedy), false}
  catch
    kind, reason ->
      {failed("tcp_reachable", "Server reachable", inspect({kind, reason}), @tcp_remedy), false}
  end

  # -- 5. tls_ok / login_ok / folders / move_capability (one connect) -----------

  defp transport_group(_ctx, false) do
    {unknown("tls_ok", "TLS", @gate_detail), unknown("login_ok", "Login", @gate_detail),
     unknown("folders", "Folders", @gate_detail),
     unknown("move_capability", "Move capability", @gate_detail)}
  end

  defp transport_group(%{settings: %{imap: imap} = settings} = ctx, true) do
    # Resolved exactly once, right at this connect boundary (never earlier,
    # never logged) — and reused below to scrub the raw secret out of a
    # connect error's `inspect/1`'d reason before it ever reaches a check's
    # `detail` string. Realistically no transport error embeds the
    # credential, but the check builder has no way to know that in general,
    # so this is a belt-and-suspenders egress filter, not a load-bearing one.
    secret = resolve_credential(ctx[:credential])

    case do_connect(ctx.transport, Settings.imap_config(settings), secret) do
      {:ok, conn} ->
        tls = ok("tls_ok", "TLS", "TLS handshake succeeded.")
        login = ok("login_ok", "Login", "Logged in as #{imap.username}.")
        folders = folders_check(ctx, conn)
        move = move_capability_check(ctx, conn)
        safe_logout(ctx.transport, conn)
        {tls, login, folders, move}

      {:error, :auth_failed} ->
        tls = ok("tls_ok", "TLS", "TLS handshake succeeded.")

        login =
          failed(
            "login_ok",
            "Login",
            "The server rejected the username or password.",
            @login_remedy
          )

        {tls, login, unknown("folders", "Folders", "not checked — login failed."),
         unknown("move_capability", "Move capability", "not checked — login failed.")}

      # An OAuth2 account whose token the server refused (M6 task 15). Splits
      # the pair exactly like `:auth_failed` — the credential is only ever
      # offered over the TLS layer, so reaching a rejection PROVES TLS came up —
      # but the remedy is a new sign-in, not a re-typed password.
      {:error, :reauth_required} ->
        tls = ok("tls_ok", "TLS", "TLS handshake succeeded.")

        login =
          failed(
            "login_ok",
            "Login",
            "The server rejected this account's sign-in token.",
            @reauth_remedy
          )

        {tls, login, unknown("folders", "Folders", "not checked — login failed."),
         unknown("move_capability", "Move capability", "not checked — login failed.")}

      {:error, reason} ->
        tls =
          failed(
            "tls_ok",
            "TLS",
            Redact.text("Could not connect: #{inspect(reason)}", secret),
            @tls_remedy
          )

        {tls, unknown("login_ok", "Login", @gate_detail),
         unknown("folders", "Folders", @gate_detail),
         unknown("move_capability", "Move capability", @gate_detail)}
    end
  end

  defp folders_check(ctx, conn) do
    case ctx.transport.list_folders(conn) do
      {:ok, existing} ->
        build_folders_result(missing_folders(existing, ctx.settings.folders))

      {:error, reason} ->
        failed(
          "folders",
          "Folders",
          "Could not list folders: #{inspect(reason)}",
          @folders_transport_remedy
        )
    end
  rescue
    e -> failed("folders", "Folders", Exception.message(e), @folders_transport_remedy)
  catch
    kind, reason ->
      failed("folders", "Folders", inspect({kind, reason}), @folders_transport_remedy)
  end

  # The account's four CONFIGURED special folders (spec E: settings v4 —
  # provider defaults or explicit config): the executor's archive/trash
  # moves and the push flow's Drafts APPEND all target these exact names,
  # so a missing one means real actions will be rejected.
  defp missing_folders(existing, folders) do
    for {key, name} <- [
          {:drafts, folders.drafts},
          {:sent, folders.sent},
          {:archive, folders.archive},
          {:trash, folders.trash}
        ],
        name not in existing,
        do: {key, name}
  end

  defp build_folders_result([]) do
    ok("folders", "Folders", "The configured drafts, sent, archive, and trash folders all exist.")
  end

  defp build_folders_result(missing) do
    names = Enum.map(missing, fn {_key, name} -> name end)
    detail = "Missing folder(s): #{Enum.join(names, ", ")}."
    failed("folders", "Folders", detail, folders_remedy(missing))
  end

  defp folders_remedy(missing) do
    if Enum.any?(missing, fn {_key, name} -> creatable_folder?(name) end) do
      "Use \"Create folders\" to create the missing folder(s), " <>
        "or fix the names in config/mail.yaml."
    else
      "Fix the folder names in config/mail.yaml — [Gmail]/* system folders " <>
        "exist only when the account really is Gmail."
    end
  end

  # "[Gmail]/..." names are Gmail-owned system folders — creating a plain
  # folder with that name would NOT make it special (same container
  # exclusion the ops executor applies), so Valea never tries.
  defp creatable_folder?(name), do: not String.starts_with?(name, "[Gmail]")

  defp move_capability_check(ctx, conn) do
    case ctx.transport.capabilities(conn) do
      {:ok, caps} -> build_move_result(caps)
      {:error, reason} -> move_transport_error(reason)
    end
  rescue
    e -> move_transport_error(Exception.message(e))
  catch
    kind, reason -> move_transport_error({kind, reason})
  end

  defp move_transport_error(reason) do
    failed(
      "move_capability",
      "Move capability",
      "Could not read server capabilities: #{inspect(reason)}",
      @folders_transport_remedy
    )
  end

  defp build_move_result(caps) do
    cond do
      "MOVE" in caps ->
        ok("move_capability", "Move capability", "MOVE supported")

      "UIDPLUS" in caps ->
        ok("move_capability", "Move capability", "UIDPLUS fallback")

      true ->
        failed(
          "move_capability",
          "Move capability",
          "Neither MOVE nor UIDPLUS is advertised by the server.",
          @move_remedy
        )
    end
  end

  # -- 6. smtp_tcp / smtp_tls / smtp_auth (spec G, sending accounts only) -------

  # A push-only account (no `smtp:` block — every v4 file, and any v5 account
  # that simply cannot send) gets NO smtp checks at all: reporting three
  # "unknown" rows for a capability the account was never configured for
  # would read as breakage rather than as a deliberate configuration.
  defp smtp_checks(%{settings: %{smtp: %{} = smtp}} = ctx) do
    {tcp, tcp_ok?} = smtp_tcp_reachable(smtp)
    {tls, auth} = smtp_auth_group(ctx, smtp, tcp_ok?)
    [tcp, tls, auth]
  end

  defp smtp_checks(_ctx), do: []

  defp smtp_tcp_reachable(%{host: host, port: port}) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], @gen_tcp_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        {ok(
           "smtp_tcp",
           "Sending server reachable",
           "Connected to #{host}:#{port} over TCP."
         ), true}

      {:error, reason} ->
        {failed(
           "smtp_tcp",
           "Sending server reachable",
           "Could not open a TCP connection to #{host}:#{port}: #{inspect(reason)}",
           @smtp_tcp_remedy
         ), false}
    end
  rescue
    e ->
      {failed("smtp_tcp", "Sending server reachable", Exception.message(e), @smtp_tcp_remedy),
       false}
  catch
    kind, reason ->
      {failed("smtp_tcp", "Sending server reachable", inspect({kind, reason}), @smtp_tcp_remedy),
       false}
  end

  defp smtp_auth_group(_ctx, _smtp, false) do
    {unknown("smtp_tls", "Sending TLS", @gate_detail),
     unknown("smtp_auth", "Sending login", @gate_detail)}
  end

  defp smtp_auth_group(ctx, smtp, true) do
    # Resolved exactly once, at this boundary, and reused to scrub the secret
    # out of an error's `inspect/1`'d reason — same posture as
    # `transport_group/2`. A missing secret short-circuits BEFORE any session
    # is opened: `check_auth/3` cannot succeed without one, and opening a
    # doomed session would spend one of the provider's AUTH attempts.
    case resolve_credential(ctx[:smtp_credential]) do
      nil ->
        {unknown("smtp_tls", "Sending TLS", "not checked — no sending credential available."),
         failed(
           "smtp_auth",
           "Sending login",
           smtp_credential_missing_detail(ctx),
           smtp_credential_missing_remedy(ctx)
         )}

      secret ->
        smtp_auth_group(ctx, smtp, secret)
    end
  end

  defp smtp_auth_group(ctx, smtp, secret) when is_binary(secret) do
    case do_check_auth(ctx[:smtp_transport], Settings.smtp_config(ctx.settings), secret) do
      :ok ->
        {ok("smtp_tls", "Sending TLS", "TLS handshake succeeded."),
         ok("smtp_auth", "Sending login", "Authenticated as #{smtp.username}.")}

      # An auth failure PROVES the TLS layer came up — the credential is only
      # ever offered over it (see `SmtpClient`), so this is the one error that
      # splits the pair the way `{:error, :auth_failed}` does for IMAP.
      {:error, {:auth_failed, _detail}} ->
        {ok("smtp_tls", "Sending TLS", "TLS handshake succeeded."),
         failed(
           "smtp_auth",
           "Sending login",
           "The sending server rejected the username or password.",
           @smtp_auth_remedy
         )}

      # The XOAUTH2 counterpart (M6 task 15) — same split, different remedy.
      {:error, {:reauth_required, _detail}} ->
        {ok("smtp_tls", "Sending TLS", "TLS handshake succeeded."),
         failed(
           "smtp_auth",
           "Sending login",
           "The sending server rejected this account's sign-in token.",
           @reauth_remedy
         )}

      {:error, reason} ->
        {failed(
           "smtp_tls",
           "Sending TLS",
           Redact.text("Could not establish an SMTP session: #{inspect(reason)}", secret),
           @smtp_tls_remedy
         ), unknown("smtp_auth", "Sending login", @gate_detail)}
    end
  end

  # Same mode-awareness as `credential_present/2`: an oauth2 account has no
  # separate SMTP password — the single sign-in covers sending too.
  defp smtp_credential_missing_detail(ctx) do
    if oauth_account?(ctx),
      do: "This account has not been signed in yet.",
      else: "No SMTP password has been provided yet."
  end

  defp smtp_credential_missing_remedy(ctx),
    do: if(oauth_account?(ctx), do: @signin_remedy, else: @smtp_credential_remedy)

  defp do_check_auth(transport, smtp_config, secret) do
    transport.check_auth(smtp_config, secret, [])
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # -- create_folders helpers ---------------------------------------------------

  defp create_missing_special_folders(transport, conn, folders) do
    case transport.list_folders(conn) do
      {:ok, existing} ->
        missing_folders(existing, folders)
        |> Enum.filter(fn {_key, name} -> creatable_folder?(name) end)
        |> Enum.filter(fn {_key, name} -> create_one(transport, conn, name) end)
        |> Enum.map(fn {_key, name} -> name end)

      {:error, _reason} ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp create_one(transport, conn, name) do
    transport.create_folder(conn, name) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # -- shared: connect/logout, never raising -------------------------------------

  defp do_connect(transport, imap_config, secret) do
    transport.connect(imap_config, secret, [])
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp resolve_credential(fun) when is_function(fun, 0), do: fun.()
  defp resolve_credential(secret) when is_binary(secret), do: secret
  defp resolve_credential(nil), do: nil

  defp safe_logout(transport, conn) do
    transport.logout(conn)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- check builders -------------------------------------------------------------

  defp ok(id, label, detail),
    do: %{"id" => id, "label" => label, "status" => "ok", "detail" => detail, "remedy" => nil}

  defp failed(id, label, detail, remedy),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "failed",
      "detail" => detail,
      "remedy" => remedy
    }

  defp unknown(id, label, detail),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "unknown",
      "detail" => detail,
      "remedy" => nil
    }
end
