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

  defp handle({:ok, %Req.Response{status: status} = response}) do
    case response.body do
      %{"error" => %{"code" => code} = err} when is_binary(code) and status != 200 ->
        {:error,
         %Error{
           status: status,
           code: code,
           message: if(is_binary(err["message"]), do: err["message"], else: ""),
           retry_after: retry_after(response, err)
         }}

      _ ->
        error(status, "HTTP_ERROR", "the API answered HTTP #{status}")
    end
  end

  defp handle({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, %Error{code: "TIMEOUT", message: "no response in time", reason: :timeout}}

  defp handle({:error, %Req.TransportError{reason: reason}}) when is_atom(reason),
    do:
      {:error,
       %Error{code: "TRANSPORT_ERROR", message: "connection failed: #{reason}", reason: reason}}

  # Any other exception may hold the request, and so the key. Keep only its
  # module name.
  defp handle({:error, exception}),
    do:
      {:error,
       %Error{
         code: "TRANSPORT_ERROR",
         message: "request failed: #{inspect(exception.__struct__)}"
       }}

  defp retry_after(response, err) do
    header =
      case Req.Response.get_header(response, "retry-after") do
        [value | _] -> Integer.parse(value)
        [] -> :error
      end

    case {header, err["retry_after"]} do
      {{seconds, ""}, _} -> seconds
      {_, seconds} when is_integer(seconds) -> seconds
      _ -> nil
    end
  end

  defp config(opts, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Application.get_env(:adinize, key, default) end)

  defp error(status, code, message),
    do: {:error, %Error{status: status, code: code, message: message}}
end
