defmodule Adinize.Batcher.Queue do
  @moduledoc false
  # Holds the events `Adinize.track_async/2` enqueues and sends them off in
  # chunks of at most `max_batch`, each chunk in its own supervised Task so
  # a crash while sending never loses the queue. Reuses `Adinize.Event`
  # (validation and hashing), `Adinize.Client` (the HTTP call) and
  # `Adinize.Retry` (the retry policy) — nothing here re-implements any of
  # the three.

  use GenServer
  require Logger

  alias Adinize.{Batcher, Client, Error, Event, Result, Retry, Telemetry}

  @default_flush_interval 1_000
  @default_max_batch 100
  @default_max_queue 10_000
  @default_shutdown 5_000
  @hard_max_batch 100

  def default_shutdown, do: @default_shutdown

  def start_link(opts) do
    name = Keyword.get(opts, :name, Adinize.Batcher)
    GenServer.start_link(__MODULE__, opts, name: Batcher.queue_name(name))
  end

  @impl true
  def init(opts) do
    with {:ok, max_batch} <- bounded(opts, :max_batch, @default_max_batch, 1, @hard_max_batch),
         {:ok, max_queue} <- bounded(opts, :max_queue, @default_max_queue, 1, nil),
         {:ok, flush_interval} <- bounded(opts, :flush_interval, @default_flush_interval, 1, nil),
         {:ok, shutdown} <- bounded(opts, :shutdown, @default_shutdown, 1, nil),
         {:ok, default_country} <- Adinize.default_country(Keyword.get(opts, :default_country)) do
      Process.flag(:trap_exit, true)

      state = %{
        name: Keyword.get(opts, :name, Adinize.Batcher),
        queue: :queue.new(),
        queue_size: 0,
        max_batch: max_batch,
        max_queue: max_queue,
        flush_interval: flush_interval,
        shutdown: shutdown,
        default_country: default_country,
        client_opts: Keyword.take(opts, Client.client_keys()),
        in_flight: %{},
        timer_ref: nil
      }

      {:ok, schedule_tick(state)}
    else
      {:error, message} ->
        Logger.error("Adinize.Batcher failed to start: #{message}")
        {:stop, {:invalid_option, message}}
    end
  end

  @impl true
  def handle_call({:enqueue, event_name, opts}, _from, state) do
    case Event.build(event_name, opts, state.default_country) do
      {:ok, body} ->
        if state.queue_size >= state.max_queue do
          Telemetry.dropped(body, event_name, :queue_full)
          {:reply, {:error, :queue_full}, state}
        else
          state = %{
            state
            | queue: :queue.in({event_name, body}, state.queue),
              queue_size: state.queue_size + 1
          }

          {:reply, :ok, flush_ready(state)}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = state |> flush_all() |> schedule_tick()
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_map_key(state.in_flight, ref) do
    Process.demonitor(ref, [:flush])
    {{_task, chunk}, in_flight} = Map.pop(state.in_flight, ref)
    handle_chunk_result(result, chunk, %{state | in_flight: in_flight})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.in_flight, ref) do
    {{_task, chunk}, in_flight} = Map.pop(state.in_flight, ref)
    safe_reason = sanitize_reason(reason)
    Logger.error("Adinize.Batcher flush crashed: #{safe_reason}")

    handle_chunk_result(
      {:error, %Error{code: "CRASHED", message: "the send crashed: #{safe_reason}"}},
      chunk,
      %{state | in_flight: in_flight}
    )
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    drain(state)
    :ok
  end

  # --- flushing -----------------------------------------------------------

  # Called after every enqueue: send immediately once a whole chunk is
  # ready, so a burst does not wait for the timer.
  defp flush_ready(state) do
    if state.queue_size >= state.max_batch do
      state |> pop_and_send() |> flush_ready()
    else
      state
    end
  end

  # Called on every tick: send whatever is queued, even a partial chunk.
  defp flush_all(state) do
    if state.queue_size > 0 do
      state |> pop_and_send() |> flush_all()
    else
      state
    end
  end

  defp pop_and_send(state) do
    {chunk, rest, rest_size} = pop_chunk(state.queue, min(state.max_batch, state.queue_size))
    state = %{state | queue: rest, queue_size: rest_size}
    start_task(chunk, state)
  end

  defp pop_chunk(queue, 0), do: {[], queue, 0}

  defp pop_chunk(queue, take) do
    {items, queue} =
      Enum.map_reduce(1..take, queue, fn _i, q ->
        {{:value, item}, q} = :queue.out(q)
        {item, q}
      end)

    {items, queue, :queue.len(queue)}
  end

  defp start_task(chunk, state) do
    bodies = Enum.map(chunk, fn {_name, body} -> body end)
    client_opts = state.client_opts

    task =
      Task.Supervisor.async_nolink(Batcher.task_supervisor_name(state.name), fn ->
        safe_flush(fn -> send_with_retry(bodies, client_opts) end)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, {task, chunk})}
  end

  defp send_with_retry(bodies, client_opts) do
    Retry.run(fn -> Client.post_events(bodies, client_opts) end)
  end

  defp send_once(bodies, client_opts) do
    safe_flush(fn -> Client.post_events(bodies, client_opts) end)
  end

  # OTP logs a crashed Task's exit reason automatically, in full, via its
  # own crash report — independent of anything Logger.error/warning here
  # does. That reason can embed whatever the crashing call's own
  # arguments were (a MatchError's failing term, for one), and this
  # closure captures state.client_opts (the secret key). Catching every
  # reachable exception here, before it ever reaches Task.Supervised,
  # means OTP never generates that report — only an untrappable kill
  # still reaches handle_info({:DOWN, ...}), and a kill reason is always
  # the bare atom :killed, nothing more.
  defp safe_flush(fun) do
    fun.()
  rescue
    exception ->
      {:error,
       %Error{code: "CRASHED", message: "the flush crashed: #{inspect(exception.__struct__)}"}}
  catch
    kind, _reason ->
      {:error, %Error{code: "CRASHED", message: "the flush exited: #{kind}"}}
  end

  defp handle_chunk_result({:ok, results}, chunk, state) do
    report_results(results, chunk)
    {:noreply, state}
  end

  defp handle_chunk_result({:error, error}, chunk, state) do
    Logger.warning(
      "Adinize.Batcher dropped #{length(chunk)} event(s): #{Exception.message(error)}"
    )

    Enum.each(chunk, fn {event_name, body} ->
      Telemetry.dropped(body, event_name, drop_reason(error))
    end)

    {:noreply, state}
  end

  # A count (or order) mismatch between what the server answered and what
  # this chunk sent must never be papered over by Enum.zip's silent
  # truncation — that would drop or misattribute events with no
  # telemetry at all. Treat it exactly like Adinize.parse_results/3 does:
  # the whole chunk is unaccounted for, so it is dropped.
  defp report_results(results, chunk) when length(results) == length(chunk) do
    results
    |> Enum.zip(chunk)
    |> Enum.each(fn {json, {event_name, _body}} ->
      case Result.from_json(json) do
        {:ok, %Result{status: :rejected} = result} -> Telemetry.rejected(result, event_name)
        _ok_accepted_duplicate_or_unparsable -> :ok
      end
    end)
  end

  defp report_results(results, chunk) do
    Logger.warning(
      "Adinize.Batcher got #{length(results)} result(s) back for #{length(chunk)} event(s); dropping the chunk"
    )

    drop_chunk(chunk, :rejected_by_server)
  end

  defp drop_reason(%Error{code: "CRASHED"}), do: :crashed

  defp drop_reason(%Error{} = error) do
    if Retry.retryable?(error), do: :retries_exhausted, else: :rejected_by_server
  end

  # A Task's :DOWN reason can be any term, including one that embeds the
  # flush closure's own arguments (bodies, client_opts — the secret key).
  # Never inspect it whole; keep only a shape safe to log, the same way
  # Client.handle/1 already strips a raised exception to its module name.
  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason({%module{}, stacktrace}) when is_list(stacktrace), do: inspect(module)
  defp sanitize_reason({:shutdown, reason}), do: "shutdown: #{sanitize_reason(reason)}"
  defp sanitize_reason(_reason), do: "unrecognized exit reason"

  # --- shutdown -------------------------------------------------------------

  # Best effort: one attempt per remaining chunk, no retries — retrying
  # would blow the shutdown budget. Whatever cannot be sent (or answered)
  # before the deadline is dropped with telemetry.
  defp drain(state) do
    deadline = System.monotonic_time(:millisecond) + state.shutdown

    state
    |> flush_remaining_queue()
    |> await_in_flight(deadline)
  end

  defp flush_remaining_queue(state) do
    if state.queue_size > 0 do
      {chunk, rest, rest_size} = pop_chunk(state.queue, min(state.max_batch, state.queue_size))
      bodies = Enum.map(chunk, fn {_name, body} -> body end)
      client_opts = state.client_opts

      task =
        Task.Supervisor.async_nolink(Batcher.task_supervisor_name(state.name), fn ->
          send_once(bodies, client_opts)
        end)

      %{
        state
        | queue: rest,
          queue_size: rest_size,
          in_flight: Map.put(state.in_flight, task.ref, {task, chunk})
      }
      |> flush_remaining_queue()
    else
      state
    end
  end

  defp await_in_flight(state, deadline) do
    Enum.each(state.in_flight, fn {_ref, {task, chunk}} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      result =
        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, value} -> {:ok, value}
          _timed_out_or_already_down -> :killed
        end

      case result do
        {:ok, {:ok, results}} -> report_results(results, chunk)
        {:ok, {:error, error}} -> drop_chunk(chunk, drop_reason(error))
        _killed_or_timed_out -> drop_chunk(chunk, :shutdown_timeout)
      end
    end)

    state
  end

  defp drop_chunk(chunk, reason) do
    Enum.each(chunk, fn {event_name, body} -> Telemetry.dropped(body, event_name, reason) end)
  end

  # --- config -----------------------------------------------------------

  defp schedule_tick(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: Process.send_after(self(), :tick, state.flush_interval)}
  end

  defp bounded(opts, key, default, min, max) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= min and (is_nil(max) or value <= max) ->
        {:ok, value}

      _other ->
        {:error, "#{key} must be an integer" <> range_text(min, max)}
    end
  end

  defp range_text(min, nil), do: " >= #{min}"
  defp range_text(min, max), do: " between #{min} and #{max}"
end
