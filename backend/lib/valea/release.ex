defmodule Valea.Release do
  @moduledoc """
  Release tasks. Inside a release (e.g. the desktop sidecar) there is no Mix,
  so migrations run through Ecto.Migrator directly.
  """
  @app :valea

  def migrate do
    Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
