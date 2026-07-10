defmodule Valea.Markdown.DeterminismTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror

  @template Path.join(:code.priv_dir(:valea), "workspace_template/icm")

  # Every seed page — including the four Workflows/*.md pages that carry a
  # leading YAML frontmatter block — must round-trip byte-identically. For a
  # page with no frontmatter, `Valea.ICM.split_frontmatter/1` returns
  # `{"", md}` and this degenerates to the original whole-file check; for a
  # frontmatter page, the block is left untouched (it never goes through the
  # markdown converter) and only the body is round-tripped.
  for path <-
        Path.wildcard(
          Path.join(Path.join(:code.priv_dir(:valea), "workspace_template/icm"), "**/*.md")
        ),
      rel = Path.relative_to(path, Path.join(:code.priv_dir(:valea), "workspace_template/icm")) do
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
    assert length(Path.wildcard(Path.join(@template, "**/*.md"))) >= 12
  end
end
