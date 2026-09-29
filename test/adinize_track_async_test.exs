defmodule Adinize.TrackAsyncTest do
  # Shares the default Adinize.Batcher name (track_async/2 takes no name
  # option), so this file cannot run concurrently with another test that
  # also starts the default-named batcher.
  use ExUnit.Case, async: false

  alias Adinize.Test.Stub

  test "the public entry point queues an event for the default batcher and sends it" do
    start_supervised!(
      {Adinize.Batcher, Keyword.merge(Stub.opts(Adinize.Batcher), flush_interval: 20)}
    )

    Stub.respond(Adinize.Batcher, 200, Stub.accepted("public_api_1"))

    assert :ok =
             Adinize.track_async("Purchase",
               event_id: "public_api_1",
               data: [value: 42, currency: "EGP"]
             )

    assert_receive {:request, conn, raw}, 1_000
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> Stub.key()]
    assert %{"events" => [%{"event_id" => "public_api_1"}]} = Jason.decode!(raw)
  end

  test "invalid options never reach the batcher" do
    start_supervised!(
      {Adinize.Batcher, Keyword.merge(Stub.opts(Adinize.Batcher), flush_interval: 20)}
    )

    assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
             Adinize.track_async("", event_id: "bad")

    assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
             Adinize.track_async("Lead", :not_a_list)
  end
end
