defmodule Valea.Mail.Maildir do
  @moduledoc """
  Pure maildir/folder codec for Valea mail subsystem.

  Implements filename encoding/decoding, IMAP flag mapping, folder name escaping,
  and atomic maildir delivery with APFS collision handling.
  """

  @type flags :: MapSet.t(String.t())

  # Regex for parsing maildir filenames
  @filename_regex ~r/^(?<id>[^,:]+)(,U=(?<uid>\d+))?:2,(?<flags>[A-Za-z]*)$/

  # Known maildir flags and their IMAP equivalents
  @flag_map %{
    "S" => "\\Seen",
    "R" => "\\Answered",
    "F" => "\\Flagged",
    "T" => "\\Deleted",
    "D" => "\\Draft"
  }

  @doc """
  Encode a message into a maildir filename.

  Returns a filename string like:
  - "2026-07-15-alex-4f2a91c3,U=42:2,FS" (with uid)
  - "2026-07-15-alex-4f2a91c3:2," (without uid, pre-confirmation)

  Flags are sorted ascending alphabetically.
  """
  @spec encode_filename(String.t(), pos_integer() | nil, flags) :: String.t()
  def encode_filename(msg_id, uid, flags) do
    sorted_flags = flags |> Enum.sort() |> Enum.join()

    uid_part =
      case uid do
        nil -> ""
        uid_val -> ",U=#{uid_val}"
      end

    "#{msg_id}#{uid_part}:2,#{sorted_flags}"
  end

  @doc """
  Parse a maildir filename back into its components.

  Returns {:ok, %{msg_id: String.t(), uid: pos_integer() | nil, flags: MapSet.t()}}
  or :error if the filename is invalid or contains unknown flag letters.
  """
  @spec parse_filename(String.t()) ::
          {:ok, %{msg_id: String.t(), uid: pos_integer() | nil, flags: flags}} | :error
  def parse_filename(filename) do
    case Regex.named_captures(@filename_regex, filename) do
      nil ->
        :error

      captures ->
        msg_id = captures["id"]

        uid =
          case captures["uid"] do
            "" -> nil
            uid_str -> String.to_integer(uid_str)
          end

        flags_str = captures["flags"]

        # Only accept known flag letters
        flag_list = String.graphemes(flags_str)

        if Enum.all?(flag_list, &Map.has_key?(@flag_map, &1)) do
          {:ok, %{msg_id: msg_id, uid: uid, flags: MapSet.new(flag_list)}}
        else
          :error
        end
    end
  end

  @doc """
  Convert maildir flag letters to IMAP system flag strings.

  Unknown flags are dropped (this shouldn't happen with parse_filename output).
  """
  @spec flags_to_imap(flags) :: [String.t()]
  def flags_to_imap(flags) do
    flags
    |> Enum.map(&Map.get(@flag_map, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Convert IMAP system flag strings to maildir flag letters.

  Unknown or custom flags (like $Forwarded) are dropped.
  """
  @spec flags_from_imap([String.t()]) :: flags
  def flags_from_imap(imap_flags) do
    reverse_map = Map.new(@flag_map, fn {k, v} -> {v, k} end)

    imap_flags
    |> Enum.map(&Map.get(reverse_map, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  Return the set of flags that can be pushed to the server.

  Only S (Seen), R (Answered), and F (Flagged) are mutable.
  """
  @spec pushable_flags() :: flags
  def pushable_flags() do
    MapSet.new(["S", "R", "F"])
  end

  @doc """
  Escape a segment for use in a maildir folder path.

  Escapes:
  1. % → %25 (first, before other escapes)
  2. Leading . → %2E
  3. Whole segment cur|new|tmp → escape first char (c→%63, n→%6E, t→%74)
  """
  @spec encode_segment(String.t()) :: String.t()
  def encode_segment(segment) do
    # Step 1: Escape % first
    escaped = String.replace(segment, "%", "%25")

    # Step 2: Escape leading dot
    escaped =
      if String.starts_with?(escaped, ".") do
        "%2E" <> String.slice(escaped, 1..-1//1)
      else
        escaped
      end

    # Step 3: Escape reserved words (cur, new, tmp) by escaping first char
    cond do
      escaped == "cur" -> "%63" <> String.slice(escaped, 1..-1//1)
      escaped == "new" -> "%6E" <> String.slice(escaped, 1..-1//1)
      escaped == "tmp" -> "%74" <> String.slice(escaped, 1..-1//1)
      true -> escaped
    end
  end

  @doc """
  Decode a segment from maildir folder path format.

  Reverses %-escape sequences (%XX → chr(0xXX)).
  """
  @spec decode_segment(String.t()) :: String.t()
  def decode_segment(segment) do
    # Decode %XX sequences
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, segment, fn _match, hex ->
      byte_val = String.to_integer(hex, 16)
      <<byte_val::8>>
    end)
  end

  @doc """
  Map an IMAP folder name to a maildir directory path.

  Splits the name on "/", encodes each segment, and joins.
  Handles collision with pre-existing directories by appending suffixes
  (6, 12, 18, ... hex digits of SHA256(imap_name)).

  The collision key is computed as: String.downcase() + :unicode.characters_to_nfc_binary()
  of the encoded path. Every candidate (including suffixed ones) is checked against `taken`.
  """
  @spec folder_to_dir(String.t(), MapSet.t(String.t())) :: String.t()
  def folder_to_dir(imap_name, taken) do
    # Encode the path segments
    encoded_path = imap_name |> String.split("/") |> Enum.map(&encode_segment/1) |> Enum.join("/")

    # Try base path first
    if candidate_available?(encoded_path, taken) do
      encoded_path
    else
      # Generate suffixes: 6, 12, 18, ... hex digits of SHA256(imap_name)
      sha_hex = :crypto.hash(:sha256, imap_name) |> Base.encode16(case: :lower)

      # Try suffixes of increasing length
      Enum.reduce_while([6, 12, 18, 24, 30, 36, 42, 48, 54, 60, 64], nil, fn
        hex_len, _acc ->
          suffix = "-" <> String.slice(sha_hex, 0, hex_len)
          candidate = "#{encoded_path}#{suffix}"

          if candidate_available?(candidate, taken) do
            {:halt, candidate}
          else
            {:cont, nil}
          end
      end)
    end
  end

  defp candidate_available?(candidate, taken) do
    norm = normalize_for_collision(candidate)
    not MapSet.member?(taken, norm)
  end

  defp normalize_for_collision(path) do
    path
    |> String.downcase()
    |> :unicode.characters_to_nfc_binary()
  end

  @doc """
  Create the standard maildir subdirectories (cur, new, tmp) in the given path.
  """
  @spec mailbox_dirs(String.t()) :: :ok
  def mailbox_dirs(folder_dir) do
    File.mkdir_p!(Path.join(folder_dir, "cur"))
    File.mkdir_p!(Path.join(folder_dir, "new"))
    File.mkdir_p!(Path.join(folder_dir, "tmp"))
    :ok
  end

  @doc """
  Write the folder identity file atomically.

  Creates <dir>/.folder containing the exact IMAP name, written atomically
  (temp file + rename).
  """
  @spec write_folder_identity!(String.t(), String.t()) :: :ok
  def write_folder_identity!(folder_dir, imap_name) do
    folder_file = Path.join(folder_dir, ".folder")
    temp_file = "#{folder_file}.tmp-#{System.unique_integer([:positive])}"

    File.write!(temp_file, imap_name)
    File.rename!(temp_file, folder_file)
    :ok
  end

  @doc """
  Read the folder identity from the .folder file.

  Returns {:ok, imap_name} or :error if the file doesn't exist or can't be read.
  """
  @spec read_folder_identity(String.t()) :: {:ok, String.t()} | :error
  def read_folder_identity(folder_dir) do
    folder_file = Path.join(folder_dir, ".folder")

    case File.read(folder_file) do
      {:ok, content} -> {:ok, String.trim(content)}
      :error -> :error
    end
  end

  @doc """
  Deliver a message to the maildir atomically.

  Writes the message bytes to tmp/<filename>, fsyncs, then renames to cur/.
  """
  @spec deliver!(String.t(), String.t(), binary) :: :ok
  def deliver!(folder_dir, filename, bytes) do
    tmp_path = Path.join(folder_dir, "tmp")
    cur_path = Path.join(folder_dir, "cur")

    tmp_file = Path.join(tmp_path, filename)
    cur_file = Path.join(cur_path, filename)

    # Write to tmp
    File.write!(tmp_file, bytes)

    # Sync to disk (open in read mode to avoid truncating)
    File.open!(tmp_file, [:binary], fn file ->
      :file.datasync(file)
    end)

    # Atomically move to cur
    File.rename!(tmp_file, cur_file)
    :ok
  end

  @doc """
  List all occurrences (messages) in the maildir folder.

  Returns a list of maps with: filename, msg_id, uid, flags.
  """
  @spec list_occurrences(String.t()) :: [
          %{
            filename: String.t(),
            msg_id: String.t(),
            uid: pos_integer() | nil,
            flags: flags
          }
        ]
  def list_occurrences(folder_dir) do
    cur_path = Path.join(folder_dir, "cur")

    case File.ls(cur_path) do
      {:ok, files} ->
        for filename <- files do
          case parse_filename(filename) do
            {:ok, %{msg_id: msg_id, uid: uid, flags: flags}} ->
              %{filename: filename, msg_id: msg_id, uid: uid, flags: flags}

            :error ->
              nil
          end
        end
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end
end
