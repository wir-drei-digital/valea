defmodule Valea.Mail.SyncPassTest do
  use ExUnit.Case, async: false

  alias Valea.Mail.SyncPass

  # GUTTED in Task 6 alongside `lib/valea/mail/sync_pass.ex` — see that
  # module's moduledoc. Every old case here exercised the deleted
  # `MessageFile.render(message, %{uid:, status:, source:, ...})`
  # landing pipeline (folder walking, attachment writes, dedupe,
  # `inbox.md` generation, `Store.record_outcome/outcomes`), none of
  # which survives `Task 6`'s `MessageFile`/`Store` changes. Task 7
  # rewrites `SyncPass` wholesale around `Valea.Mail.Views`/
  # `Valea.Mail.Index` and replaces this file in full; until then, these
  # are the only cases that make sense against the temporary stub —
  # they exist so `Valea.Mail.Engine`'s connect/auth-failed contract
  # (which the stub deliberately preserves; see `engine_test.exs`) has
  # matching direct coverage at the `SyncPass` level too.

  defp settings do
    %{imap: %{host: "imap.example.test", port: 993, username: "mara@example.com"}}
  end

  defp run(overrides \\ %{}) do
    SyncPass.run(
      Map.merge(
        %{
          root: "/irrelevant",
          settings: settings(),
          credential: fn -> "app-password" end,
          transport: FakeMailTransport
        },
        overrides
      )
    )
  end

  setup do
    {:ok, _} = FakeMailTransport.start_link()
    :ok
  end

  test "a successful connect logs out and reports a no-op pass" do
    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:logout, :_, :ok}
    ])

    assert {:ok, %{new_messages: 0, errors: []}} = run()
    assert Enum.any?(FakeMailTransport.calls(), &match?({:logout, _}, &1))
  end

  test "auth failure propagates verbatim" do
    FakeMailTransport.script([{:connect, :_, {:error, :auth_failed}}])

    assert {:error, :auth_failed} = run()
  end

  test "any other connect failure propagates verbatim" do
    FakeMailTransport.script([{:connect, :_, {:error, :some_other_reason}}])

    assert {:error, :some_other_reason} = run()
  end

  test "the credential closure is called exactly once, at the connect boundary" do
    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}},
      {:logout, :_, :ok}
    ])

    test_pid = self()
    credential = fn -> send(test_pid, :credential_called) && "app-password" end

    assert {:ok, _} = run(%{credential: credential})
    assert_received :credential_called
    refute_received :credential_called
  end
end
