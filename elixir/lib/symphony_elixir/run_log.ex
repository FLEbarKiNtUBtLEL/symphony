defmodule SymphonyElixir.RunLog do
  @moduledoc """
  Durable, append-only record of agent runs.

  `GET /api/v1/state` reports what is running *now*. Once a run ends it leaves
  no queryable trace: the application log narrates it in prose across a dozen
  interleaved lines, and the dashboard renders it faster than a person can
  read. Reconstructing "how many times did this issue dispatch, how long did
  each take, and how did they end" currently means correlating a process table
  against `grep` output after the fact.

  This writes one JSON object per line, one line per run, at the moment the run
  ends. It is deliberately not the application log: it is a small number of
  structured facts that answer operational questions directly, and it is safe
  to tail, parse, ship, or diff.

      {"event":"run","issue_id":61,"issue_identifier":"GH-61","worker_host":"local",
       "started_at":"2026-09-20T02:18:52Z","ended_at":"2026-09-20T02:18:56Z",
       "duration_ms":3894,"outcome":"ok","detail":null}

  `outcome` is one of `ok`, `error` or `crash`. `detail` carries the reason for
  the latter two and is `null` for `ok`.

  Failures to write are swallowed with a warning. An observability sink must
  never be able to take down the run it observes.
  """

  require Logger

  alias SymphonyElixir.LogFile

  @filename "symphony-runs.jsonl"

  @doc """
  Default location: beside the configured application log.

  The first version derived this from `File.cwd!()`, which is wrong in a way
  that fails quietly: Symphony started from a different directory writes its
  run log somewhere nobody looks, and an observability sink that writes to the
  wrong place is worse than one that does not write at all -- the file exists,
  it is just empty, so the absence of records reads as an absence of runs.

  Following `LogFile` keeps the two together wherever the operator has put
  them, and makes `:log_file` the single setting that moves both.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Path.join(Path.dirname(LogFile.default_log_file()), @filename)

  @spec default_path(Path.t()) :: Path.t()
  def default_path(log_file) when is_binary(log_file),
    do: Path.join(Path.dirname(log_file), @filename)

  @doc """
  Where the run log is written.

  `:run_log_file` overrides it outright; otherwise it follows `:log_file`, so
  an operator who relocates the application log relocates this with it rather
  than discovering later that the two diverged.
  """
  @spec path() :: Path.t()
  def path do
    case Application.get_env(:symphony_elixir, :run_log_file) do
      nil ->
        default_path(Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file()))

      configured ->
        configured
    end
  end

  @doc """
  Time `fun`, then append a record describing how it ended.

  Returns whatever `fun` returned, and re-raises anything it raised, so wrapping
  a call in this cannot change the call's behaviour.
  """
  @spec measure(map(), keyword(), (-> result)) :: result when result: term()
  def measure(issue, opts, fun) when is_function(fun, 0) do
    started_at = DateTime.utc_now()
    started_ms = System.monotonic_time(:millisecond)

    try do
      result = fun.()
      record(issue, opts, started_at, started_ms, outcome_of(result))
      result
    rescue
      exception ->
        record(issue, opts, started_at, started_ms, {"crash", Exception.message(exception)})
        reraise(exception, __STACKTRACE__)
    catch
      kind, value ->
        record(issue, opts, started_at, started_ms, {"crash", "#{kind}: #{inspect(value)}"})
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  defp outcome_of(:ok), do: {"ok", nil}
  defp outcome_of({:error, reason}), do: {"error", inspect(reason)}
  defp outcome_of(_other), do: {"ok", nil}

  defp record(issue, opts, started_at, started_ms, {outcome, detail}) do
    ended_at = DateTime.utc_now()

    entry = %{
      event: "run",
      issue_id: Map.get(issue, :id) || Map.get(issue, "id"),
      issue_identifier: Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      worker_host: Keyword.get(opts, :worker_host) || "local",
      started_at: DateTime.to_iso8601(started_at),
      ended_at: DateTime.to_iso8601(ended_at),
      duration_ms: System.monotonic_time(:millisecond) - started_ms,
      outcome: outcome,
      detail: detail
    }

    append(entry)
  end

  @spec append(map()) :: :ok
  def append(entry) when is_map(entry) do
    file = path()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, line} <- encode(entry),
         :ok <- File.write(file, line, [:append]) do
      :ok
    else
      {:error, reason} ->
        # An observability sink must never take down the run it observes.
        Logger.warning("RunLog: could not append to #{file}: #{inspect(reason)}")
        :ok
    end
  end

  defp encode(entry) do
    {:ok, Jason.encode!(entry) <> "\n"}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Most recent entries, newest first.

  Reads the whole file. The record is one short line per run, so this stays
  cheap for the operational question it answers; a deployment that outgrows
  that wants a real store, not a bigger read.
  """
  @spec recent(pos_integer(), keyword()) :: [map()]
  def recent(limit \\ 100, opts \\ []) do
    issue = Keyword.get(opts, :issue_identifier)

    case File.read(path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Stream.map(&decode_line/1)
        |> Stream.reject(&is_nil/1)
        |> Stream.filter(fn entry ->
          # The file carries more than one event type; this endpoint reports
          # runs. Without the guard a rate-limit observation would be returned
          # as though it were a run.
          entry["event"] == "run" and (is_nil(issue) or entry["issue_identifier"] == issue)
        end)
        |> Enum.take(limit)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("RunLog: could not read #{path()}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Record a rate-limit observation.

  Codex reports these during a turn. The orchestrator keeps the latest in
  memory, which answers "what are the limits right now" and nothing else: the
  value is `null` before the first run of a process, `null` again after a
  restart, and never written down. An operator asking the one question that
  matters when runs start failing — *am I limited, and when does it reset?* —
  has nowhere to look.
  """
  @spec record_rate_limits(map()) :: :ok
  def record_rate_limits(limits) when is_map(limits) do
    append(%{
      event: "rate_limits",
      observed_at: DateTime.to_iso8601(DateTime.utc_now()),
      limits: limits
    })
  end

  def record_rate_limits(_other), do: :ok

  @doc """
  The most recently recorded rate-limit observation, or `nil`.

  Returns `{limits, observed_at}` so a caller can report **when** it was seen.
  A persisted observation presented as though it were live would be worse than
  none: the reader would have no way to tell a current limit from one recorded
  before a restart hours ago.
  """
  @spec latest_rate_limits() :: {map(), String.t()} | nil
  def latest_rate_limits do
    case File.read(path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case decode_line(line) do
            %{"event" => "rate_limits", "limits" => limits, "observed_at" => at} ->
              {limits, at}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, entry} when is_map(entry) -> entry
      # A partially written final line is expected while a run is ending.
      _ -> nil
    end
  end
end
