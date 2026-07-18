defmodule Valea.Calendar.Source do
  @moduledoc """
  Per-source feed identity binding (calendar spec F, §Storage layout) — the
  engine-owned `sources/calendar/<slug>/.source` file recording which FEED a
  slug's local subtree was first provisioned against: the URL's host plus
  the first 16 hex characters of `sha256(url)`. The `Valea.Mail.Account`
  `.account` posture, adapted to a subscription URL: a slug whose supplied
  URL no longer matches `.source` refuses to sync (`identity_mismatch`,
  resolved by purge), so one feed's mirror can never be silently
  overwritten by a different feed reusing the slug.

  The URL itself is a credential (Google's "secret address") and is NEVER
  persisted — only its host and a short hash land in `.source`, enough to
  verify identity without disclosing the token.
  """

  @doc """
  Verifies `url` against `dir/.source`, claiming it when absent:

    * absent → write `host <> "\\n" <> first 16 hex of sha256(url)`
      (atomic: temp file + rename) and `:ok`;
    * present and matching → `:ok`;
    * present and different — or unreadable/unparseable (a corrupt file
      must never silently re-claim the slug) → `{:error, :identity_mismatch}`.
  """
  @spec verify_or_claim(String.t(), String.t()) :: :ok | {:error, :identity_mismatch}
  def verify_or_claim(dir, url) when is_binary(dir) and is_binary(url) do
    path = Path.join(dir, ".source")
    expected = render(url)

    case File.read(path) do
      {:error, :enoent} ->
        File.mkdir_p!(dir)
        atomic_write!(path, expected)
        :ok

      {:error, _reason} ->
        {:error, :identity_mismatch}

      {:ok, ^expected} ->
        :ok

      {:ok, _different} ->
        {:error, :identity_mismatch}
    end
  end

  defp render(url) do
    host =
      case URI.new(url) do
        {:ok, %URI{host: host}} when is_binary(host) -> host
        _not_a_uri -> ""
      end

    hash =
      :crypto.hash(:sha256, url)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    host <> "\n" <> hash <> "\n"
  end

  defp atomic_write!(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, path)
  end
end
