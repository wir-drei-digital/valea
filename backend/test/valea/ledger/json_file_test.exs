defmodule Valea.Ledger.JsonFileTest do
  use ExUnit.Case, async: true

  alias Valea.Ledger.JsonFile

  setup do
    dir = Path.join(System.tmp_dir!(), "ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "tasks.json")}
  end

  describe "read/2 leniency" do
    test("absent file", %{path: path}, do: assert(JsonFile.read(path, "tasks") == :absent))

    test "malformed json is :unreadable", %{path: path} do
      File.write!(path, "{not json")
      assert JsonFile.read(path, "tasks") == {:error, :unreadable}
    end

    test "non-map top level is :unreadable", %{path: path} do
      File.write!(path, ~s([{"id":"t-1"}]))
      assert JsonFile.read(path, "tasks") == {:error, :unreadable}
    end

    test "a directory in the file's place is :unreadable", %{dir: dir} do
      sub = Path.join(dir, "tasks.json")
      File.mkdir_p!(sub)
      assert JsonFile.read(sub, "tasks") == {:error, :unreadable}
    end

    test "missing list key yields no entries but keeps the doc", %{path: path} do
      File.write!(path, ~s({"readme":"x"}))
      assert {:ok, %{doc: %{"readme" => "x"}, entries: []}} = JsonFile.read(path, "tasks")
    end

    test "wrong-typed list key yields no entries but keeps the doc as-is", %{path: path} do
      File.write!(path, ~s({"tasks":"nope","readme":"x"}))

      assert {:ok, %{doc: doc, entries: []}} = JsonFile.read(path, "tasks")
      assert doc == %{"tasks" => "nope", "readme" => "x"}
    end

    test "hash is the sha256 of the raw bytes", %{path: path} do
      raw = ~s({"tasks":[]})
      File.write!(path, raw)
      assert {:ok, %{hash: hash}} = JsonFile.read(path, "tasks")
      assert hash == :crypto.hash(:sha256, raw)
    end

    test "non-map entries dropped, unknown fields survive round-trip", %{path: path} do
      File.write!(path, ~s({"readme":"x","tasks":[{"id":"t-1","custom":{"a":1}},42]}))
      {:ok, %{doc: doc, entries: [entry], hash: hash}} = JsonFile.read(path, "tasks")
      assert entry["custom"] == %{"a" => 1}
      :ok = JsonFile.write(path, put_in(doc, ["tasks"], [Map.put(entry, "title", "T")]), hash)
      {:ok, %{entries: [e2]}} = JsonFile.read(path, "tasks")
      assert e2["custom"] == %{"a" => 1} and e2["title"] == "T"
      # top-level unknown key preserved too
      assert Jason.decode!(File.read!(path))["readme"] == "x"
    end
  end

  describe "write/3" do
    test "writes pretty json with a trailing newline and no tmp left behind", %{path: path} do
      assert :ok = JsonFile.write(path, %{"tasks" => [%{"id" => "t-1"}]}, :absent)

      raw = File.read!(path)
      assert String.ends_with?(raw, "}\n")
      assert raw =~ "\n  "
      assert Path.wildcard(path <> ".tmp*") == []
    end

    test "creates the parent directory", %{dir: dir} do
      path = Path.join([dir, "nested", "deeper", "tasks.json"])
      assert :ok = JsonFile.write(path, %{"tasks" => []}, :absent)
      assert {:ok, %{entries: []}} = JsonFile.read(path, "tasks")
    end

    test "expected :absent against an existing file is :conflict", %{path: path} do
      File.write!(path, ~s({"tasks":[]}))
      assert JsonFile.write(path, %{"tasks" => []}, :absent) == {:error, :conflict}
      assert File.read!(path) == ~s({"tasks":[]})
    end

    test "expected hash against a vanished file is :conflict", %{path: path} do
      File.write!(path, ~s({"tasks":[]}))
      {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
      File.rm!(path)
      assert JsonFile.write(path, doc, hash) == {:error, :conflict}
      refute File.exists?(path)
    end

    test "write with stale hash is :conflict", %{path: path} do
      File.write!(path, ~s({"tasks":[]}))
      {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
      File.write!(path, ~s({"tasks":[{"id":"t-9"}]}))
      assert JsonFile.write(path, doc, hash) == {:error, :conflict}
    end

    test "a conflict leaves neither the file nor a tmp sibling behind", %{path: path} do
      File.write!(path, ~s({"tasks":[]}))
      {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
      other = ~s({"tasks":[{"id":"t-9"}]})
      File.write!(path, other)

      assert JsonFile.write(path, doc, hash) == {:error, :conflict}
      assert File.read!(path) == other
      assert Path.wildcard(path <> ".tmp*") == []
    end

    # Regression: with a single shared temp path, two writers take turns
    # filling the SAME file, so the one whose hash check passes can rename
    # the OTHER's bytes into place — and still be told `:ok`. The temp name
    # is private per call precisely so `:ok` means "my document is on disk".
    test "a successful write always publishes its own bytes", %{path: path} do
      File.write!(path, ~s({"tasks":[]}))

      results =
        1..40
        |> Task.async_stream(
          fn n ->
            {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
            marker = "writer-#{n}"
            {marker, JsonFile.write(path, Map.put(doc, "marker", marker), hash)}
          end,
          max_concurrency: 40,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      published = for {marker, :ok} <- results, do: marker

      assert published != []
      assert Jason.decode!(File.read!(path))["marker"] in published
      assert Path.wildcard(path <> ".tmp*") == []
    end

    test "the hash returned by read round-trips a write of the same bytes", %{path: path} do
      assert :ok = JsonFile.write(path, %{"tasks" => []}, :absent)
      {:ok, %{doc: doc, hash: hash}} = JsonFile.read(path, "tasks")
      assert :ok = JsonFile.write(path, Map.put(doc, "readme", "hi"), hash)
      assert {:ok, %{doc: %{"readme" => "hi"}}} = JsonFile.read(path, "tasks")
    end
  end
end
