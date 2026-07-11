defmodule Valea.Mail.Redact do
  @moduledoc """
  Shared credential scrubbing for `Valea.Mail.Doctor` and `Valea.Mail.Engine`
  — the one place a connect-error reason is stripped of the credential before
  it can reach a log line or a UI-visible status field (e.g. the mail status
  `last_error` that is broadcast on every push).

  Redaction here is **defense-in-depth**, not the primary defense: the IMAP
  client sends the username and password as literals, so a secret never flows
  through the command encoder that could raise with it inline. This module
  catches the residual case where a reason term nonetheless embeds the secret
  — raw, or in the `\\`-escaped form `inspect/1` would render it as.

  Two guards keep it from doing harm:

    * it never touches a secret shorter than `@min_secret_len` bytes, so a
      2-character password can't blank out unrelated substrings of a message;
    * it compares against both the raw secret and its inspect-escaped form,
      so a secret a prior `inspect/1` already escaped is still caught.
  """

  @mask "[redacted]"
  @min_secret_len 4

  @doc """
  Scrub `secret` (both raw and inspect-escaped) out of an already-built
  display string. A `nil`/blank/too-short secret leaves the string untouched.
  """
  @spec text(String.t(), String.t() | nil) :: String.t()
  def text(string, secret) when is_binary(string) and is_binary(secret) do
    if redactable?(secret) do
      string
      |> String.replace(secret, @mask)
      |> String.replace(inspect_inner(secret), @mask)
    else
      string
    end
  end

  def text(string, _secret) when is_binary(string), do: string

  @doc """
  Scrub a still-a-term connect `reason`. A reason that does not embed the
  secret passes through completely untouched (callers keep matching on
  `:econnrefused`-style atoms); one that does is stringified via `inspect/1`
  with the secret scrubbed — losing the term's shape is the acceptable cost of
  never letting the credential out.
  """
  @spec reason(term(), String.t() | nil) :: term()
  def reason(reason, secret) when is_binary(secret) do
    if redactable?(secret) do
      inspected = inspect(reason)

      if String.contains?(inspected, secret) or String.contains?(inspected, inspect_inner(secret)) do
        text(inspected, secret)
      else
        reason
      end
    else
      reason
    end
  end

  def reason(reason, _secret), do: reason

  defp redactable?(secret), do: byte_size(secret) >= @min_secret_len

  # The secret as it renders INSIDE a double-quoted inspected string (escapes
  # applied, surrounding quotes stripped) — this is how the secret appears
  # once a larger reason string containing it is itself inspected. Non-string
  # inspect output (e.g. a binary rendered as `<<...>>`) is used as-is.
  defp inspect_inner(secret) do
    case inspect(secret) do
      <<?", _::binary>> = quoted -> binary_part(quoted, 1, byte_size(quoted) - 2)
      other -> other
    end
  end
end
