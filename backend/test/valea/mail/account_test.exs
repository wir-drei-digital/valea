defmodule Valea.Mail.AccountTest do
  # Pure filesystem work under a per-test tmp root — no Repo, no shared state.
  use ExUnit.Case, async: true

  alias Valea.Mail.Account

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "valea-account-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp identity, do: %{host: "imap.example.test", username: "mara@example.com"}

  defp write_account!(root, slug, body) do
    path = Account.account_path(root, slug)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  # -- write_if_absent!/4 --------------------------------------------------

  describe "write_if_absent!/4" do
    test "records the separator alongside the identity", %{root: root} do
      assert :ok = Account.write_if_absent!(root, "mara", identity(), ";")

      body = File.read!(Account.account_path(root, "mara"))
      assert body =~ ~s(host: "imap.example.test")
      assert body =~ ~s(username: "mara@example.com")
      assert body =~ ~s(maildir_separator: ";")

      assert Account.verify(root, "mara", identity()) == :ok
      assert Account.separator(root, "mara") == {:ok, ";"}
    end

    test "a `:` store round-trips too", %{root: root} do
      assert :ok = Account.write_if_absent!(root, "mara", identity(), ":")
      assert Account.separator(root, "mara") == {:ok, ":"}
    end

    test "never rewrites an existing file — the separator is claimed once", %{root: root} do
      :ok = Account.write_if_absent!(root, "mara", identity(), ":")
      original = File.read!(Account.account_path(root, "mara"))

      assert :ok = Account.write_if_absent!(root, "mara", identity(), ";")

      assert File.read!(Account.account_path(root, "mara")) == original
      assert Account.separator(root, "mara") == {:ok, ":"}
    end

    test "refuses a separator outside the two-value vocabulary", %{root: root} do
      assert_raise FunctionClauseError, fn ->
        Account.write_if_absent!(root, "mara", identity(), "|")
      end

      refute File.exists?(Account.account_path(root, "mara"))
    end
  end

  # -- separator/2 ---------------------------------------------------------

  describe "separator/2" do
    test "absent .account file is the legacy rule: `:`", %{root: root} do
      assert Account.separator(root, "mara") == {:ok, ":"}
    end

    test "a legacy file WITHOUT the key is `:` — never OS-defaulted", %{root: root} do
      write_account!(root, "mara", ~s(host: "imap.example.test"\nusername: "mara@example.com"\n))

      assert Account.separator(root, "mara") == {:ok, ":"}
    end

    test "a value outside the vocabulary fails closed", %{root: root} do
      write_account!(
        root,
        "mara",
        ~s(host: "h"\nusername: "u"\nmaildir_separator: "|"\n)
      )

      assert Account.separator(root, "mara") == {:error, :invalid_separator}
    end

    test "a non-string value fails closed", %{root: root} do
      write_account!(root, "mara", ~s(host: "h"\nusername: "u"\nmaildir_separator: 5\n))

      assert Account.separator(root, "mara") == {:error, :invalid_separator}
    end

    test "an unparseable file fails closed (never legacy-defaulted)", %{root: root} do
      write_account!(root, "mara", "\tnot: [valid: yaml\n")

      assert Account.separator(root, "mara") == {:error, :invalid_separator}
    end
  end

  # -- separator is store metadata, NOT identity ---------------------------

  describe "verify/3 is untouched by the separator" do
    test "a differing separator is not an identity mismatch", %{root: root} do
      :ok = Account.write_if_absent!(root, "mara", identity(), ";")

      assert Account.verify(root, "mara", identity()) == :ok
    end

    test "a differing host still mismatches, separator or not", %{root: root} do
      :ok = Account.write_if_absent!(root, "mara", identity(), ";")

      assert Account.verify(root, "mara", %{host: "other.test", username: "mara@example.com"}) ==
               {:error, :identity_mismatch}
    end
  end
end
