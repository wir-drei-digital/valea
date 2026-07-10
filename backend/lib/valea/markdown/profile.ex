defmodule Valea.Markdown.Profile do
  @moduledoc """
  The default Valea profile for `Valea.Markdown.ProseMirror`.

  It performs no custom node lifting or serialization: the converter produces
  and consumes only standard CommonMark + GFM shapes (headings, paragraphs,
  bullet/ordered lists, task lists, tables, code blocks, blockquotes, links,
  emphasis/strong/strikethrough, horizontal rules). Every callback is the
  identity/default so nothing magus-specific (callouts, wikilinks, tags,
  `magus://` links, image blocks) is introduced.
  """
  @behaviour Valea.Markdown.ProseMirror.Profile

  @impl true
  def post_process(doc), do: doc

  @impl true
  def node_to_markdown(_node), do: :default

  @impl true
  def inline_node_to_markdown(_node), do: :default
end
