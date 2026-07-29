defmodule Valea.Ledger.WriterTest do
  # async: false — the writer registers under its module name (one per open
  # workspace), so two modules starting one concurrently would clash.
  use ExUnit.Case, async: false

  alias Valea.Ledger.Writer
  alias Valea.Tasks

  setup do
    start_supervised!(Writer)

    root = Path.join(System.tmp_dir!(), "writer-icm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  describe "exec/1 serialization" do
    # The guarantee the spec asks for: read-patch-write cycles never
    # interleave. Unserialized, these 25 creates read the same file and
    # overwrite each other's appends (lost updates); through the writer every
    # one lands, with no conflict retries needed at all.
    test "25 concurrent creates all land, each with its own id", %{root: root} do
      results =
        1..25
        |> Task.async_stream(
          fn n -> Tasks.create(root, %{"title" => "task-#{n}"}) end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _entry}, &1))

      created = for {:ok, entry} <- results, do: entry
      %{status: :ok, tasks: tasks} = Tasks.list(root)

      assert length(tasks) == 25
      assert tasks |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 25

      assert Enum.map(created, & &1["id"]) |> Enum.sort() ==
               Enum.map(tasks, & &1["id"]) |> Enum.sort()

      assert tasks |> Enum.map(& &1["title"]) |> Enum.sort() ==
               Enum.sort(for n <- 1..25, do: "task-#{n}")
    end

    test "no two funs run at the same time" do
      tracker = start_supervised!({Agent, fn -> %{running: 0, peak: 0} end})

      overlap = fn ->
        Agent.update(tracker, fn %{running: running, peak: peak} ->
          %{running: running + 1, peak: max(peak, running + 1)}
        end)

        Process.sleep(2)
        Agent.update(tracker, &%{&1 | running: &1.running - 1})
      end

      1..10
      |> Task.async_stream(fn _n -> Writer.exec(overlap) end, max_concurrency: 10)
      |> Stream.run()

      assert Agent.get(tracker, & &1.peak) == 1
    end

    test "returns the fun's value verbatim" do
      assert Writer.exec(fn -> {:ok, %{archived: 3}} end) == {:ok, %{archived: 3}}
      assert Writer.exec(fn -> nil end) == nil
    end
  end

  describe "exec/1 failure isolation" do
    test "an exception propagates to the caller and the writer survives" do
      pid = Process.whereis(Writer)

      assert_raise RuntimeError, "boom", fn -> Writer.exec(fn -> raise "boom" end) end

      assert Process.whereis(Writer) == pid
      assert Process.alive?(pid)
      assert Writer.exec(fn -> :still_serializing end) == :still_serializing
    end

    test "the re-raised exception keeps the original stacktrace" do
      stacktrace =
        try do
          Writer.exec(fn -> raise "boom" end)
        rescue
          _error -> __STACKTRACE__
        end

      # The frame of the fun that actually failed — this test module — rather
      # than only the writer's own call site.
      assert Enum.any?(stacktrace, fn {module, _fun, _arity, _location} ->
               module == __MODULE__
             end)
    end

    test "throws and exits propagate too, and the writer survives both" do
      pid = Process.whereis(Writer)

      assert catch_throw(Writer.exec(fn -> throw(:nope) end)) == :nope
      assert catch_exit(Writer.exec(fn -> exit(:nope) end)) == :nope

      assert Process.whereis(Writer) == pid
      assert Writer.exec(fn -> :alive end) == :alive
    end

    test "a mutation that raises leaves the ledger readable and writable", %{root: root} do
      {:ok, entry} = Tasks.create(root, %{"title" => "before"})

      assert_raise RuntimeError, "mid-flight", fn ->
        Writer.exec(fn -> raise "mid-flight" end)
      end

      assert {:ok, _patched} = Tasks.patch(root, entry["id"], %{"status" => "in_progress"})
      assert [%{"status" => "in_progress"}] = Tasks.list(root).tasks
    end
  end
end
