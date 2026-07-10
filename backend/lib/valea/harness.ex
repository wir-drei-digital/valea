defmodule Valea.Harness do
  @moduledoc """
  The harness seam (spec §Harness seam): a harness only describes how to
  spawn its ACP adapter subprocess. Everything else — protocol, permissions,
  transcripts, queue — is generic. Adding an agent is ~10 lines.
  """
  alias Valea.Agents.CommandSpec

  @callback definition() :: %{id: String.t(), name: String.t()}
  @callback acp_command(opts :: map()) :: {:ok, CommandSpec.t()} | {:error, :harness_unavailable}
end
