defmodule Valea.Mail.Trust do
  @moduledoc """
  The trusted-senders list behind HTML mail's "load remote content" gate:
  a message from a trusted address renders with remote images allowed; from
  anyone else the frontend blocks external loads and shows the ask banner.

  File-first like everything else mail: a plain JSON array of lowercased
  addresses at `config/mail-trusted-senders.json`, workspace-scoped (trust
  is a reader decision, not a per-account one), hand-editable, atomically
  rewritten (same temp-file + rename discipline as
  `Valea.Mail.Settings.atomic_write!/2`). A missing or unparseable file is
  an empty list — fail-closed: nobody is trusted until the user says so.

  Trust here gates CONTENT LOADING only (tracking pixels, remote images) —
  it grants nothing else: no sending, no filtering, no identity claim. The
  sender address is whatever the message's `From` header said, which is
  spoofable; that is acceptable for this gate because the decision's scope
  is "may this rendering fetch remote resources", not anything
  security-bearing about who wrote the mail.
  """

  @file_name "mail-trusted-senders.json"
  @max_entries 5_000
  @max_length 320

  @doc "Every trusted address, lowercased, sorted. Missing/broken file → `[]`."
  @spec list(String.t()) :: [String.t()]
  def list(root) when is_binary(root) do
    case File.read(path(root)) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, entries} when is_list(entries) ->
            entries
            |> Enum.filter(&valid_address?/1)
            |> Enum.map(&String.downcase/1)
            |> Enum.uniq()
            |> Enum.sort()

          _malformed ->
            []
        end

      {:error, _} ->
        []
    end
  end

  @doc "Whether `email` (case-insensitive) is on the trusted list."
  @spec trusted?(String.t(), String.t() | nil) :: boolean()
  def trusted?(_root, nil), do: false

  def trusted?(root, email) when is_binary(root) and is_binary(email) do
    String.downcase(email) in list(root)
  end

  @doc """
  Adds or removes `email` and atomically rewrites the file. Idempotent.
  `{:error, :invalid_email}` for a value that isn't a plausible address —
  nothing invalid is ever written into the file.
  """
  @spec set_trusted(String.t(), String.t(), boolean()) :: :ok | {:error, :invalid_email}
  def set_trusted(root, email, trusted) when is_binary(root) and is_binary(email) do
    if valid_address?(email) do
      normalized = String.downcase(String.trim(email))
      current = list(root)

      updated =
        if trusted,
          do: Enum.take(Enum.uniq(Enum.sort([normalized | current])), @max_entries),
          else: List.delete(current, normalized)

      if updated == current do
        :ok
      else
        atomic_write!(path(root), Jason.encode!(updated, pretty: true) <> "\n")
      end
    else
      {:error, :invalid_email}
    end
  end

  # Plausible-address gate, not full RFC validation: one `@`, no control
  # characters or quotes (keeps the JSON file trivially hand-editable), sane
  # length. The value only ever compares against `From` headers.
  defp valid_address?(email) when is_binary(email) do
    trimmed = String.trim(email)

    byte_size(trimmed) in 3..@max_length and String.contains?(trimmed, "@") and
      not Regex.match?(~r/[\s\x00-\x1F\x7F"\\]/, trimmed)
  end

  defp valid_address?(_other), do: false

  defp path(root), do: Path.join([root, "config", @file_name])

  defp atomic_write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
    :ok
  end
end
