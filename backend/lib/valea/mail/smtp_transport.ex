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
  """

  @typedoc """
  The connection-shaped subset of `Valea.Mail.Settings.smtp()` an
  implementation reads. The caller passes the settings map whole; the extra
  identity keys (`from`/`from_name`) belong to composition, not transport.
  """
  @type smtp_config :: %{
          :host => String.t(),
          :port => pos_integer(),
          :security => :starttls | :tls,
          :username => String.t(),
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
