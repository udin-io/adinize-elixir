defmodule Adinize do
  @moduledoc """
  Sends conversion events from your server to the adinize server events API.

      # config/runtime.exs
      config :adinize, secret_key: System.fetch_env!("ADINIZE_SECRET_KEY")

      Adinize.track("Purchase",
        event_id: "order_10482",
        user: [email: "jane@example.com"],
        data: [value: 129.5, currency: "EGP"]
      )
      #=> {:ok, %Adinize.Result{event_id: "order_10482", status: :accepted, errors: []}}

  Personal fields (`email`, `phone`, `first_name`, `last_name`,
  `street_address`) leave your server only as SHA-256 hashes; see
  `Adinize.Hash`.
  """

  alias Adinize.{Batcher, Client, Error, Event, Result, Retry, Telemetry}

  @max_batch 100
  @batch_keys [:default_country | Client.client_keys()]

  @doc """
  Same as `track/2`, plus `retry: true` (default `false`): on a 429 it
  waits `Retry-After`; on a 5xx, a timeout or a transport error it backs
  off with jitter; either way it sends the same `event_id` again, up to 5
  attempts total. A 400, 401 or other non-retryable error returns on the
  first attempt, same as `retry: false`.
  """
  @spec track(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def track(event_name, opts \\ [])

  def track(event_name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {retry?, opts} = Keyword.pop(opts, :retry, false)
      {batch_opts, event_opts} = Keyword.split(opts, @batch_keys)
      dispatch_track(retry?, event_name, event_opts, batch_opts)
    else
      invalid("options must be a keyword list")
    end
  end

  def track(_event_name, _opts), do: invalid("options must be a keyword list")

  defp dispatch_track(true, event_name, event_opts, batch_opts),
    do: track_with_retry(event_name, event_opts, batch_opts)

  defp dispatch_track(false, event_name, event_opts, batch_opts) do
    with {:ok, [result]} <- track_many([{event_name, event_opts}], batch_opts) do
      {:ok, result}
    end
  end

  defp track_with_retry(event_name, event_opts, batch_opts) do
    with {:ok, country} <- default_country(Keyword.get(batch_opts, :default_country)),
         {:ok, body} <- Event.build(event_name, event_opts, country) do
      client_opts = Keyword.delete(batch_opts, :default_country)

      fn -> Client.post_events([body], client_opts) end
      |> Retry.run()
      |> single_result(event_name)
    end
  end

  defp single_result({:ok, results}, event_name) do
    with {:ok, [result]} <- parse_results(results, 1, [event_name]), do: {:ok, result}
  end

  defp single_result({:error, _} = error, _event_name), do: error

  @doc """
  Queues one event for the running `Adinize.Batcher` to send later. Takes
  the same options as `track/2` except the batch options (`:secret_key`,
  `:base_url`, ...), which the batcher was configured with once at start.

  Returns `:ok` once the event is queued, never once it is sent.
  `{:error, :batcher_not_started}` when no batcher is running,
  `{:error, :queue_full}` past `:max_queue`, or the same
  `{:error, %Adinize.Error{}}` `track/2` would return for the same
  options — the event was never queued.
  """
  @spec track_async(String.t(), keyword()) ::
          :ok | {:error, :batcher_not_started | :queue_full | Error.t()}
  def track_async(event_name, opts \\ [])

  def track_async(event_name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Batcher.enqueue(event_name, opts)
    else
      invalid("options must be a keyword list")
    end
  end

  def track_async(_event_name, _opts), do: invalid("options must be a keyword list")

  @doc """
  Sends 1 to 100 events in one request. Each entry is `{event_name, opts}`
  with the event options `track/2` takes; the batch options (`:secret_key`,
  `:base_url`, `:receive_timeout`, `:req_options`, `:default_country`) go
  in `opts`. Results come back in input order. More than 100 events return
  `TOO_MANY_EVENTS` and nothing is sent.
  """
  @spec track_many([{String.t(), keyword()}], keyword()) ::
          {:ok, [Result.t()]} | {:error, Error.t()}
  def track_many(events, opts \\ [])

  def track_many(events, _opts) when is_list(events) and length(events) > @max_batch,
    do:
      {:error,
       %Error{code: "TOO_MANY_EVENTS", message: "send at most #{@max_batch} events a request"}}

  def track_many([_ | _] = events, opts) when is_list(opts) do
    with :ok <- proper_list(events),
         :ok <- batch_keys_only(opts),
         {:ok, country} <- default_country(Keyword.get(opts, :default_country)),
         {:ok, bodies} <- build_all(events, country),
         {:ok, results} <- Client.post_events(bodies, Keyword.delete(opts, :default_country)) do
      parse_results(results, length(bodies), Enum.map(events, fn {name, _opts} -> name end))
    end
  end

  def track_many(_events, _opts),
    do: invalid("events must be a non-empty list, and options a keyword list")

  defp proper_list(events) do
    if List.improper?(events), do: invalid("events must be a proper list"), else: :ok
  end

  defp batch_keys_only(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- @batch_keys == [],
      do: :ok,
      else: invalid("track_many options take only #{inspect(@batch_keys)}")
  end

  defp build_all(events, country) do
    events
    |> Enum.reduce_while({:ok, []}, fn
      {name, event_opts}, {:ok, acc} ->
        case Event.build(name, event_opts, country) do
          {:ok, body} -> {:cont, {:ok, [body | acc]}}
          error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, invalid("each event must be {event_name, opts}")}
    end)
    |> case do
      {:ok, bodies} -> {:ok, Enum.reverse(bodies)}
      error -> error
    end
  end

  defp parse_results(results, count, names) when length(results) == count do
    results
    |> Enum.zip(names)
    |> Enum.reduce_while({:ok, []}, fn {json, name}, {:ok, acc} ->
      case Result.from_json(json) do
        {:ok, %Result{status: :rejected} = result} ->
          Telemetry.rejected(result, name)
          {:cont, {:ok, [result | acc]}}

        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        :error ->
          {:halt, invalid_response()}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_results(_results, _count, _names), do: invalid_response()

  @doc false
  # Shared with Adinize.Batcher.Queue, which resolves the same option once
  # at start instead of on every enqueue.
  @spec default_country(String.t() | nil) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def default_country(nil) do
    case Application.get_env(:adinize, :default_country) do
      nil -> {:ok, nil}
      country -> default_country(country)
    end
  end

  def default_country(country) do
    case Adinize.Phone.country_code(country) do
      {:ok, _code} -> {:ok, country}
      :error -> invalid("default_country must be one of #{Adinize.Phone.countries()}")
    end
  end

  defp invalid(message), do: {:error, %Error{code: "INVALID_OPTION", message: message}}

  defp invalid_response,
    do:
      {:error,
       %Error{
         status: 200,
         code: "INVALID_RESPONSE",
         message: "the results do not match the events sent"
       }}
end
