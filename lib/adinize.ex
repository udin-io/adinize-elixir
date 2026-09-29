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

  @spec track(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def track(event_name, opts \\ [])

  def track(event_name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {client_opts, event_opts} = Keyword.split(opts, Client.client_keys())
      {country, event_opts} = Keyword.pop(event_opts, :default_country)

      with {:ok, country} <- default_country(country),
           {:ok, event} <- Event.build(event_name, event_opts, country),
           {:ok, [json]} <- Client.post_events([event], client_opts) do
        case Result.from_json(json) do
          {:ok, result} -> {:ok, result}
          :error -> invalid_response()
        end
      else
        {:ok, _other} -> invalid_response()
        error -> error
      end
    else
      invalid("options must be a keyword list")
    end
  end

  def track(_event_name, _opts), do: invalid("options must be a keyword list")

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
