defmodule Valea.Mail.Views do
  @moduledoc """
  Landing + garbage-collecting the DERIVED, per-message views under
  `sources/mail/<account>/views/` (mail-as-maildir design spec, §Storage
  layout / §Derived views & indexing) — `messages/<msg_id>.md` (normalized
  markdown, `Valea.Mail.MessageFile`'s format) and `attachments/<msg_id>/`
  (extracted on landing). ONE view per message, shared by every occurrence
  of that message across every folder (a Gmail label + INBOX, an ordinary
  `COPY`) — landing the same raw bytes twice is a no-op, never a second
  file.

  ## Fingerprint bookkeeping (the `.fingerprints` sidecar)

  `land/4` must be able to tell, cheaply and without re-reading the
  (possibly large) view file, whether a given `msg_id` already holds a
  DIFFERENT message's content (a genuine 8-hex hash collision — the rule
  this module's `resolve_msg_id/4` implements is 8 → 16 → 64 hex,
  identical in spirit to `Valea.Mail.Maildir.folder_to_dir/2`'s directory
  collision suffixes). This module keeps a small sidecar file per msg_id —
  `views/.fingerprints/<msg_id>` containing just the hex fingerprint
  string — rather than comparing against a raw maildir candidate file: the
  caller landing a view doesn't necessarily have a maildir occurrence path
  handy yet (in the normal flow, `land/4` runs BEFORE the raw bytes are
  delivered into `maildir/`, precisely so the caller can build the
  maildir filename `<msg_id>,U=<uid>:2,<flags>` from the id this function
  returns), and a sidecar keeps this module's file I/O self-contained
  (it never needs to know folder directory layout). The sidecar is
  removed alongside the view on full GC (`remove_occurrence/4` with
  `remaining: 0`) — a msg_id can be freely reused for new content once
  every trace of the old content is gone.

  A sidecar can go missing while its view file survives (hand-deleted,
  interrupted write, a concurrent rebuild's self-heal). `land/4` treats
  that combination as ALREADY CLAIMED, not unclaimed: it regenerates the
  sidecar from the incoming bytes' own fingerprint rather than overwriting
  the view (which would silently wipe out `folders:`/`flags:` set by
  `refresh_folders/5` since the view was landed). This can't distinguish
  "lost sidecar for THIS content" from "a genuine different-content
  collision at this exact msg_id" -- the residual risk is accepted because
  regenerating the sidecar re-establishes the invariant going forward, and
  the former case is overwhelmingly the common one.

  ## `msg_id_hint`

  A caller that already knows which msg_id a raw copy logically belongs to
  (e.g. it matched an existing occurrence by Message-ID before computing
  anything) can pass `msg_id_hint` to skip this module's own 8/16/64
  resolution and land straight under that id. The hint is trusted only
  when it is either unclaimed (no sidecar yet) or already carries the SAME
  fingerprint (idempotent re-land); a hint that collides with a
  DIFFERENT stored fingerprint falls back to the ordinary resolution
  instead of silently overwriting someone else's view.
  """

  alias Valea.Mail.MessageFile
  alias Valea.Mail.Normalizer

  # -- land ---------------------------------------------------------------

  @doc """
  Normalizes `raw` (RFC822 bytes), computes its fingerprint + msg_id
  (collision-extended against OTHER stored fingerprints — see the
  moduledoc), and — unless a view already exists under that msg_id with
  the SAME fingerprint (idempotent no-op) — writes
  `views/messages/<msg_id>.md` and `views/attachments/<msg_id>/*`. Freshly
  landed views carry `folders: []`/`flags: ""`; the caller assigns real
  occurrence membership afterwards via `refresh_folders/5` (this
  function's signature has no folder/flag information to render — it
  lands the MESSAGE, not any particular occurrence).
  """
  @spec land(String.t(), String.t(), binary(), map()) ::
          {:ok, %{msg_id: String.t(), fingerprint: String.t(), has_attachments: boolean()}}
  def land(root, account, raw, opts \\ %{})
      when is_binary(root) and is_binary(account) and is_binary(raw) and is_map(opts) do
    {:ok, message} = Normalizer.normalize(raw)
    fingerprint = MessageFile.fingerprint(raw)
    msg_id = resolve_id(root, account, message, raw, fingerprint, Map.get(opts, :msg_id_hint))

    case {fingerprint_of(root, account, msg_id), view_ok?(root, account, msg_id)} do
      {^fingerprint, true} ->
        # Already landed under this id with this exact content, and the
        # view file is actually intact (readable + parseable) — no-op.
        :ok

      {nil, true} ->
        # The sidecar is gone but the view file survives intact (hand-deleted,
        # crash mid-write, or `Valea.Mail.Index.rebuild/2`'s raw-fallback
        # self-heal racing a live land). A missing sidecar alone must NOT
        # be read as "unclaimed": the view is the source of truth for
        # occurrence membership (`folders:`/`flags:` set by
        # `refresh_folders/5` since it was landed) — overwriting it here
        # would silently wipe that back to `folders: []`. We cannot verify
        # without the sidecar that this view holds the SAME content as
        # `raw` (a genuine different-content collision at this exact
        # msg_id is therefore undetectable on this path, and can't trigger
        # the 8->16->64 collision-extension) — but regenerating the
        # sidecar from `raw`'s own fingerprint re-establishes the
        # invariant going forward, and the common case (a lost sidecar for
        # THIS content) self-heals correctly.
        write_fingerprint_sidecar!(root, account, msg_id, fingerprint)

      _no_view_or_different_fingerprint ->
        write_view!(root, account, msg_id, message, fingerprint)
    end

    {:ok, %{msg_id: msg_id, fingerprint: fingerprint, has_attachments: message.attachments != []}}
  end

  # No hint: run the full 8/16/64 collision resolution. A hint is trusted
  # when unclaimed or already matching; otherwise it's discarded in favor
  # of the same resolution (never a blind overwrite of different content).
  defp resolve_id(root, account, message, raw, fingerprint, nil),
    do: resolve_msg_id(root, account, message, raw, fingerprint)

  defp resolve_id(root, account, message, raw, fingerprint, hint) when is_binary(hint) do
    case fingerprint_of(root, account, hint) do
      nil -> hint
      ^fingerprint -> hint
      _different -> resolve_msg_id(root, account, message, raw, fingerprint)
    end
  end

  # 8 -> 16 -> 64 hex, exactly like the msg_id_test's collision-extension
  # contract for the old flat design (mail-as-maildir design spec,
  # §Two-level identity: "hash-extension collision rule kept"). A candidate
  # is acceptable when its sidecar is empty (unclaimed) or already holds
  # THIS fingerprint (re-landing the same content); a full 64-hex clash
  # against different content is astronomically unlikely but degrades to
  # reusing the 64-hex id rather than raising.
  defp resolve_msg_id(root, account, message, raw, fingerprint) do
    base = MessageFile.msg_id(message, raw)
    prefix = String.replace_suffix(base, String.slice(fingerprint, 0, 8), "")

    Enum.find_value([8, 16, 64], fn n ->
      candidate = prefix <> String.slice(fingerprint, 0, n)

      case fingerprint_of(root, account, candidate) do
        nil -> candidate
        ^fingerprint -> candidate
        _other -> nil
      end
    end) || prefix <> fingerprint
  end

  defp write_view!(root, account, msg_id, message, fingerprint) do
    attachments = write_attachments!(root, account, msg_id, message.attachments)

    bytes =
      MessageFile.render(message, %{
        msg_id: msg_id,
        account: account,
        folders: [],
        flags: "",
        attachments: attachments
      })

    view_path = view_abs_path(root, account, msg_id)
    File.mkdir_p!(Path.dirname(view_path))
    atomic_write!(view_path, bytes)

    write_fingerprint_sidecar!(root, account, msg_id, fingerprint)
  end

  defp write_fingerprint_sidecar!(root, account, msg_id, fingerprint) do
    fp_path = fingerprint_sidecar_path(root, account, msg_id)
    File.mkdir_p!(Path.dirname(fp_path))
    atomic_write!(fp_path, fingerprint)
    :ok
  end

  # A view is "ok" when it's both present AND actually parseable — a view
  # file can go missing (see `land/4`'s sidecar-loss handling) or become
  # corrupt independently of the sidecar (partial write, manual edit gone
  # wrong); either way `land/4` must not treat it as already-landed, or a
  # corrupt file would sit there forever with a sidecar vouching for it.
  defp view_ok?(root, account, msg_id) do
    case File.read(view_abs_path(root, account, msg_id)) do
      {:ok, bytes} -> match?({:ok, _}, MessageFile.parse(bytes))
      {:error, _reason} -> false
    end
  end

  defp write_attachments!(_root, _account, _msg_id, []), do: []

  defp write_attachments!(root, account, msg_id, attachments) do
    dir = attachments_abs_dir(root, account, msg_id)
    File.mkdir_p!(dir)

    {landed, _used} =
      Enum.reduce(attachments, {[], MapSet.new()}, fn attachment, {acc, used} ->
        filename = dedupe_filename(MessageFile.sanitize_filename(attachment.filename), used)
        atomic_write!(Path.join(dir, filename), attachment.content)

        entry = %{
          filename: filename,
          path: Path.join(attachments_rel_dir(account, msg_id), filename),
          bytes: byte_size(attachment.content)
        }

        {[entry | acc], MapSet.put(used, filename)}
      end)

    Enum.reverse(landed)
  end

  defp dedupe_filename(name, used) do
    if MapSet.member?(used, name) do
      {base, ext} = split_ext(name)

      Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn i ->
        candidate = "#{base}-#{i}#{ext}"
        unless MapSet.member?(used, candidate), do: candidate
      end)
    else
      name
    end
  end

  defp split_ext(name) do
    ext = Path.extname(name)
    {Path.basename(name, ext), ext}
  end

  @doc """
  The fingerprint recorded in the `.fingerprints` sidecar for
  `(account, msg_id)`, or `nil` when no sidecar exists (unclaimed, or a
  view that was never landed). Exposed so a caller that's about to re-land
  bytes under a msg_id it already trusts (`SyncPass.restore_missing/4`,
  restoring an out-of-band-deleted local file) can verify the re-fetched
  bytes are STILL the same content BEFORE calling `land/4` — `land/4`'s own
  `msg_id_hint` fallback (see the moduledoc) resolves a BRAND NEW msg_id
  for mismatched content and writes a view for it, which is exactly right
  when the caller wants that new id back, but wrong when the caller only
  wanted to confirm identity and would otherwise leave that fresh view
  orphaned (nothing yet references it) on a mismatch it was going to reject
  anyway.
  """
  @spec stored_fingerprint(String.t(), String.t(), String.t()) :: String.t() | nil
  def stored_fingerprint(root, account, msg_id)
      when is_binary(root) and is_binary(account) and is_binary(msg_id),
      do: fingerprint_of(root, account, msg_id)

  # -- refresh_folders ------------------------------------------------------

  @doc """
  Rewrites the view's `folders:`/`flags:` frontmatter lines in place
  (byte-preserving patch via `MessageFile.patch_frontmatter/2` — see that
  function's moduledoc for why a full re-render isn't needed), reflecting
  every folder this msg_id currently occurs in. `folders` is sorted +
  deduped before rendering (the spec's "sorted list of the occurrences'
  folders"); `flags_union` is rendered verbatim — the caller has already
  computed the informational union across occurrences. A missing view
  file is a silent no-op: nothing to refresh.
  """
  @spec refresh_folders(String.t(), String.t(), String.t(), [String.t()], String.t()) :: :ok
  def refresh_folders(root, account, msg_id, folders, flags_union)
      when is_binary(root) and is_binary(account) and is_binary(msg_id) and is_list(folders) and
             is_binary(flags_union) do
    path = view_abs_path(root, account, msg_id)

    case File.read(path) do
      {:ok, bytes} ->
        {:ok, patched} =
          MessageFile.patch_frontmatter(bytes, %{
            "folders" => MessageFile.render_string_list(Enum.sort(Enum.uniq(folders))),
            "flags" => MessageFile.yaml_string(flags_union)
          })

        atomic_write!(path, patched)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # -- remove_occurrence ----------------------------------------------------

  @doc """
  Removes bookkeeping for one occurrence of `msg_id` going away.
  `remaining` is the occurrence count left across every folder AFTER this
  removal (the caller's job — this module has no occurrence table of its
  own): `0` garbage-collects the shared view, its attachments, and its
  fingerprint sidecar (a msg_id with nothing left pointing to it can be
  freely reused for new content, per `land/4`'s idempotency check); any
  other value keeps the view untouched — other occurrences still need it,
  and their own `folders:`/`flags:` refresh is a separate
  `refresh_folders/5` call the caller makes with the updated membership.
  Idempotent: removing an already-absent view is not an error.
  """
  @spec remove_occurrence(String.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def remove_occurrence(root, account, msg_id, 0)
      when is_binary(root) and is_binary(account) and is_binary(msg_id) do
    File.rm(view_abs_path(root, account, msg_id))
    File.rm_rf(attachments_abs_dir(root, account, msg_id))
    File.rm(fingerprint_sidecar_path(root, account, msg_id))
    :ok
  end

  def remove_occurrence(root, account, msg_id, remaining)
      when is_binary(root) and is_binary(account) and is_binary(msg_id) and
             is_integer(remaining) and remaining > 0,
      do: :ok

  # -- view_rel_path --------------------------------------------------------

  @doc "`sources/mail/<account>/views/messages/<msg_id>.md`, relative to the workspace root."
  @spec view_rel_path(String.t(), String.t()) :: String.t()
  def view_rel_path(account, msg_id) when is_binary(account) and is_binary(msg_id) do
    Path.join(["sources", "mail", account, "views", "messages", "#{msg_id}.md"])
  end

  # -- paths ----------------------------------------------------------------

  defp views_dir(account), do: Path.join(["sources", "mail", account, "views"])

  defp attachments_rel_dir(account, msg_id),
    do: Path.join([views_dir(account), "attachments", msg_id])

  defp fingerprints_rel_dir(account), do: Path.join(views_dir(account), ".fingerprints")

  defp view_abs_path(root, account, msg_id), do: Path.join(root, view_rel_path(account, msg_id))

  defp attachments_abs_dir(root, account, msg_id),
    do: Path.join(root, attachments_rel_dir(account, msg_id))

  defp fingerprint_sidecar_path(root, account, msg_id),
    do: Path.join(root, Path.join(fingerprints_rel_dir(account), msg_id))

  defp fingerprint_of(root, account, msg_id) do
    case File.read(fingerprint_sidecar_path(root, account, msg_id)) do
      {:ok, content} -> String.trim(content)
      {:error, _reason} -> nil
    end
  end

  defp atomic_write!(abs_path, bytes) do
    tmp = abs_path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)
    File.rename!(tmp, abs_path)
  end
end
