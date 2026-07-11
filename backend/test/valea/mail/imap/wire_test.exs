defmodule Valea.Mail.Imap.WireTest do
  use ExUnit.Case, async: true
  alias Valea.Mail.Imap.Wire

  test "pulls a tagged OK" do
    assert {:ok, {:tagged, "A1", :ok, "LOGIN completed"}, ""} =
             Wire.pull("A1 OK LOGIN completed\r\n")
  end

  test "incomplete without CRLF" do
    assert :incomplete = Wire.pull("A1 OK LOGIN comp")
  end

  test "fetch with literal body parses by exact byte count" do
    # contains ')' inside the literal body — a naive regex/text scanner would
    # mistake it for the closing paren of the attr list and truncate early.
    body = "From: a@b\r\n\r\nhello)world"

    line =
      "* 2 FETCH (UID 7 RFC822.SIZE #{byte_size(body)} BODY[] {#{byte_size(body)}}\r\n#{body})\r\n"

    assert {:ok, {:fetch, 2, attrs}, ""} = Wire.pull(line <> "")
    assert attrs.uid == 7
    assert attrs.body == body
  end

  test "incomplete mid-literal" do
    assert :incomplete = Wire.pull("* 2 FETCH (BODY[] {10}\r\nabc")
  end

  test "untagged capability line passes through raw" do
    assert {:ok, {:untagged, "CAPABILITY IMAP4rev1 MOVE UIDPLUS"}, ""} =
             Wire.pull("* CAPABILITY IMAP4rev1 MOVE UIDPLUS\r\n")
  end

  test "continuation" do
    assert {:ok, {:continuation, "Ready"}, ""} = Wire.pull("+ Ready\r\n")
  end

  test "two responses pull one at a time" do
    buf = "* 1 EXISTS\r\nA2 OK done\r\n"
    assert {:ok, {:untagged, "1 EXISTS"}, rest} = Wire.pull(buf)
    assert {:ok, {:tagged, "A2", :ok, "done"}, ""} = Wire.pull(rest)
  end

  test "encode quotes folder names with spaces" do
    {iodata, []} = Wire.encode("A1", ["SELECT", "AI/Review Folder"])
    assert IO.iodata_to_binary(iodata) == "A1 SELECT \"AI/Review Folder\"\r\n"
  end

  test "encode APPEND with literal defers the literal" do
    {iodata, [lit]} = Wire.encode("A2", ["APPEND", "Drafts", "(\\Draft)", {:literal, "abc"}])
    assert IO.iodata_to_binary(iodata) == "A2 APPEND \"Drafts\" (\\Draft) {3}\r\n"
    assert lit == "abc"
  end

  test "encode raises on CR/LF smuggled into a bare argument" do
    assert_raise ArgumentError, fn -> Wire.encode("A3", ["SELECT", "x\r\nA4 DELETE INBOX"]) end
  end

  test "fetch header fields variant maps to :header" do
    hdr = "From: p@x\r\nSubject: hi\r\n\r\n"

    line =
      "* 5 FETCH (UID 9 BODY[HEADER.FIELDS (FROM SUBJECT)] {#{byte_size(hdr)}}\r\n#{hdr})\r\n"

    assert {:ok, {:fetch, 5, %{uid: 9, header: ^hdr}}, ""} = Wire.pull(line)
  end

  # Additional cases beyond the brief's minimum, added per "you may add more
  # cases; do not weaken the given ones".

  test "pulls a tagged NO and BAD" do
    assert {:ok, {:tagged, "A9", :no, "LOGIN failed"}, ""} =
             Wire.pull("A9 OK LOGIN failed\r\n" |> String.replace("OK", "NO"))

    assert {:ok, {:tagged, "A10", :bad, "unknown command"}, ""} =
             Wire.pull("A10 BAD unknown command\r\n")
  end

  test "fetch parses multiple flags in order" do
    line = "* 3 FETCH (FLAGS (\\Seen \\Answered \\Draft))\r\n"
    assert {:ok, {:fetch, 3, attrs}, ""} = Wire.pull(line)
    assert attrs.flags == ["\\Seen", "\\Answered", "\\Draft"]
  end

  test "fetch parses empty flags list" do
    line = "* 4 FETCH (FLAGS ())\r\n"
    assert {:ok, {:fetch, 4, attrs}, ""} = Wire.pull(line)
    assert attrs.flags == []
  end

  test "fetch parses INTERNALDATE as a quoted string" do
    line = "* 6 FETCH (INTERNALDATE \"05-Jan-2024 12:00:00 +0000\" UID 1)\r\n"
    assert {:ok, {:fetch, 6, attrs}, ""} = Wire.pull(line)
    assert attrs.internaldate == "05-Jan-2024 12:00:00 +0000"
  end

  test "fetch with two literals in one line parses both by exact byte count" do
    hdr = "Subject: hi\r\n\r\n"
    body = "hello (world)"

    line =
      "* 8 FETCH (BODY[HEADER.FIELDS (SUBJECT)] {#{byte_size(hdr)}}\r\n#{hdr} BODY[] {#{byte_size(body)}}\r\n#{body})\r\n"

    assert {:ok, {:fetch, 8, attrs}, ""} = Wire.pull(line)
    assert attrs.header == hdr
    assert attrs.body == body
  end

  test "incomplete when only the tail CRLF is missing" do
    assert :incomplete = Wire.pull("A1 OK LOGIN completed\r")
  end

  test "incomplete on empty buffer" do
    assert :incomplete = Wire.pull("")
  end

  test "pull does not misparse a ')' inside a quoted string as list close" do
    line = "* 7 FETCH (INTERNALDATE \"has ) paren\" UID 2)\r\n"
    assert {:ok, {:fetch, 7, attrs}, ""} = Wire.pull(line)
    assert attrs.internaldate == "has ) paren"
    assert attrs.uid == 2
  end

  test "encode: bare command verb and sequence-set style tokens stay unquoted" do
    {iodata, []} = Wire.encode("A5", ["UID", "FETCH", "1:*", "(UID FLAGS)"])
    assert IO.iodata_to_binary(iodata) == "A5 UID FETCH 1:* (UID FLAGS)\r\n"
  end

  test "encode escapes embedded backslash and double quote in a quoted argument" do
    {iodata, []} = Wire.encode("A6", ["SELECT", "weird\"name\\here"])
    assert IO.iodata_to_binary(iodata) == "A6 SELECT \"weird\\\"name\\\\here\"\r\n"
  end

  test "encode raises on 8-bit byte in a bare argument" do
    assert_raise ArgumentError, fn -> Wire.encode("A7", ["SELECT", <<"bad", 0xFF>>]) end
  end
end
