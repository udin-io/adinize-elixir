defmodule Adinize.Telemetry do
  @moduledoc false
  # The two event-level telemetry events, in one place so `Adinize` (sync)
  # and `Adinize.Batcher.Queue` (async) emit the same shape. Metadata never
  # holds the secret key, a request or a response — only the event name,
  # the event_id the caller gave or Event.build generated, and the
  # server's own field/code/message strings for a rejection.

  alias Adinize.Result

  @spec rejected(Result.t(), String.t()) :: :ok
  def rejected(%Result{} = result, event_name) do
    result.errors
    |> List.wrap()
    |> Enum.each(fn err ->
      :telemetry.execute([:adinize, :event, :rejected], %{count: 1}, %{
        event_id: result.event_id,
        event_name: event_name,
        field: err.field,
        code: err.code,
        message: err.message
      })
    end)
  end

  @type drop_reason ::
          :queue_full | :retries_exhausted | :rejected_by_server | :crashed | :shutdown_timeout

  @spec dropped(map(), String.t(), drop_reason()) :: :ok
  def dropped(body, event_name, reason) do
    :telemetry.execute([:adinize, :event, :dropped], %{count: 1}, %{
      event_id: body["event_id"],
      event_name: event_name,
      reason: reason
    })
  end
end
