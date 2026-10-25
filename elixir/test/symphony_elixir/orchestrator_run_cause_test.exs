defmodule SymphonyElixir.OrchestratorRunCauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunCause

  setup do
    RunCause.reset_for_test()
    on_exit(fn -> RunCause.reset_for_test() end)
    :ok
  end

  for mode <- [:running, :blocked], cause <- [:self_withdrawal, :usage_limit, :external] do
    test "#{mode} reconciliation handles #{cause} without crashing" do
      issue = issue("#{unquote(mode)}-#{unquote(cause)}")
      state = state_for(issue, unquote(mode))
      record_cause(issue.id, unquote(cause))
      unrouted = %{issue | dispatchable: false}

      log =
        capture_log(fn ->
          updated = reconcile(unquote(mode), unrouted, state)
          refute MapSet.member?(updated.claimed, issue.id)
          refute Map.has_key?(updated.running, issue.id)
          refute Map.has_key?(updated.blocked, issue.id)
          assert RunCause.observed(issue.id) == nil

          if unquote(mode) == :running do
            refute Process.alive?(state.running[issue.id].pid)
          end
        end)

      expected =
        if unquote(cause) == :external,
          do: "external_no_agent_action_observed",
          else: Atom.to_string(unquote(cause))

      assert log =~ "cause=#{expected}"

      if unquote(cause) == :self_withdrawal do
        assert log =~ "DELETE /repos/owner/repo/issues/42/labels/symphony"
      end
    end
  end

  for mode <- [:running, :blocked], state_name <- ["Done", "Backlog"] do
    test "#{mode} #{state_name} reconciliation releases the old cause" do
      issue = issue("#{unquote(mode)}-#{unquote(state_name)}")
      state = state_for(issue, unquote(mode))
      record_cause(issue.id, :self_withdrawal)

      updated = reconcile(unquote(mode), %{issue | state: unquote(state_name)}, state)

      refute MapSet.member?(updated.claimed, issue.id)
      assert RunCause.observed(issue.id) == nil
    end
  end

  for reason <- [:normal, :shutdown] do
    test "#{reason} worker exit clears the cause before retry" do
      issue = issue("exit-#{unquote(reason)}")
      state = state_for(issue, :running)
      record_cause(issue.id, :usage_limit)
      ref = state.running[issue.id].ref
      :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, state.running[issue.id].pid)

      {:noreply, updated} = Orchestrator.handle_info({:DOWN, ref, :process, nil, unquote(reason)}, state)

      assert RunCause.observed(issue.id) == nil
      assert %{timer_ref: timer} = updated.retry_attempts[issue.id]
      Process.cancel_timer(timer)
    end
  end

  test "auto-answer failure stays specifically blocked and retains attribution until release" do
    issue = issue("auto-answer")
    state = state_for(issue, :running)
    entry = %{state.running[issue.id] | last_codex_event: :approval_auto_answer_unavailable}
    state = %{state | running: %{issue.id => entry}}
    record_cause(issue.id, :self_withdrawal)
    :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid)

    {:noreply, blocked} = Orchestrator.handle_info({:DOWN, entry.ref, :process, nil, :shutdown}, state)

    assert blocked.blocked[issue.id].error == "codex approval auto-answer unavailable"
    refute Map.has_key?(blocked.retry_attempts, issue.id)
    assert {:self_withdrawal, _} = RunCause.classify(issue.id)

    released = reconcile(:blocked, %{issue | dispatchable: false}, blocked)
    refute MapSet.member?(released.claimed, issue.id)
    assert RunCause.observed(issue.id) == nil
  end

  test "missing running and blocked issues release their causes through the poll cycle" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    running = issue("missing-running")
    blocked = issue("missing-blocked")
    state = state_for(running, :running)
    blocked_state = state_for(blocked, :blocked)
    state = %{state | blocked: blocked_state.blocked, claimed: MapSet.new([running.id, blocked.id])}
    record_cause(running.id, :self_withdrawal)
    record_cause(blocked.id, :usage_limit)

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    Process.cancel_timer(updated.tick_timer_ref)
    assert updated.running == %{}
    assert updated.blocked == %{}
    assert RunCause.observed(running.id) == nil
    assert RunCause.observed(blocked.id) == nil
  end

  defp issue(id) do
    %Issue{id: id, identifier: "GH-42", state: "In Progress", title: "Cause regression", dispatchable: true}
  end

  defp state_for(issue, mode) do
    pid =
      if mode == :running do
        {:ok, pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            receive do
              :stop -> :ok
            end
          end)

        on_exit(fn -> Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) end)
        pid
      end

    entry = %{
      pid: pid,
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now(),
      last_codex_event: nil
    }

    %Orchestrator.State{
      running: if(mode == :running, do: %{issue.id => entry}, else: %{}),
      blocked: if(mode == :blocked, do: %{issue.id => entry}, else: %{}),
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp record_cause(id, :self_withdrawal),
    do: RunCause.record(id, "DELETE", "/repos/owner/repo/issues/42/labels/symphony")

  defp record_cause(id, :usage_limit), do: RunCause.record_usage_limit(id, "usage limit reached")
  defp record_cause(_id, :external), do: :ok

  defp reconcile(:running, issue, state), do: Orchestrator.reconcile_issue_states_for_test([issue], state)
  defp reconcile(:blocked, issue, state), do: Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)
end
