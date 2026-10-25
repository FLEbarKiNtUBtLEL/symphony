defmodule SymphonyElixir.RunCause do
  @moduledoc """
  Why a run stopped, recorded where the cause is known rather than guessed later.

  Two different stops were reported identically, and both are recorded here because
  they are the same question asked twice: what ended this run?

  The orchestrator reconciles by polling the tracker, so it sees only the RESULT:
  the issue is no longer routed to this worker. A self-withdrawal — the agent
  removing its own dispatch label, or assigning the issue away, because it decided a
  human must rule — produces exactly the same observation as an external
  cancellation, a timeout or a crash. Both then logged the same line, so attributing
  a past stop needed the agent rollout, the runtime log and the tracker's timeline
  read together, and the number of self-withdrawals that were mistaken for stops
  stayed unknown.

  The runtime already has the missing fact and was discarding it. Every tracker call
  an agent makes is mediated by Symphony's injected tool, so a mutation of the
  issue's own routing is observable AT THE MOMENT IT HAPPENS, by the process that
  performs it. This module is where that observation is kept.

  ## Why not read the tracker's actor field

  Because it cannot answer. One credential is shared by the orchestrator and every
  agent, so the tracker records the same actor whoever wrote. The only place the two
  cases differ is here, inside the runtime, at the call.

  ## Durability, stated precisely

  Three sinks carry a cause, and only two of them survive a restart:

    * `log/symphony.log` — the rotating disk handler configured at application start.
      Every cause is logged the moment it is observed, so a past run is attributable
      from the log alone. Survives a VM restart, within the rotation window.
    * the run log — one structured line per run, appended when the run ends, carrying
      the cause in its detail. Survives a VM restart.
    * this table — live only, and deliberately so. It exists for one job: letting the
      reconcile loop name the cause in the line it writes, in the same VM, minutes
      after the agent recorded it. It is owned from application start rather than by
      whichever process wrote first, because an owner that is an agent session takes
      the table with it when the agent exits.

  Nothing depends on the table surviving a restart. A restart loses the live
  correlation and keeps the record, which is the correct trade: the question "why did
  this run stop" is answered by the two durable sinks.
  """

  require Logger

  @table :symphony_run_causes

  @typedoc "A recorded cause, with what showed it and when."
  @type observation :: %{
          required(:cause) => :self_withdrawal | :usage_limit,
          required(:detail) => String.t(),
          required(:observed_at) => DateTime.t()
        }

  @doc """
  Create the table, owned by the calling process. Safe to call repeatedly.

  CALL THIS AT APPLICATION START AND NOWHERE ELSE THAT MATTERS. An ETS table belongs
  to the process that created it and dies with it. The first version let whichever
  process happened to write first become the owner -- which is an agent session, the
  shortest-lived process in the system. The table therefore vanished when that agent
  exited, and the orchestrator's reconcile, running later in a different process,
  read an empty table and reported every self-withdrawal as an external stop. The
  module failed silently at the one thing it exists for, and the unit tests passed
  throughout because each wrote and read inside a single process.

  Owned from application start, the table outlives every agent and the table's
  absence stops being a thing that can happen mid-run.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  @doc """
  Note that the agent working `issue_id` changed that issue's own routing.

  Logged as well as stored, because the log is the part that outlives the run.
  """
  @spec record(term(), String.t(), String.t(), keyword()) :: :ok
  def record(issue_id, method, path, opts \\ []) do
    context = Keyword.get(opts, :context, "issue_id=#{inspect(issue_id)}")

    put(issue_id, :self_withdrawal, "#{method} #{path}", opts)

    Logger.info(
      "Agent changed its own issue routing: #{context} method=#{method} path=#{path}; " <>
        "a later stop for this issue is a SELF-WITHDRAWAL, not an external stop"
    )

    :ok
  end

  @doc """
  Note that the provider reported exhausted capacity during `issue_id`'s run.

  The run has not asked anybody for anything; it ran out of allowance. Recorded so
  the run's own line says so instead of leaving the operator to infer it from a
  pause.
  """
  @spec record_usage_limit(term(), String.t(), keyword()) :: :ok
  def record_usage_limit(issue_id, phrase, opts \\ []) do
    put(issue_id, :usage_limit, phrase, opts)

    Logger.info(
      "Provider capacity exhausted during run: issue_id=#{inspect(issue_id)} " <>
        "phrase=#{inspect(phrase)}; the run is not waiting for operator input"
    )

    :ok
  end

  defp put(issue_id, cause, detail, opts) do
    ensure_table()
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    :ets.insert(@table, {issue_id, %{cause: cause, detail: detail, observed_at: observed_at}})

    :ok
  end

  @doc "The observation for `issue_id`, or nil when the agent did not touch its own routing."
  @spec observed(term()) :: observation() | nil
  def observed(issue_id) do
    ensure_table()

    case :ets.lookup(@table, issue_id) do
      [{^issue_id, observation}] -> observation
      _ -> nil
    end
  end

  @doc """
  How a stop for `issue_id` should be described.

  `:self_withdrawal` when this runtime watched the agent do it, `:external` when it
  did not. `:external` is deliberately the default: an absence of evidence must never
  be reported as an agent-authored escalation, which is the failure this exists to
  prevent.
  """
  @spec classify(term()) :: {:self_withdrawal | :usage_limit, observation()} | :external
  def classify(issue_id) do
    case observed(issue_id) do
      nil -> :external
      %{cause: cause} = observation -> {cause, observation}
    end
  end

  @doc """
  A compact phrase for a run's structured record, or nil when nothing was observed.

  Returning nil rather than a placeholder keeps the run log honest: a run with no
  recorded cause says nothing about why it ended, which is the truth.
  """
  @spec summary(term()) :: String.t() | nil
  def summary(issue_id) do
    case classify(issue_id) do
      {:self_withdrawal, %{detail: detail}} -> "self_withdrawal via #{detail}"
      {:usage_limit, %{detail: detail}} -> "usage_limit: #{detail}"
      :external -> nil
    end
  end

  @doc "Drop the record for `issue_id`, once the stop it explains has been handled."
  @spec forget(term()) :: :ok
  def forget(issue_id) do
    ensure_table()
    :ets.delete(@table, issue_id)
    :ok
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
