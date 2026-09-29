defmodule Adinize.Client do
  @moduledoc false
  # One POST to /api/server/v1/events. Every outcome becomes a value:
  # `{:ok, [result_json]}` or `{:error, %Adinize.Error{}}`. Nothing here
  # logs or stores the secret key.

  alias Adinize.Error

  @default_base_url "https://adinize.ai"
  @default_receive_timeout 15_000
  @client_keys [:secret_key, :base_url, :receive_timeout, :req_options]

  def client_keys, do: @client_keys

  @spec post_events([map()], keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def post_events(events, opts) do
    key = config(opts, :secret_key, nil)

    Keyword.merge(config(opts, :req_options, []),
      method: :post,
      base_url: config(opts, :base_url, @default_base_url),
      url: "/api/server/v1/events",
      json: %{"events" => events},
      headers: [{"accept", "application/json"}, {"authorization", "Bearer " <> key}],
      receive_timeout: config(opts, :receive_timeout, @default_receive_timeout),
      retry: false,
      redirect: false
    )
    |> Req.new()
    |> Req.request()
    |> handle()
  end

  defp handle({:ok, %Req.Response{status: 200, body: %{"results" => results}}})
       when is_list(results),
       do: {:ok, results}

  defp handle({:ok, %Req.Response{status: 200}}),
    do: error(200, "INVALID_RESPONSE", "the 200 response carried no results list")

  defp handle({:ok, %Req.Response{status: status}}),
    do: error(status, "HTTP_ERROR", "the API answered HTTP #{status}")

  defp config(opts, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Application.get_env(:adinize, key, default) end)

  defp error(status, code, message),
    do: {:error, %Error{status: status, code: code, message: message}}
end
