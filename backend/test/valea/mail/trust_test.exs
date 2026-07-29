defmodule Valea.Mail.TrustTest do
  use ExUnit.Case, async: true

  alias Valea.Mail.Trust

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "valea-trust-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "missing file -> empty list, nobody trusted (fail-closed)", %{root: root} do
    assert Trust.list(root) == []
    refute Trust.trusted?(root, "a@b.c")
    refute Trust.trusted?(root, nil)
  end

  test "set_trusted round-trips, case-insensitively, idempotently", %{root: root} do
    assert :ok = Trust.set_trusted(root, "Priya@Example.COM", true)
    assert Trust.list(root) == ["priya@example.com"]
    assert Trust.trusted?(root, "priya@example.com")
    assert Trust.trusted?(root, "PRIYA@example.com")

    # Idempotent add, then remove.
    assert :ok = Trust.set_trusted(root, "priya@example.com", true)
    assert Trust.list(root) == ["priya@example.com"]
    assert :ok = Trust.set_trusted(root, "priya@example.com", false)
    assert Trust.list(root) == []
    refute Trust.trusted?(root, "priya@example.com")
  end

  test "invalid addresses are refused and never written", %{root: root} do
    assert {:error, :invalid_email} = Trust.set_trusted(root, "no-at-sign", true)
    assert {:error, :invalid_email} = Trust.set_trusted(root, "a b@c.d", true)
    assert {:error, :invalid_email} = Trust.set_trusted(root, "x@y\n.z", true)
    refute File.exists?(Path.join([root, "config", "mail-trusted-senders.json"]))
  end

  test "a hand-broken file degrades to empty rather than raising", %{root: root} do
    path = Path.join([root, "config", "mail-trusted-senders.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")
    assert Trust.list(root) == []

    # Non-string entries in a valid array are filtered, not crashed on.
    File.write!(path, ~s([1, "ok@x.y", {"a": 1}]))
    assert Trust.list(root) == ["ok@x.y"]
  end
end
