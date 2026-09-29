defmodule Adinize.Batcher.TelemetrySecurityTest do
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  test "a dropped event's telemetry never carries the queued event's data, only its id" do
    name = :"telemetry_sec_drop_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])

    start_supervised!(
      {Adinize.Batcher,
       Keyword.merge(Stub.opts(name),
         flush_interval: 60_000,
         max_batch: 100,
         max_queue: 1,
         name: name
       )},
      id: name
    )

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "keep")

    assert {:error, :queue_full} =
             Adinize.Batcher.enqueue(name, "Purchase",
               event_id: "dropped1",
               user: [email: "someone@example.com"]
             )

    assert_receive {[:adinize, :event, :dropped], ^ref, %{count: 1}, metadata}, 1_000
    assert metadata.event_id == "dropped1"
    refute inspect(metadata) =~ "someone@example.com"
    assert map_size(metadata) == 3
    assert Map.keys(metadata) |> Enum.sort() == [:event_id, :event_name, :reason]
  end
end
