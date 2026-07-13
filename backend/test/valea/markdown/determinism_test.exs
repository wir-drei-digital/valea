defmodule Valea.Markdown.DeterminismTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror

  # The starter-mount seed content now lives under the LEGACY (v4,
  # all-are-mounts) template — `priv/workspace_template` is the v5 hidden
  # workspace shape and no longer ships a starter mount at all.
  @template Path.join(:code.priv_dir(:valea), "legacy_workspace_template/mounts/starter")

  # Every seed ICM page — including the four Workflows/*.md pages that carry
  # a leading YAML frontmatter block — must round-trip byte-identically. The
  # mount's own AGENTS.md/CLAUDE.md (self-description, not a curated ICM
  # page a user edits through the ICM page editor) and `prompts/*.md`
  # (reference fragments, same non-ICM-page status) are excluded — the same
  # split the pre-mounts template already drew structurally (AGENTS.md/
  # CLAUDE.md lived at the workspace root; prompts/ was a sibling top-level
  # dir), now re-expressed as an explicit filter since both live inside the
  # mount alongside the real ICM content post-T8.
  @seed_pages @template
              |> Path.join("**/*.md")
              |> Path.wildcard()
              |> Enum.reject(fn path ->
                rel = Path.relative_to(path, @template)
                rel in ["AGENTS.md", "CLAUDE.md"] or String.starts_with?(rel, "prompts/")
              end)

  # For a page with no frontmatter, `Valea.ICM.split_frontmatter/1` returns
  # `{"", md}` and this degenerates to the original whole-file check; for a
  # frontmatter page, the block is left untouched (it never goes through the
  # markdown converter) and only the body is round-tripped.
  for path <- @seed_pages, rel = Path.relative_to(path, @template) do
    test "round-trips seed page #{rel} byte-identically" do
      md = File.read!(unquote(path))
      {block, body} = Valea.ICM.split_frontmatter(md)
      {:ok, pm} = ProseMirror.from_markdown(body)
      {:ok, out} = ProseMirror.to_markdown(pm)
      # second pass must be a fixed point even if the first normalizes
      {:ok, pm2} = ProseMirror.from_markdown(out)
      {:ok, out2} = ProseMirror.to_markdown(pm2)
      assert out2 == out

      assert block <> out == md,
             "seed page #{unquote(rel)} does not round-trip byte-identically; " <>
               "either fix the serializer or canonicalize the seed page in the same commit"
    end
  end

  test "template has seed pages (guard against silent wildcard miss)" do
    assert length(@seed_pages) >= 12
  end
end
