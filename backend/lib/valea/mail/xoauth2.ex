defmodule Valea.Mail.Xoauth2 do
  @moduledoc """
  The SASL `XOAUTH2` client response, shared by both mail clients (mail
  full-client plan, M6 task 15).

  ONE builder for the whole codebase on purpose: `Valea.Mail.ImapClient`
  sends it as `AUTHENTICATE XOAUTH2 <response>` and
  `Valea.Mail.SmtpClient` as `AUTH XOAUTH2 <response>`, and a second
  spelling of the same byte layout is exactly the bug that would
  authenticate against one server and be rejected by the other.

  The layout is Google's (and Microsoft's) de-facto `XOAUTH2` mechanism,
  not an RFC: the raw string is

      "user=" <> user <> "\\x01auth=Bearer " <> token <> "\\x01\\x01"

  base64-encoded. `\\x01` (`^A`) is the field separator and the string ends
  in two of them — one closing the last field, one closing the list.

  ## Never raises on the bytes it is given

  Both inputs are opaque to this module: an access token is provider-issued
  text this codebase does not get to validate, and a username can be
  anything the account's config says. So the construction is pure binary
  concatenation plus `Base.encode64/1` — no `String.*` function that could
  reject invalid UTF-8, no interpolation, no wire-encoding guard. 8-bit
  bytes in either input produce a (correctly encoded, probably rejected)
  SASL response rather than an exception that would land the token in a
  crash report.

  Nothing here logs, and callers must not either: the returned string
  CONTAINS the access token in a trivially reversible encoding. Treat it
  exactly like the secret it wraps.
  """

  @doc """
  The base64 `XOAUTH2` initial client response for `user` + `token`.

  Both arguments are raw binaries — see the moduledoc: this never raises on
  8-bit or otherwise invalid-UTF-8 input.
  """
  @spec response(binary(), binary()) :: binary()
  def response(user, token) when is_binary(user) and is_binary(token) do
    Base.encode64("user=" <> user <> <<1>> <> "auth=Bearer " <> token <> <<1, 1>>)
  end
end
