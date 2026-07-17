defmodule Valea.Mail.FakeMailTransportTest do
  use ExUnit.Case, async: false

  # Self-test of the fake Transport harness (test/support/fake_mail_transport.ex)
  # that later mail tasks (T8's sync pass, T11's mailbox ops) script against —
  # same spirit as fake_imap_server_test.exs's self-test of its harness.

  setup do
    name = :"fake_mail_transport_#{System.unique_integer([:positive])}"
    {:ok, _pid} = FakeMailTransport.start_link(name: name)
    %{name: name}
  end

  test "connect always targets the default-named instance" do
    {:ok, _pid} = FakeMailTransport.start_link([])

    FakeMailTransport.script([
      {:connect, :_, {:ok, FakeMailTransport}}
    ])

    assert {:ok, FakeMailTransport} =
             FakeMailTransport.connect(%{host: "h", port: 993, username: "u"}, "secret", [])

    assert [{:connect, [%{host: "h"}, "secret", []]}] = FakeMailTransport.calls()
  end

  test "matches on exact args list, :_ wildcards, and logs calls in order", %{name: name} do
    # Bypasses connect (which always targets the default instance — see the
    # test above) by calling other callbacks directly with `conn = name`.
    FakeMailTransport.script(name, [
      {:select, [:_, "Sorted"], {:ok, %{uidvalidity: 7, uidnext: 42}}},
      {:select, :_, {:error, :no_such_folder}}
    ])

    assert {:ok, %{uidvalidity: 7}} = FakeMailTransport.select(name, "Sorted")
    assert {:error, :no_such_folder} = FakeMailTransport.select(name, "Nope")

    assert [
             {:select, [^name, "Sorted"]},
             {:select, [^name, "Nope"]}
           ] = FakeMailTransport.calls(name)
  end

  test "a function args_matcher and a function result both receive the call's args", %{
    name: name
  } do
    FakeMailTransport.script(name, [
      {:uid_fetch_full, fn [_conn, uid] -> uid > 100 end,
       fn [_conn, uid] -> {:ok, "uid=#{uid}"} end}
    ])

    assert {:ok, "uid=101"} = FakeMailTransport.uid_fetch_full(name, 101)
  end

  test "an unscripted call raises loudly rather than returning a made-up value", %{name: name} do
    FakeMailTransport.script(name, [])

    assert_raise RuntimeError, ~r/no script step matches logout/, fn ->
      FakeMailTransport.logout(name)
    end
  end
end
