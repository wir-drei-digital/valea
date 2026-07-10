defmodule Valea.Markdown.DeterminismTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror

  @template Path.join(:code.priv_dir(:valea), "workspace_template/icm")

  # Workflow pages carry YAML frontmatter, which the converter does not yet
  # handle. Task 4 extends the contract to frontmatter pages.
  @frontmatter_pages [
    "Workflows/New Inquiry Triage.md",
    "Workflows/Post-Session Follow-up.md",
    "Workflows/Session Prep Brief.md",
    "Workflows/Weekly Admin Review.md"
  ]

  for path <-
        Path.wildcard(
          Path.join(Path.join(:code.priv_dir(:valea), "workspace_template/icm"), "**/*.md")
        ),
      rel = Path.relative_to(path, Path.join(:code.priv_dir(:valea), "workspace_template/icm")),
      rel not in @frontmatter_pages do
    test "round-trips seed page #{rel} byte-identically" do
      md = File.read!(unquote(path))
      {:ok, pm} = ProseMirror.from_markdown(md)
      {:ok, out} = ProseMirror.to_markdown(pm)
      # second pass must be a fixed point even if the first normalizes
      {:ok, pm2} = ProseMirror.from_markdown(out)
      {:ok, out2} = ProseMirror.to_markdown(pm2)
      assert out2 == out

      assert out == md,
             "seed page #{unquote(rel)} does not round-trip byte-identically; " <>
               "either fix the serializer or canonicalize the seed page in the same commit"
    end
  end

  test "template has seed pages (guard against silent wildcard miss)" do
    assert length(Path.wildcard(Path.join(@template, "**/*.md"))) >= 12
  end
end
