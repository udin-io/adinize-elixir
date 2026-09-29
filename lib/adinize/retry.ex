defmodule Adinize.Retry do
  @moduledoc false
  # Retries a send that returns {:ok, _} | {:error, %Adinize.Error{}}, up to
  # 5 total attempts. 429 waits the server's Retry-After (falling back to
  # the same backoff as a 5xx when the server gives none); a 5xx, a
  # timeout or a transport error backs off with full jitter; a 400, 401 or
  # any other non-retryable error returns on the first attempt. Shared by
  # `Adinize.track/2` (retry: true) and `Adinize.Batcher.Queue`, so both
  # retry the exact same way.

  alias Adinize.Error

  @max_attempts 5
  @base_ms 200
  @cap_ms 10_000

  @spec run((-> {:ok, term()} | {:error, Error.t()}), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def run(fun, opts \\ []) when is_function(fun, 0) do
    attempt(fun, 1, opts)
  end

  defp attempt(fun, attempt_no, opts) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, %Error{} = error} = failure ->
        if attempt_no < @max_attempts and retryable?(error) do
          sleep(delay_ms(error, attempt_no, opts))
          attempt(fun, attempt_no + 1, opts)
        else
          failure
        end
    end
  end

  @doc false
  @spec retryable?(Error.t()) :: boolean()
  def retryable?(%Error{status: 429}), do: true
  def retryable?(%Error{status: status}) when is_integer(status) and status >= 500, do: true
  def retryable?(%Error{status: nil, reason: :timeout}), do: true
  def retryable?(%Error{status: nil, code: "TIMEOUT"}), do: true
  def retryable?(%Error{status: nil, code: "TRANSPORT_ERROR"}), do: true
  def retryable?(%Error{}), do: false

  defp delay_ms(%Error{status: 429, retry_after: seconds}, _attempt_no, _opts)
       when is_integer(seconds) and seconds >= 0,
       do: seconds * 1_000

  defp delay_ms(%Error{}, attempt_no, opts), do: backoff_ms(attempt_no, opts)

  defp backoff_ms(attempt_no, opts) do
    base = Keyword.get(opts, :base_ms, @base_ms)
    cap = Keyword.get(opts, :cap_ms, @cap_ms)
    ceiling = min(cap, base * Integer.pow(2, attempt_no - 1))
    Enum.random(1..max(ceiling, 1))
  end

  defp sleep(ms), do: Process.sleep(ms)
end
