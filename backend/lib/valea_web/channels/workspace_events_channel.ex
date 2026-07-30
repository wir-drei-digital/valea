defmodule ValeaWeb.WorkspaceEventsChannel do
  use Phoenix.Channel

  @impl true
  def join("workspace:events", _payload, socket) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")
    Phoenix.PubSub.subscribe(Valea.PubSub, "calendar")
    Phoenix.PubSub.subscribe(Valea.PubSub, "git")
    {:ok, socket}
  end

  @impl true
  def handle_info({:workspace_opened, info, generation}, socket) do
    push(socket, "workspace", %{
      "open" => true,
      "name" => info.name,
      "path" => info.path,
      "generation" => generation
    })

    {:noreply, socket}
  end

  def handle_info({:workspace_closed}, socket) do
    push(socket, "workspace", %{"open" => false})
    {:noreply, socket}
  end

  def handle_info({:icm_changed}, socket) do
    push(socket, "icm_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:mounts_changed}, socket) do
    push(socket, "mounts_changed", %{})
    {:noreply, socket}
  end

  def handle_info({:mail_status_changed, slug, status}, socket) do
    push(socket, "mail_status", stringify(status) |> Map.put("account", slug))
    {:noreply, socket}
  end

  def handle_info({:mail_sync_started, slug}, socket) do
    push(socket, "mail_sync", %{
      "phase" => "started",
      "newMessages" => 0,
      "newUnread" => 0,
      "account" => slug
    })

    {:noreply, socket}
  end

  # `newUnread` is ADDITIVE (mail full-client plan, M5 task 13): the newly
  # landed INBOX occurrences without `S` this pass, which the frontend's
  # new-mail notification keys off. `newMessages` keeps its exact previous
  # meaning and value for every existing consumer. Read with a default so an
  # event built before the field existed (or by any other broadcaster) still
  # pushes rather than crashing the channel.
  def handle_info({:mail_sync_finished, slug, %{new_messages: new_messages} = result}, socket) do
    push(socket, "mail_sync", %{
      "phase" => "finished",
      "newMessages" => new_messages,
      "newUnread" => Map.get(result, :new_unread, 0),
      "account" => slug
    })

    {:noreply, socket}
  end

  # A freshly authorized (or provider-ROTATED) OAuth2 refresh token, on its way
  # to the desktop client's OS keychain — the token's only durable home, since
  # `Valea.Mail.Engine` deliberately never writes one to disk (see its
  # §OAuth2 accounts). This is the one push in this channel that carries a
  # SECRET: it goes over the loopback socket the control token already gates,
  # it is never logged (`push/3` logs nothing, and no handler here inspects a
  # payload), and in a browser-dev session the frontend's keychain write is a
  # documented no-op so the token simply stays in Engine RAM.
  def handle_info({:mail_oauth_token, slug, token}, socket) do
    push(socket, "mail_oauth", %{"account" => slug, "refreshToken" => token})
    {:noreply, socket}
  end

  def handle_info({:mail_message_upserted, slug, %{path: path}}, socket) do
    push(socket, "mail_message", %{"path" => path, "account" => slug})
    {:noreply, socket}
  end

  # A draft file changed on disk (`Valea.ICM.Watcher`, debounced per
  # account). Carries the slug and nothing else — the store refetches the
  # workspace-wide drafts list, whose per-row states are ledger-derived
  # backend-side and so can't be patched from a path alone.
  def handle_info({:mail_draft_changed, slug}, socket) do
    push(socket, "mail_draft", %{"account" => slug})
    {:noreply, socket}
  end

  # Calendar pushes (calendar spec F, §RPC surface "Channel pushes"): the
  # spec's channel table is the wire contract — string keys, SNAKE_CASE
  # `event_count` (deliberately NOT mail's camelCase push style).
  def handle_info({:calendar_status_changed, slug, status}, socket) do
    push(socket, "calendar_status", stringify(status) |> Map.put("source", slug))
    {:noreply, socket}
  end

  def handle_info({:calendar_synced, slug, %{event_count: event_count}}, socket) do
    push(socket, "calendar_synced", %{"source" => slug, "event_count" => event_count})
    {:noreply, socket}
  end

  def handle_info({:calendar_local_changed}, socket) do
    push(socket, "calendar_local_changed", %{})
    {:noreply, socket}
  end

  # Every git pass broadcasts its WHOLE status map, so the push is the whole
  # list too — the frontend replaces its rows rather than patching one, which
  # is what makes a repo that stopped being git-backed disappear. The row
  # shape (string keys, no internal bookkeeping) is
  # `Valea.Git.Engine.public_rows/1`'s to decide, shared verbatim with the
  # `git_status` RPC and the cockpit's own block.
  def handle_info({:git_status_changed, statuses}, socket) do
    push(socket, "git_status", %{"repos" => Valea.Git.Engine.public_rows(statuses)})
    {:noreply, socket}
  end

  # `Valea.Mail.Engine.status/0`'s map is atom-keyed; the channel payload
  # must be string keys (mirrors `Valea.Api.Mail.mail_status`'s identical
  # top-level stringify for the RPC surface).
  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)
end
