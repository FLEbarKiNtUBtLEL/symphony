defmodule SymphonyElixir.RunLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.RunLog

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-run-log-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "runs.jsonl")
    previous = Application.get_env(:symphony_elixir, :run_log_file)
    previous_log = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :run_log_file, file)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :run_log_file, previous)
      else
        Application.delete_env(:symphony_elixir, :run_log_file)
      end

      if previous_log do
        Application.put_env(:symphony_elixir, :log_file, previous_log)
      else
        Application.delete_env(:symphony_elixir, :log_file)
      end

      File.rm_rf(dir)
    end)

    {:ok, log_file: file}
  end

  defp issue, do: %{id: 61, identifier: "GH-61"}

  test "default_path/1 puts the run log beside the given log file" do
    assert RunLog.default_path("/tmp/symphony/log/symphony.log") ==
             "/tmp/symphony/log/symphony-runs.jsonl"
  end

  test "path/0 follows a relocated application log" do
    # The bug this replaces: deriving from File.cwd!() meant Symphony started
    # from another directory wrote its run log where nobody looks. The file
    # exists and stays empty, so missing records read as missing runs.
    Application.delete_env(:symphony_elixir, :run_log_file)
    Application.put_env(:symphony_elixir, :log_file, "/var/log/symphony/symphony.log")

    assert RunLog.path() == "/var/log/symphony/symphony-runs.jsonl"
  end

  test "an explicit :run_log_file still wins outright" do
    Application.put_env(:symphony_elixir, :log_file, "/var/log/symphony/symphony.log")
    Application.put_env(:symphony_elixir, :run_log_file, "/elsewhere/runs.jsonl")

    assert RunLog.path() == "/elsewhere/runs.jsonl"
  end

  test "measure/3 returns the wrapped value and records a successful run" do
    assert :ok == RunLog.measure(issue(), [worker_host: "local"], fn -> :ok end)

    assert [entry] = RunLog.recent()
    assert entry["event"] == "run"
    assert entry["issue_id"] == 61
    assert entry["issue_identifier"] == "GH-61"
    assert entry["worker_host"] == "local"
    assert entry["outcome"] == "ok"
    assert entry["detail"] == nil
    assert is_integer(entry["duration_ms"])
  end

  test "an error tuple is recorded as an error with its reason" do
    assert {:error, :boom} == RunLog.measure(issue(), [], fn -> {:error, :boom} end)

    assert [entry] = RunLog.recent()
    assert entry["outcome"] == "error"
    assert entry["detail"] =~ "boom"
  end

  test "a raised exception is recorded and then re-raised unchanged" do
    assert_raise RuntimeError, "exploded", fn ->
      RunLog.measure(issue(), [], fn -> raise "exploded" end)
    end

    assert [entry] = RunLog.recent()
    assert entry["outcome"] == "crash"
    assert entry["detail"] =~ "exploded"
  end

  test "a throw is recorded and then re-thrown unchanged" do
    assert catch_throw(RunLog.measure(issue(), [], fn -> throw(:nope) end)) == :nope

    assert [entry] = RunLog.recent()
    assert entry["outcome"] == "crash"
  end

  test "recent/2 returns newest first and honours the limit" do
    for n <- 1..5 do
      RunLog.measure(%{id: n, identifier: "GH-#{n}"}, [], fn -> :ok end)
    end

    assert RunLog.recent() |> Enum.map(& &1["issue_id"]) == [5, 4, 3, 2, 1]
    assert RunLog.recent(2) |> Enum.map(& &1["issue_id"]) == [5, 4]
  end

  test "recent/2 filters by issue identifier" do
    RunLog.measure(%{id: 1, identifier: "GH-1"}, [], fn -> :ok end)
    RunLog.measure(%{id: 2, identifier: "GH-2"}, [], fn -> :ok end)

    assert [entry] = RunLog.recent(100, issue_identifier: "GH-2")
    assert entry["issue_id"] == 2
  end

  test "a missing log file reads as no history rather than an error" do
    assert RunLog.recent() == []
  end

  test "a truncated final line is skipped, not fatal", %{log_file: file} do
    RunLog.measure(issue(), [], fn -> :ok end)
    File.write!(file, ~s({"event":"run","issue_id":), [:append])

    assert [entry] = RunLog.recent()
    assert entry["issue_id"] == 61
  end

  test "an unwritable destination does not disturb the run" do
    Application.put_env(:symphony_elixir, :run_log_file, "/proc/version/nope.jsonl")

    # The observability sink must never take down the run it observes.
    assert :ok == RunLog.measure(issue(), [], fn -> :ok end)
  end

  test "rate-limit observations are recorded and read back with their timestamp" do
    assert :ok == RunLog.record_rate_limits(%{"primary" => %{"used_percent" => 92}})

    assert {limits, observed_at} = RunLog.latest_rate_limits()
    assert limits["primary"]["used_percent"] == 92
    assert {:ok, _, _} = DateTime.from_iso8601(observed_at)
  end

  test "latest_rate_limits/0 returns the newest observation" do
    RunLog.record_rate_limits(%{"used_percent" => 10})
    RunLog.record_rate_limits(%{"used_percent" => 90})

    assert {%{"used_percent" => 90}, _} = RunLog.latest_rate_limits()
  end

  test "no observation reads as nil rather than an error" do
    assert RunLog.latest_rate_limits() == nil
  end

  test "rate-limit entries are not returned as runs" do
    # One file, several event types. /api/v1/runs reports runs.
    RunLog.record_rate_limits(%{"used_percent" => 50})
    RunLog.measure(issue(), [], fn -> :ok end)
    RunLog.record_rate_limits(%{"used_percent" => 60})

    assert [entry] = RunLog.recent()
    assert entry["event"] == "run"
  end

  test "a run interleaved with observations still reads back cleanly" do
    RunLog.record_rate_limits(%{"used_percent" => 1})
    RunLog.measure(%{id: 1, identifier: "GH-1"}, [], fn -> :ok end)
    RunLog.record_rate_limits(%{"used_percent" => 2})
    RunLog.measure(%{id: 2, identifier: "GH-2"}, [], fn -> :ok end)

    assert RunLog.recent() |> Enum.map(& &1["issue_id"]) == [2, 1]
    assert {%{"used_percent" => 2}, _} = RunLog.latest_rate_limits()
  end
end
