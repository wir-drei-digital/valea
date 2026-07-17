defmodule Valea.Mail.Supervisor do
  @moduledoc """
  One `Valea.Mail.Engine` child per VALID account in `config/mail.yaml`
  (mail-as-maildir design spec E, §Engine — multi-account). An account
  `Valea.Mail.Settings.load/1` drops as invalid gets NO engine at all — its
  problem is surfaced by `Valea.Api.Mail.mail_status` merging `Settings.
  load/1`'s `invalid:` map alongside `Valea.Mail.Engine.statuses/0`, not by
  a degraded Engine.

  Replaces the old singleton `{Valea.Mail.Engine, cfg}` child in
  `Valea.Workspace.Runtime` — started the same way, at the same point in the
  Runtime's lifecycle (before the workspace's own `:workspace_opened`
  broadcast fires), so every account's Engine boots inert and activates off
  that broadcast exactly like the old singleton did (see `Engine`'s
  moduledoc).

  ## Rehashing

  `reload_settings_all/1` is how a settings CHANGE (a fresh
  `setup_mail_account`/`remove_mail_account` RPC landing a new
  `config/mail.yaml`) takes effect without a full workspace reopen:

    * a slug newly present among the valid accounts gets a FRESH Engine
      child, started with `activate: true` (no `:workspace_opened`
      broadcast is coming for it — the workspace opened, and broadcast,
      before this account existed — so it self-activates immediately via
      `{:continue, :activate_now}` instead of waiting);
    * a slug no longer present (removed from the config, or newly invalid)
      has its Engine terminated and deleted;
    * a slug present in both, with UNCHANGED settings, is left running
      untouched — its in-RAM credential and in-flight/idle sync state
      survive a sibling account's setup/removal;
    * a slug present in both with CHANGED settings (e.g. a repeat
      `setup_mail_account` against the same, still-matching identity,
      editing port/folders/sync) is restarted — terminated and rebuilt with
      the fresh `Settings.t()`, again self-activating immediately.
  """
  use Supervisor

  alias Valea.Mail.Engine
  alias Valea.Mail.Settings
  alias Valea.Workspace.Manager

  def start_link(cfg), do: Supervisor.start_link(__MODULE__, cfg, name: __MODULE__)

  @impl true
  def init(%{root: root, generation: generation}) do
    children =
      for {slug, settings} <- valid_accounts(root) do
        engine_child_spec(root, generation, slug, settings)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Rehashes running Engine children to match `root`'s current
  `config/mail.yaml` — see the moduledoc's "Rehashing" section.
  """
  @spec reload_settings_all(String.t()) :: :ok
  def reload_settings_all(root) when is_binary(root) do
    desired = valid_accounts(root)
    desired_slugs = desired |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    running = running_children()
    running_slugs = running |> Map.keys() |> MapSet.new()

    Enum.each(running_slugs, fn slug ->
      unless MapSet.member?(desired_slugs, slug), do: stop_child(slug)
    end)

    generation = Manager.generation()

    Enum.each(desired, fn {slug, settings} ->
      cond do
        not Map.has_key?(running, slug) ->
          start_child(root, generation, slug, settings)

        running[slug] != settings ->
          stop_child(slug)
          start_child(root, generation, slug, settings)

        true ->
          :ok
      end
    end)

    :ok
  end

  # -- children ---------------------------------------------------------------

  defp valid_accounts(root) do
    case Settings.load(root) do
      {:ok, %{accounts: accounts}} -> accounts |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))
      _not_ok -> []
    end
  end

  # `%{slug => Settings.t()}` for every currently-running child, read off the
  # Engine's own state via `status/1`'s settings snapshot — NOT trusted from
  # a locally-cached copy, so a rehash always diffs against what each Engine
  # is actually holding right now.
  defp running_children do
    __MODULE__
    |> Supervisor.which_children()
    |> Enum.filter(fn {_id, pid, _type, _mods} -> is_pid(pid) end)
    |> Map.new(fn {id, pid, _type, _mods} -> {id, GenServer.call(pid, :current_settings)} end)
  end

  defp stop_child(slug) do
    Supervisor.terminate_child(__MODULE__, slug)
    Supervisor.delete_child(__MODULE__, slug)
  end

  defp start_child(root, generation, slug, settings) do
    Supervisor.start_child(__MODULE__, engine_child_spec(root, generation, slug, settings, true))
  end

  defp engine_child_spec(root, generation, slug, settings, activate \\ false) do
    args = %{
      root: root,
      generation: generation,
      account: slug,
      settings: settings,
      activate: activate
    }

    Supervisor.child_spec({Engine, args}, id: slug)
  end
end
