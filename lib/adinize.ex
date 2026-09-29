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
  def track(event_name, opts \\ []) do
    {client_opts, event_opts} = Keyword.split(opts, Client.client_keys())
    {:ok, event} = Event.build(event_name, event_opts, nil)

    with {:ok, [json]} <- Client.post_events([event], client_opts) do
      case Result.from_json(json) do
        {:ok, result} -> {:ok, result}
        :error -> invalid_response()
      end
    end
  end

  defp invalid_response,
    do:
      {:error,
       %Error{
         status: 200,
         code: "INVALID_RESPONSE",
         message: "the results do not match the events sent"
       }}
end
