defmodule SymphonyElixir.RunCauseTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.RunCause

  setup do
    RunCause.reset_for_test()
    :ok
  end

  defp ok_client, do: fn _m, _p, _q, _b, _o -> {:ok, %{status: 200, body: %{}}} end
  defp issue, do: %{id: 42, number: 207, identifier: "ISSUE-207"}

  defp run(method, path, opts \\ []) do
    AgentTool.execute(
      "github_api",
      %{"method" => method, "path" => path},
      Keyword.merge([github_client: ok_client(), issue: issue()], opts)
    )
  end

  test "an absence of observation is EXTERNAL, never an agent-authored escalation" do
    # The failure this exists to prevent. If the runtime did not watch the agent do
    # it, it must not say the agent did it.
    assert RunCause.classify(42) == :external
    assert RunCause.observed(42) == nil
  end

  test "removing its own dispatch label is recorded as a self-withdrawal" do
    run("DELETE", "/repos/owner/repo/issues/207/labels/required-label")

    assert {:self_withdrawal, %{cause: :self_withdrawal, detail: detail, observed_at: %DateTime{}}} =
             RunCause.classify(42)

    assert detail =~ "DELETE"
    assert detail =~ "/labels/required-label"
    # And the compact form the run's structured record carries.
    assert RunCause.summary(42) =~ "self_withdrawal via DELETE"
  end

  test "adding a hold, assigning away, and patching the issue all count" do
    for {method, path} <- [
          {"POST", "/repos/owner/repo/issues/207/labels"},
          {"DELETE", "/repos/owner/repo/issues/207/assignees"},
          {"PATCH", "/repos/owner/repo/issues/207"}
        ] do
      RunCause.reset_for_test()
      run(method, path)
      assert {:self_withdrawal, _} = RunCause.classify(42), "#{method} #{path}"
    end
  end

  test "ordinary agent traffic is NOT a withdrawal" do
    # An agent comments, reads, and touches other issues constantly. Recording those
    # would report every chatty agent as having escalated, which is the same defect
    # pointed the other way.
    for {method, path} <- [
          {"POST", "/repos/owner/repo/issues/207/comments"},
          {"GET", "/repos/owner/repo/issues/207/labels"},
          {"POST", "/repos/owner/repo/issues/999/labels"},
          {"DELETE", "/repos/owner/repo/issues/9999/labels/required-label"},
          {"POST", "/repos/owner/repo/pulls/207/reviews"}
        ] do
      RunCause.reset_for_test()
      run(method, path)
      assert RunCause.classify(42) == :external, "#{method} #{path}"
    end
  end

  test "the issue number is recovered from whichever identity field the turn carries" do
    path = "/repos/owner/repo/issues/207/labels/required-label"

    for bound <- [
          %{id: 207},
          %{id: "207"},
          %{id: "207", number: nil}
        ] do
      RunCause.reset_for_test()
      run("DELETE", path, issue: bound)
      assert {:self_withdrawal, _} = RunCause.classify(bound.id), inspect(bound)
    end
  end

  test "an issue whose number cannot be recovered attributes nothing" do
    # An identifier without digits does not fall back to the id: it names the issue.
    for bound <- [%{id: "not-a-number"}, %{id: 207, identifier: "no digits"}, %{id: :opaque}, %{id: nil}] do
      RunCause.reset_for_test()
      run("DELETE", "/repos/owner/repo/issues/207/labels/required-label", issue: bound)
      assert RunCause.classify(bound.id) == :external, inspect(bound)
    end
  end

  test "a path for an issue whose number merely STARTS with ours is not ours" do
    # /issues/2071 must not match issue 207.
    run("DELETE", "/repos/owner/repo/issues/2071/labels/required-label")
    assert RunCause.classify(42) == :external
  end

  test "a query string does not hide the path" do
    run("DELETE", "/repos/owner/repo/issues/207/labels/required-label?foo=1")
    assert {:self_withdrawal, _} = RunCause.classify(42)
  end

  test "a rejected call changed nothing and is not recorded" do
    AgentTool.execute(
      "github_api",
      %{"method" => "DELETE", "path" => "/repos/owner/repo/issues/207/labels/required-label"},
      github_client: fn _m, _p, _q, _b, _o -> {:ok, %{status: 403, body: %{}}} end,
      issue: issue()
    )

    assert RunCause.classify(42) == :external
  end

  test "with no issue bound to the turn, nothing is attributed" do
    AgentTool.execute(
      "github_api",
      %{"method" => "DELETE", "path" => "/repos/owner/repo/issues/207/labels/required-label"},
      github_client: ok_client()
    )

    assert RunCause.classify(42) == :external
  end

  test "a usage-limit stop is a different cause, recorded through the same ledger" do
    # Not an operator request and not a withdrawal: the run ran out of allowance.
    RunCause.record_usage_limit(42, "You've hit your usage limit.")

    assert {:usage_limit, %{detail: detail}} = RunCause.classify(42)
    assert detail =~ "usage limit"
    assert RunCause.summary(42) =~ "usage_limit:"
    refute RunCause.summary(42) =~ "self_withdrawal"
  end

  test "summary is nil when nothing was observed, rather than a placeholder" do
    # A run with no recorded cause must say nothing about why it ended. Inventing a
    # cause would be worse than the silence it replaced.
    assert RunCause.summary(42) == nil
  end

  test "forget clears the record once the stop it explains is handled" do
    run("DELETE", "/repos/owner/repo/issues/207/labels/required-label")
    assert {:self_withdrawal, _} = RunCause.classify(42)
    RunCause.forget(42)
    assert RunCause.classify(42) == :external
  end

  test "the identifier form supplies the number when `number` is absent" do
    AgentTool.execute(
      "github_api",
      %{"method" => "DELETE", "path" => "/repos/owner/repo/issues/207/labels/required-label"},
      github_client: ok_client(),
      issue: %{id: 7, identifier: "ISSUE-207"}
    )

    assert {:self_withdrawal, _} = RunCause.classify(7)
  end

  test "a cause recorded by a process that then EXITS is still readable" do
    # THE DEFECT EVERY OTHER TEST HERE MISSED, and missed structurally: each one
    # writes and reads inside a single process, so none could see that the table
    # belonged to the writer and died with it.
    #
    # In production the writer is an agent session -- the shortest-lived process in
    # the system -- and the reader is the orchestrator's reconcile loop, minutes
    # later in a different process. The table vanished in between, so classify
    # answered :external and every self-withdrawal was reported as an external stop.
    # The module failed silently at the one thing it exists for.
    #
    # The table is now created at application start. This test asserts the property
    # that makes that matter: a record outlives the process that wrote it.
    assert :ok = RunCause.ensure_table()
    owner = :ets.info(:symphony_run_causes, :owner)

    Task.await(
      Task.async(fn ->
        RunCause.record(42, "DELETE", "/repos/owner/repo/issues/207/labels/required-label")
      end)
    )

    assert {:self_withdrawal, _} = RunCause.classify(42),
           "the record must outlive the process that wrote it"

    assert :ets.info(:symphony_run_causes, :owner) == owner,
           "and writing must not transfer ownership to the writer"
  end

  test "a cause recorded in another process reaches the run log summary too" do
    assert :ok = RunCause.ensure_table()
    Task.await(Task.async(fn -> RunCause.record_usage_limit(43, "usage limit reached") end))
    assert RunCause.summary(43) =~ "usage_limit:"
  end

  test "the cause reaches the durable run log, which is what survives a restart" do
    # The ETS table is live-only by design. The two sinks that survive a VM restart
    # are the rotating application log and this one -- a structured line per run. A
    # cause that only ever reached the prose log would be durable but would still
    # need grepping; here it sits on the run's own record.
    alias SymphonyElixir.RunLog

    tmp = Path.join(System.tmp_dir!(), "run-cause-#{System.unique_integer([:positive])}.log")
    previous = Application.get_env(:symphony_elixir, :run_log_file)
    Application.put_env(:symphony_elixir, :run_log_file, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if previous,
        do: Application.put_env(:symphony_elixir, :run_log_file, previous),
        else: Application.delete_env(:symphony_elixir, :run_log_file)
    end)

    issue = %{id: 42, identifier: "ISSUE-207", number: 207}
    RunCause.record(42, "DELETE", "/repos/owner/repo/issues/207/labels/required-label")

    RunLog.measure(issue, [worker_host: "local"], fn -> :ok end)

    line = tmp |> File.read!() |> String.split("\n", trim: true) |> List.last()
    entry = Jason.decode!(line)

    assert entry["outcome"] == "ok", "the outcome is unchanged -- the cause is added beside it"
    assert entry["detail"] =~ "self_withdrawal via DELETE"
  end
end
