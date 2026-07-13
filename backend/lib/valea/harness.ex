defmodule Valea.Harness do
  @moduledoc """
  The harness seam (spec §Harness seam): a harness only describes how to
  spawn its ACP adapter subprocess. Everything else — protocol, permissions,
  transcripts, queue — is generic. Adding an agent is ~10 lines.

  `launch/2` is the harness-neutral launch seam Phase 5 wires
  `SessionScope`/`SessionServer` into: given the resolved session scope and
  its session directory, a harness materializes whatever bootstrap files it
  needs and returns the directives the ACP launch path uses to spawn and
  configure the adapter subprocess. `managed_settings` is an in-memory
  permission-posture JSON string (never written to disk) or `nil` for a
  harness that doesn't support a managed-settings channel.
  """
  alias Valea.Agents.CommandSpec

  @callback definition() :: %{id: String.t(), name: String.t()}
  @callback acp_command(opts :: map()) :: {:ok, CommandSpec.t()} | {:error, :harness_unavailable}

  @callback launch(scope :: map(), session_dir :: String.t()) :: {:ok, map()}
end
