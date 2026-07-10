defmodule Valea.Agents.CommandSpec do
  @moduledoc "How to spawn an agent adapter: absolute cmd + argv, no shell."
  @enforce_keys [:cmd]
  defstruct cmd: nil, args: [], env: %{}

  @type t :: %__MODULE__{cmd: String.t(), args: [String.t()], env: map()}
end
