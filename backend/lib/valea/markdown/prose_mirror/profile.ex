# Vendored from magus (lib/magus/markdown/prose_mirror/profile.ex) on 2026-07-10 — keep divergences minimal.
defmodule Valea.Markdown.ProseMirror.Profile do
  @moduledoc "Hook for domain-specific ProseMirror node lifting/serialization."
  @callback post_process(doc :: map()) :: map()
  @callback node_to_markdown(node :: map()) :: {:ok, String.t()} | :default
  @callback inline_node_to_markdown(node :: map()) :: {:ok, String.t()} | :default
end
