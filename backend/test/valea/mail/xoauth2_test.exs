defmodule Valea.Mail.Xoauth2Test do
  use ExUnit.Case, async: true

  alias Valea.Mail.Xoauth2

  # Goldens, spelled out rather than recomputed with the implementation's own
  # expression: an encoding bug must not be able to agree with itself. Decoded
  # back below so the layout is readable in the failure output too.

  test "builds the XOAUTH2 initial client response byte for byte" do
    assert Xoauth2.response("mara@example.com", "ya29.TOKEN") ==
             "dXNlcj1tYXJhQGV4YW1wbGUuY29tAWF1dGg9QmVhcmVyIHlhMjkuVE9LRU4BAQ=="
  end

  test "the decoded response is user, then Bearer token, then two SOH separators" do
    assert {:ok, decoded} =
             Xoauth2.response("mara@example.com", "ya29.TOKEN") |> Base.decode64()

    assert decoded == "user=mara@example.com\x01auth=Bearer ya29.TOKEN\x01\x01"
    # Nothing before `user=`, nothing after the two separators — a stray
    # newline here would inject a second command into the IMAP stream.
    refute String.contains?(decoded, ["\r", "\n"])
  end

  describe "never raises on the bytes it is handed" do
    test "an 8-bit, invalid-UTF-8 token still encodes" do
      token = <<0xFF, 0xFE, "tok", 0x80>>

      assert response = Xoauth2.response("mara@example.com", token)
      assert {:ok, decoded} = Base.decode64(response)
      # The raw bytes survive verbatim: the server, not this module, decides
      # whether they are a token.
      assert decoded == "user=mara@example.com" <> <<1>> <> "auth=Bearer " <> token <> <<1, 1>>
    end

    test "an 8-bit username still encodes" do
      assert response = Xoauth2.response(<<"m", 0xE4, "ra">>, "tok")

      assert {:ok, "user=m" <> <<0xE4>> <> "ra" <> <<1>> <> "auth=Bearer tok\x01\x01"} =
               Base.decode64(response)
    end

    test "empty inputs are encoded, not rejected" do
      assert {:ok, "user=\x01auth=Bearer \x01\x01"} = Xoauth2.response("", "") |> Base.decode64()
    end
  end
end
