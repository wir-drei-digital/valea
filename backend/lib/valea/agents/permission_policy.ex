defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  Stub — Task 11 implements the real deny/allow/ask policy.

  Until then every permission request is surfaced to the human (`:ask`). The
  full contract (returned by `decide/2`) is one of:

    * `:ask`            — surface the request to the UI, wait for a human answer
    * `{:allow, kind}`  — auto-answer the codec with `kind` ("allow_once")
    * `{:deny, kind}`   — auto-answer the codec with `kind` ("reject_once")
  """

  @spec decide(map(), map()) :: :ask | {:allow, String.t()} | {:deny, String.t()}
  def decide(_permission_item, _ctx), do: :ask
end
