defmodule Valea.Yaml do
  @moduledoc """
  Shared injection-hardened YAML scalar rendering for the app's hand-rolled
  YAML template writers (`config/mail.yaml`, `mounts/<name>/icm.yaml`, ...).

  `escape/1` mirrors `Valea.Mail.Settings`'s private `yaml_string/1`: invalid
  UTF-8 is scrubbed first (each bad sequence → U+FFFD) so
  `String.to_charlist/1` structurally cannot raise on raw bytes; then every
  C0 control character and DEL is neutralized to a plain space (never
  dropped, so a value doesn't silently truncate) and `\\` / `"` are escaped
  before double-quoting — none of these values can ever inject a sibling
  YAML key, break the enclosing block, or crash the write.
  """

  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    escaped =
      value
      |> ensure_valid_utf8()
      |> String.to_charlist()
      |> Enum.map(fn c -> if c < 0x20 or c == 0x7F, do: ?\s, else: c end)
      |> List.to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp ensure_valid_utf8(value) do
    if String.valid?(value), do: value, else: scrub_utf8(value)
  end

  # Same scrub semantic as `Valea.Mail.Normalizer.scrub_utf8/1`, reimplemented
  # here rather than imported so this module carries no dependency on Mail.
  defp scrub_utf8(bin) do
    case :unicode.characters_to_binary(bin) do
      b when is_binary(b) ->
        b

      {:error, good, <<_bad, rest::binary>>} ->
        good <> <<0xFFFD::utf8>> <> scrub_utf8(rest)

      {:error, good, <<>>} ->
        good <> <<0xFFFD::utf8>>

      {:incomplete, good, _rest} ->
        good <> <<0xFFFD::utf8>>
    end
  end
end
