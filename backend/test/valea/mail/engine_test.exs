defmodule Valea.Mail.EngineTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.Engine

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "vmail-engine-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_settings!(root, host, username) do
    File.write!(Path.join(root, "config/mail.yaml"), """
    account: #{username}
    imap:
      host: #{host}
      port: 993
      username: #{username}
    """)
  end

  defp start_engine!(root, generation) do
    start_supervised!({Engine, %{root: root, generation: generation}})
  end

  test "boots inert: state inactive, sync_now refuses", %{root: root} do
    start_engine!(root, 1)

    assert %{
             state: "inactive",
             configured: false,
             credential: "missing",
             last_sync_at: nil,
             last_error: nil,
             account: nil
           } = Engine.status()

    assert Engine.sync_now() == {:error, :inactive}
  end

  test "a mismatched-generation broadcast is ignored", %{root: root} do
    start_engine!(root, 2)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 1}
    )

    # synchronize with the (ignored) message having been processed
    assert Engine.status().state == "inactive"
  end

  test "activates only on its own generation's workspace_opened broadcast", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 3)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 3}
    )

    status = Engine.status()
    assert status.state == "idle"
    assert status.configured == true
    assert status.account == "mara@example.com"
  end

  test "placeholder settings (not-yet-configured) -> configured false, sync_now not_configured",
       %{
         root: root
       } do
    write_settings!(root, "imap.example.com", "mara@example.com")
    start_engine!(root, 5)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 5}
    )

    status = Engine.status()
    assert status.configured == false
    assert Engine.sync_now() == {:error, :not_configured}
  end

  test "configured but no credential -> sync_now no_credential", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 6)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 6}
    )

    assert Engine.sync_now() == {:error, :no_credential}
  end

  test "set_credential flips status and broadcasts :mail_status_changed", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 7)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 7}
    )

    assert Engine.status().credential == "missing"

    Phoenix.PubSub.subscribe(Valea.PubSub, "mail")
    assert :ok = Engine.set_credential("hunter2-secret")

    assert_receive {:mail_status_changed, status}
    assert status.credential == "present"
    assert Engine.status().credential == "present"
  end

  test "env fallback: VALEA_MAIL_PASSWORD is picked up at activation when unset previously", %{
    root: root
  } do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    System.put_env("VALEA_MAIL_PASSWORD", "dev-fallback-secret")
    on_exit(fn -> System.delete_env("VALEA_MAIL_PASSWORD") end)

    start_engine!(root, 8)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 8}
    )

    assert Engine.status().credential == "present"
  end

  test "no env fallback when VALEA_MAIL_PASSWORD is unset", %{root: root} do
    System.delete_env("VALEA_MAIL_PASSWORD")
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 9)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 9}
    )

    assert Engine.status().credential == "missing"
  end

  test "redaction: :sys.get_state never exposes the raw credential", %{root: root} do
    write_settings!(root, "imap.fastmail.com", "mara@example.com")
    start_engine!(root, 10)

    Phoenix.PubSub.broadcast(
      Valea.PubSub,
      "workspace",
      {:workspace_opened, %{path: root, name: "w"}, 10}
    )

    secret = "super-duper-secret-password-XYZ"
    :ok = Engine.set_credential(secret)

    dump =
      Valea.Mail.Engine
      |> :sys.get_state()
      |> inspect(limit: :infinity, printable_limit: :infinity)

    refute dump =~ secret
  end

  test "retry_ops/1 is an unimplemented stub this task", %{root: root} do
    start_engine!(root, 11)
    assert Engine.retry_ops("some-run-id") == {:error, :not_implemented}
  end
end
