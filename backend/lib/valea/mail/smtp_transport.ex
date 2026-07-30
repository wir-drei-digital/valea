defmodule Valea.Mail.SmtpTransport do
  @moduledoc """
  The send side of the mail stack — deliberately tiny, and deliberately
  SEPARATE from `Valea.Mail.Transport` (spec G, §SMTP transport & client).
  The IMAP behaviour stays send-free: nothing in this module's contract can
  be reached from a sync pass, a reconciliation, or a recovery path.

  ## The tri-state contract

  `send/5` returns one of three shapes, and the boundary between them is
  defined by **server knowledge, not protocol phase**:

    * `{:ok, :accepted}` — a final `2xx` was RECEIVED after the terminating
      dot. Transmission is proven.
    * `{:error, reason}` — **provably unsent.** Every failure before the
      server's `354` (connect, TLS, EHLO, AUTH, `MAIL FROM`, `RCPT TO`,
      `DATA`), *and* a received, parseable final non-2xx after the dot
      (`{:refused, code, text}` — the server definitively refused it, 4xx
      no less than 5xx). Safe to reject the op and let the human click
      again.
    * `{:unknown, reason}` — message bytes may have reached the server but
      the final reply is missing or undecodable: a dropped connection, a
      timeout, a TLS teardown, garbage instead of a reply — **and equally a
      socket/write failure mid-body or mid-terminator.** A partially
      written payload's terminating dot may already have been flushed by
      TCP, so "we did not finish handing it to the socket" is NOT evidence
      that nothing was delivered. Classifying such a failure as
      provably-unsent would let a human re-click duplicate a delivered
      message. `:unknown` parks the op for human resolution and is NEVER
      retried.

  The `354` is the line: everything before it is `{:error, _}`; everything
  after it is `{:unknown, _}` unless a parseable final reply arrived, in
  which case that reply decides.

  Recipients are **all-or-nothing**: any rejected `RCPT TO` aborts with
  `RSET` + `QUIT` BEFORE `DATA` and reports every rejected address, so Valea
  never delivers to a subset of the reviewed recipient set.

  ## Ordering per security mode

  `check_auth/3` NEVER issues `MAIL FROM` (nothing that could enqueue
  anything — some providers rate-limit AUTH, so it runs on demand only);
  `send/5` follows the same ordering through AUTH:

    * `:starttls` (587): `EHLO` → `STARTTLS` → TLS upgrade → **second
      `EHLO`** → `AUTH` → `QUIT`. RFC 3207: extensions advertised by the
      pre-TLS `EHLO` MUST be discarded — AUTH mechanisms are selected only
      from the post-TLS `EHLO` response.
    * `:tls` (465, implicit): TLS connect → `EHLO` → `AUTH` → `QUIT`. One
      `EHLO`; there is no pre-TLS plaintext phase, so `STARTTLS` never
      appears on this path.

  TLS is mandatory and verified in both modes. There is no plaintext mode,
  and AUTH is only ever issued over an established TLS layer.

  ## AUTH mechanism selection (`smtp_config.auth`)

  The account's mode decides, never the advertisement: a `:password` account
  picks `PLAIN` or `LOGIN` from the post-TLS `EHLO`, an `:oauth2` account uses
  `XOAUTH2` and NOTHING else. There is no fallback between the two families —
  a server that does not advertise `XOAUTH2` to an `:oauth2` account is
  `{:error, {:auth_unsupported, mechs}}`, because the alternative is putting
  an access token in a password field.

  `XOAUTH2`'s rejection is `{:error, {:reauth_required, text}}` — the
  send-side counterpart of `Valea.Mail.Transport`'s `:reauth_required`, and
  deliberately distinct from `{:auth_failed, text}`: a token needs minting,
  not re-typing. Both are pre-354, so both stay `{:error, _}` (provably
  unsent).
  """

  @typedoc """
  The connection-shaped subset of `Valea.Mail.Settings.smtp()` an
  implementation reads, plus the account's `auth` mode. The caller passes the
  map `Valea.Mail.Settings.smtp_config/1` builds; the extra identity keys
  (`from`/`from_name`) ride along but belong to composition, not transport.

  `auth` is what selects the SASL mechanism (M6 task 15) — `:password` means
  `AUTH PLAIN`/`AUTH LOGIN` with a password, `:oauth2` means `AUTH XOAUTH2`
  with the `credential` being an access token. It is optional in the type
  because every caller predating that mode passes the settings block alone,
  and an implementation must read its absence as `:password`; it must NEVER
  read an unrecognized value as `:password`, which would offer a bearer token
  in a password field.
  """
  @type smtp_config :: %{
          :host => String.t(),
          :port => pos_integer(),
          :security => :starttls | :tls,
          :username => String.t(),
          optional(:auth) => Valea.Mail.Settings.auth(),
          optional(atom()) => term()
        }

  @typedoc "Bare addr-specs for the SMTP envelope: `from`, and `to ++ cc ++ bcc` as `rcpt`."
  @type envelope :: %{from: String.t(), rcpt: [String.t()]}

  @type send_result ::
          {:ok, :accepted}
          | {:error, {:rejected_recipients, [{String.t(), String.t()}]}}
          | {:error, term()}
          | {:unknown, term()}

  @doc "Transmits `data` for `envelope` exactly once. See the moduledoc for the tri-state contract."
  @callback send(smtp_config(), credential :: String.t(), envelope(), data :: binary(), keyword()) ::
              send_result()

  @doc "Connects, upgrades, authenticates, and QUITs — the doctor's SMTP probe. NEVER issues MAIL FROM."
  @callback check_auth(smtp_config(), credential :: String.t(), keyword()) ::
              :ok | {:error, term()}
end
