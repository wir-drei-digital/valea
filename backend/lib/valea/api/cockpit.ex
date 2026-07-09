defmodule Valea.Api.Cockpit do
  @moduledoc """
  Data-layer-less Ash resource exposing the seeded Cockpit narrative over RPC.

  Wraps `Valea.Cockpit`; the underlying module already returns a string-keyed,
  JSON-ready map.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Cockpit")
  end

  actions do
    action :today, :map do
      run fn _input, _ctx ->
        {:ok, today} = Valea.Cockpit.today()
        {:ok, today}
      end
    end
  end
end
