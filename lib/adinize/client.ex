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
    with {:ok, req_options} <- req_options(opts),
         {:ok, key} <- secret_key(opts),
         {:ok, base_url} <- base_url(opts),
         {:ok, timeout} <- receive_timeout(opts),
         {:ok, body} <- encode(%{"events" => events}) do
      # Our options win, so req_options cannot move the key to another
      # host, drop the auth header or turn redirects back on.
      req_options
      |> Keyword.merge(
        method: :post,
        base_url: base_url,
        url: "/api/server/v1/events",
        body: body,
        headers: [
          {"content-type", "application/json"},
          {"accept", "application/json"},
          {"authorization", "Bearer " <> key}
        ],
        receive_timeout: timeout,
        retry: false,
        redirect: false,
        decode_body: false
      )
      |> request()
      |> handle()
    end
  end

  # The body is decoded here, not by Req, so a response that is not JSON
  # keeps its status instead of surfacing as a decode exception.
  defp request(options) do
    case options |> Req.new() |> Req.request() do
      {:ok, response} -> {:ok, %{response | body: decode(response.body)}}
      error -> error
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, _reason -> {:error, :exit}
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  @allowed_req_options [:plug, :adapter, :connect_options, :finch, :inet6]

  defp req_options(opts) do
    value = config(opts, :req_options, [])

    if is_list(value) and Keyword.keyword?(value) and
         Keyword.keys(value) -- @allowed_req_options == [],
       do: {:ok, value},
       else: invalid("req_options takes only #{inspect(@allowed_req_options)}")
  end

  defp secret_key(opts) do
    case config(opts, :secret_key, nil) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      nil ->
        error(nil, "MISSING_SECRET_KEY", "set :secret_key in config :adinize or pass it")

      _ ->
        invalid("secret_key must be a string")
    end
  end

  # http only for a local server, so a typo cannot send the key in clear.
  defp base_url(opts) do
    url = config(opts, :base_url, @default_base_url)

    case is_binary(url) && URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] -> {:ok, url}
      _ -> invalid("base_url must be an https URL")
    end
  end

  defp receive_timeout(opts) do
    case config(opts, :receive_timeout, @default_receive_timeout) do
      ms when is_integer(ms) and ms > 0 -> {:ok, ms}
      _ -> invalid("receive_timeout must be a positive integer")
    end
  end

  defp encode(body) do
    case Jason.encode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> invalid("data holds a value JSON cannot encode")
    end
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

  defp handle({:error, :exit}),
    do: {:error, %Error{code: "TRANSPORT_ERROR", message: "the HTTP client exited"}}

  # Any other exception may hold the request, and so the key. Keep only its
  # module name.
  defp handle({:error, %module{}}),
    do: {:error, %Error{code: "TRANSPORT_ERROR", message: "request failed: #{inspect(module)}"}}

  defp retry_after(response, err) do
    header =
      case Req.Response.get_header(response, "retry-after") do
        [value | _] -> Integer.parse(value)
        [] -> :error
      end

    case {header, err["retry_after"]} do
      {{seconds, ""}, _} when seconds >= 0 -> seconds
      {_, seconds} when is_integer(seconds) and seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp config(opts, key, default),
    do: Keyword.get_lazy(opts, key, fn -> Application.get_env(:adinize, key, default) end)

  defp invalid(message), do: error(nil, "INVALID_OPTION", message)

  defp error(status, code, message),
    do: {:error, %Error{status: status, code: code, message: message}}
end
