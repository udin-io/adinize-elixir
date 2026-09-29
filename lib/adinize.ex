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

  alias Adinize.{Client, Error, Event, Result}

  @max_batch 100
  @batch_keys [:default_country | Client.client_keys()]

  @spec track(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def track(event_name, opts \\ [])

  def track(event_name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {batch_opts, event_opts} = Keyword.split(opts, @batch_keys)

      with {:ok, [result]} <- track_many([{event_name, event_opts}], batch_opts) do
        {:ok, result}
      end
    else
      invalid("options must be a keyword list")
    end
  end

  def track(_event_name, _opts), do: invalid("options must be a keyword list")

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
      parse_results(results, length(bodies))
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

  defp parse_results(results, count) when length(results) == count do
    results
    |> Enum.reduce_while({:ok, []}, fn json, {:ok, acc} ->
      case Result.from_json(json) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        :error -> {:halt, invalid_response()}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_results(_results, _count), do: invalid_response()

  defp default_country(nil) do
    case Application.get_env(:adinize, :default_country) do
      nil -> {:ok, nil}
      country -> default_country(country)
    end
  end

  defp default_country(country) do
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
