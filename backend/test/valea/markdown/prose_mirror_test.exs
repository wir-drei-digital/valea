# Vendored + adapted from magus (test/magus/markdown/prose_mirror_test.exs) on 2026-07-10.
# Magus-specific profile cases (callouts, wikilinks, tags, magus:// links,
# image blocks) were pruned; the CommonMark/GFM matrix is kept. Assertions were
# adapted to Valea's API: `to_markdown/2` returns `{:ok, markdown}`.
defmodule Valea.Markdown.ProseMirrorTest do
  use ExUnit.Case, async: true
  alias Valea.Markdown.ProseMirror

  test "from_markdown/1 converts standard markdown (default profile)" do
    assert {:ok, %{"type" => "doc", "content" => content}} =
             ProseMirror.from_markdown("# Hi\n\n- [x] done")

    assert Enum.any?(content, &(&1["type"] == "heading"))
    assert Enum.any?(content, &(&1["type"] == "taskList"))
  end

  test "to_markdown/1 round-trips a tasklist" do
    {:ok, doc} = ProseMirror.from_markdown("- [ ] a\n- [x] b")
    assert ProseMirror.to_markdown(doc) == {:ok, "- [ ] a\n- [x] b"}
  end

  test "default profile does not lift fenced code blocks" do
    {:ok, doc} = ProseMirror.from_markdown("```elixir\nx = 1\n```")
    assert Enum.any?(doc["content"], &(&1["type"] == "codeBlock"))
    refute Enum.any?(doc["content"], &(&1["type"] == "calloutBlock"))
  end

  describe "mark coalescing (C1)" do
    defp rt(md), do: elem(ProseMirror.to_markdown(elem(ProseMirror.from_markdown(md), 1)), 1)

    test "bold spanning a code span round-trips and converges" do
      assert rt("**a `b` c**") == "**a `b` c**"
      # idempotent / converges
      assert rt(rt("**a `b` c**")) == "**a `b` c**"
    end

    test "emphasis spanning a link round-trips" do
      assert rt("*see [docs](https://x.com) now*") == "*see [docs](https://x.com) now*"
    end

    test "bold link round-trips" do
      assert rt("[**bold**](https://x.com)") == "[**bold**](https://x.com)"
    end

    test "simple marks unchanged" do
      assert rt("**bold**") == "**bold**"
      assert rt("*italic*") == "*italic*"
      assert rt("`code`") == "`code`"
      assert rt("[l](https://x.com)") == "[l](https://x.com)"
      assert rt("a **b** c") == "a **b** c"
      assert rt("**bold** and *italic* and `code`") == "**bold** and *italic* and `code`"
    end

    test "strikethrough round-trips" do
      assert rt("~~gone~~") == "~~gone~~"
    end
  end

  describe "block structures" do
    test "headings round-trip at multiple levels" do
      assert rt("# H1") == "# H1"
      assert rt("## H2") == "## H2"
      assert rt("### H3") == "### H3"
    end

    test "bullet list round-trips" do
      assert rt("- one\n- two\n- three") == "- one\n- two\n- three"
    end

    test "ordered list round-trips" do
      assert rt("1. one\n2. two\n3. three") == "1. one\n2. two\n3. three"
    end

    test "blockquote round-trips with empty quote lines" do
      assert rt("> line one\n>\n> line two") == "> line one\n>\n> line two"
    end

    test "fenced code block round-trips with language" do
      assert rt("```elixir\nx = 1\n```") == "```elixir\nx = 1\n```"
    end

    test "fenced code block round-trips without language" do
      assert rt("```\nplain\n```") == "```\nplain\n```"
    end

    test "horizontal rule round-trips" do
      assert rt("a\n\n---\n\nb") == "a\n\n---\n\nb"
    end

    test "table round-trips" do
      md = "| a | b |\n| --- | --- |\n| 1 | 2 |"
      assert rt(md) == md
    end
  end

  describe "image titles (I1)" do
    test "title round-trips" do
      assert rt("![alt](https://x.com/i.png \"My Title\")") ==
               "![alt](https://x.com/i.png \"My Title\")"
    end

    test "no title unchanged" do
      assert rt("![alt](https://x.com/i.png)") == "![alt](https://x.com/i.png)"
    end
  end
end
