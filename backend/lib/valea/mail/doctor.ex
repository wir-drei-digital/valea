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
    3. `tcp_reachable` — a raw `:gen_tcp.connect/4` probe (no TLS, no
       login), 5s timeout. Gated on 1 + 2.
    4. `tls_ok` + `login_ok` + `folders` + `move_capability` — derived from
       ONE `ctx.transport.connect/3` call, gated on 3:
       * `tls_ok` is `"ok"` whenever the connect got far enough to attempt
         LOGIN (i.e. it returned `{:ok, _}` or specifically
         `{:error, :auth_failed}`); any other connect error means the
         client never got a working transport layer, so `tls_ok` is
         `"failed"` and `login_ok`/`folders`/`move_capability` are
         `"unknown"` (the login was never attempted).
       * `login_ok` is `"ok"` on `{:ok, conn}`, `"failed"` on
         `{:error, :auth_failed}` (gated on `tls_ok`).
       * `folders` (`ctx.transport.list_folders/1`) and `move_capability`
         (`ctx.transport.capabilities/1`) are siblings computed off the
         same live `conn` once `login_ok` is `"ok"` — one's result never
         gates the other.
    5. `workflow_contract` — discovers the seeded New Inquiry Triage
       workflow via `Valea.Workflows.triage_path/1` (the first enabled
       mount, by the registry's own sort order, with a `Workflows/New
       Inquiry Triage.md` — Task A-T13; no more hardcoded
       `icm/Workflows/New Inquiry Triage.md`), reads it under `ctx.root`,
       and warns if it still names the legacy JSON input. This is a
       **local file check with no mailbox dependency**, so it is gated on
       config_present alone (step 1), not on credential/network/login
       state — a broken workflow contract is worth surfacing even before an
       account is fully connected. (It is still `"unknown"` when
       `config_present` itself failed, matching every other check, and
       `"unknown"` — not `"failed"` — when no mount has the Triage page at
       all: an absent probe target, not a probed-and-broken one.)

  `run/1` never raises: every transport call is caught, and an unexpected
  crash anywhere in the pipeline becomes a `"failed"` check with the
  exception message, never an exception that reaches the caller. The
  credential is a zero-arity closure (or a raw secret in a hand-built test
  ctx) dereferenced ONLY at the `connect/3` boundary, exactly like
  `SyncPass`/`MailboxOps` — no check's `detail`/`remedy` string ever
  interpolates it.
  """

  alias Valea.Mail.Redact
  alias Valea.Mail.Settings

  @type check :: %{String.t() => String.t() | nil}

  @type ctx :: %{
          root: String.t(),
          settings: Settings.t() | nil,
          credential: (-> String.t()) | String.t() | nil,
          transport: module()
        }

  @gen_tcp_timeout_ms 5_000
  @ai_folder_keys [:review, :processed]

  @gate_detail "not checked — an earlier check failed."

  @config_remedy "Set up your mail account (host, port, username) in Mail settings."
  @credential_remedy "Enter your mailbox password to connect."
  @tcp_remedy "Check the host and port, and your network connection."
  @tls_remedy "Confirm the host/port support implicit TLS (IMAPS, usually port 993)."
  @login_remedy "Double-check the mailbox username and password."
  @folders_transport_remedy "Check server connectivity and try again."
  @move_remedy "Your server supports neither MOVE nor UIDPLUS — " <>
                 "Valea will leave messages in AI/Review and you move them manually."
  @workflow_remedy "This workflow page still references the legacy JSON input — " <>
                     "update its Inputs to sources/mail/messages/*.md"

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
    {tcp, tcp_ok?} = tcp_reachable(ctx, config_ok? and credential_ok?)
    {tls, login, folders, move} = transport_group(ctx, tcp_ok?)
    workflow = workflow_contract(ctx, config_ok?)

    checks = [config, credential, tcp, tls, login, folders, move, workflow]
    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  @doc """
  Connects and creates whichever of the AI/Review and AI/Processed folders
  (per `ctx.settings.folders`) are missing on the server — the doctor
  panel's "Create AI folders" action. The Drafts folder is never created
  here: it isn't a Valea-owned `AI/*` folder, so a missing/misnamed one is
  a config problem (see the `folders` check's remedy), not something to
  auto-create. Returns the folder names actually created; a folder whose
  `create_folder` call itself fails is silently left out of that list (the
  doctor's next run will still report it missing). A connect failure is
  returned as `{:error, reason}` — nothing to create without a connection.
  The reason passes through untouched unless it embeds the raw credential,
  in which case it is stringified with the secret scrubbed (same redaction
  posture as `run/1`'s tls_ok check; this error reaches RPC/UI consumers).
  """
  @spec create_folders(ctx()) :: {:ok, [String.t()]} | {:error, term()}
  def create_folders(%{settings: %Settings{} = settings, transport: transport} = ctx) do
    # Same once-at-the-connect-boundary resolution as `transport_group/2`,
    # for the same reason: the connect error's reason term is the one value
    # here that could conceivably embed the secret, and it flows out of
    # this function to callers outside this module.
    secret = resolve_credential(ctx[:credential])

    case do_connect(transport, settings.imap, secret) do
      {:ok, conn} ->
        created = create_missing_ai_folders(transport, conn, settings.folders)
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

  defp config_present(%{settings: %Settings{imap: imap}}) do
    {ok(
       "config_present",
       "Mail account configured",
       "config/mail.yaml is configured for #{imap.username}@#{imap.host}."
     ), true}
  end

  # -- 2. credential_present ----------------------------------------------------

  defp credential_present(_ctx, false) do
    {unknown("credential_present", "Password available", @gate_detail), false}
  end

  defp credential_present(%{credential: nil}, true) do
    {failed(
       "credential_present",
       "Password available",
       "No mailbox password has been provided yet.",
       @credential_remedy
     ), false}
  end

  defp credential_present(%{credential: _present}, true) do
    {ok("credential_present", "Password available", "A mailbox password is available."), true}
  end

  # -- 3. tcp_reachable ----------------------------------------------------------

  defp tcp_reachable(_ctx, false) do
    {unknown("tcp_reachable", "Server reachable", @gate_detail), false}
  end

  defp tcp_reachable(%{settings: %Settings{imap: %{host: host, port: port}}}, true) do
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

  # -- 4. tls_ok / login_ok / folders / move_capability (one connect) -----------

  defp transport_group(_ctx, false) do
    {unknown("tls_ok", "TLS", @gate_detail), unknown("login_ok", "Login", @gate_detail),
     unknown("folders", "Folders", @gate_detail),
     unknown("move_capability", "Move capability", @gate_detail)}
  end

  defp transport_group(%{settings: %Settings{imap: imap}} = ctx, true) do
    # Resolved exactly once, right at this connect boundary (never earlier,
    # never logged) — and reused below to scrub the raw secret out of a
    # connect error's `inspect/1`'d reason before it ever reaches a check's
    # `detail` string. Realistically no transport error embeds the
    # credential, but the check builder has no way to know that in general,
    # so this is a belt-and-suspenders egress filter, not a load-bearing one.
    secret = resolve_credential(ctx[:credential])

    case do_connect(ctx.transport, imap, secret) do
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

  defp missing_folders(existing, folders) do
    for {key, name} <- [
          {:review, folders.review},
          {:processed, folders.processed},
          {:drafts, folders.drafts}
        ],
        name not in existing,
        do: {key, name}
  end

  defp build_folders_result([]) do
    ok("folders", "Folders", "Review, Processed, and Drafts folders all exist.")
  end

  defp build_folders_result(missing) do
    names = Enum.map(missing, fn {_key, name} -> name end)
    detail = "Missing folder(s): #{Enum.join(names, ", ")}."
    failed("folders", "Folders", detail, folders_remedy(missing))
  end

  defp folders_remedy(missing) do
    ai_missing? = Enum.any?(missing, fn {key, _} -> key in @ai_folder_keys end)
    drafts_missing? = Enum.any?(missing, fn {key, _} -> key == :drafts end)

    cond do
      ai_missing? and drafts_missing? ->
        "Use \"Create AI folders\" to create the missing AI/* folder(s); " <>
          "check the drafts folder name in config/mail.yaml."

      ai_missing? ->
        "Use \"Create AI folders\" to create the missing AI/* folder(s)."

      drafts_missing? ->
        "Check the drafts folder name in config/mail.yaml."
    end
  end

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

  # -- 5. workflow_contract ----------------------------------------------------

  defp workflow_contract(_ctx, false) do
    unknown("workflow_contract", "Workflow contract", @gate_detail)
  end

  defp workflow_contract(ctx, true) do
    case Valea.Workflows.triage_path(ctx.root) do
      nil -> workflow_contract_absent()
      rel_path -> workflow_contract_read(ctx.root, rel_path)
    end
  end

  defp workflow_contract_read(root, rel_path) do
    case File.read(Path.join(root, rel_path)) do
      {:ok, content} -> workflow_contract_result(content, rel_path)
      {:error, _reason} -> workflow_contract_absent()
    end
  end

  defp workflow_contract_result(content, rel_path) do
    if String.contains?(content, "normalized/") or String.contains?(content, ".json") do
      failed(
        "workflow_contract",
        "Workflow contract",
        "#{rel_path} still references the legacy JSON input.",
        @workflow_remedy
      )
    else
      ok(
        "workflow_contract",
        "Workflow contract",
        "#{rel_path} matches the current mail message contract."
      )
    end
  end

  defp workflow_contract_absent do
    unknown(
      "workflow_contract",
      "Workflow contract",
      "No New Inquiry Triage workflow was found in any enabled mount."
    )
  end

  # -- create_folders helpers ---------------------------------------------------

  defp create_missing_ai_folders(transport, conn, folders) do
    case transport.list_folders(conn) do
      {:ok, existing} ->
        [{:review, folders.review}, {:processed, folders.processed}]
        |> Enum.reject(fn {_key, name} -> name in existing end)
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
