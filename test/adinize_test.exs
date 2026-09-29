defmodule AdinizeTest do
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  @key Stub.key()

  defp respond(status, body, headers \\ []), do: Stub.respond(__MODULE__, status, body, headers)

  defp track(opts \\ []),
    do: Adinize.track("Purchase", Keyword.merge(Stub.opts(__MODULE__), opts))

  defp sent_event do
    assert_received {:request, _conn, raw}
    %{"events" => [event]} = Jason.decode!(raw)
    event
  end

  describe "the request" do
    test "carries email_hash, never the email, and the key only in the bearer header" do
      respond(200, Stub.accepted("o1"))

      track(
        event_id: "o1",
        user: [
          email: " Jane@Example.com ",
          phone: "+20 100 123 4567",
          client_ip_address: "203.0.113.7"
        ],
        data: [value: 129.5, currency: "EGP"]
      )

      assert_received {:request, conn, raw}
      assert conn.method == "POST"
      assert conn.request_path == "/api/server/v1/events"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @key]
      %{"events" => [event]} = Jason.decode!(raw)

      assert event["event_name"] == "Purchase"

      assert event["user_data"] == %{
               "email_hash" => "8c87b489ce35cf2e2f39f80e282cb2e804932a56a213983eeeb428407d43b52d",
               "phone_hash" => "9476e557c9e413deae474978709659f5b4f1c6a18553eddff8f042702843d0c7",
               "client_ip_address" => "203.0.113.7"
             }

      assert event["event_data"] == %{"value" => 129.5, "currency" => "EGP"}
      refute raw =~ "Jane"
      refute raw =~ "100 123"
      refute raw =~ @key
    end

    test "defaults event_id to a UUIDv4 and event_time to now, in Unix seconds" do
      respond(200, Stub.accepted("x"))
      track()
      event = sent_event()

      assert event["event_id"] =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      assert_in_delta event["event_time"], System.os_time(:second), 5
    end

    test "sends a DateTime event_time as Unix seconds" do
      respond(200, Stub.accepted("x"))
      track(event_time: ~U[2026-09-29 10:00:00Z])
      assert sent_event()["event_time"] == 1_790_676_000
    end

    test "passes visitor_id, page_url and a precomputed hash through" do
      respond(200, Stub.accepted("x"))
      hash = String.duplicate("a", 64)

      track(
        visitor_id: "mb.1.k3",
        page_url: "https://shop.example.com/",
        user: [email_hash: hash]
      )

      event = sent_event()
      assert event["visitor_id"] == "mb.1.k3"
      assert event["page_url"] == "https://shop.example.com/"
      assert event["user_data"] == %{"email_hash" => hash}
    end

    test "leaves out a phone that has no E.164 form" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "0501234567"])
      refute Map.has_key?(sent_event(), "user_data")
    end
  end

  describe "a 200 answer" do
    test "accepted" do
      respond(200, Stub.accepted("o1"))

      assert {:ok, %Adinize.Result{event_id: "o1", status: :accepted, errors: []}} =
               track(event_id: "o1")
    end

    test "duplicate" do
      respond(200, %{"results" => [%{"event_id" => "o1", "status" => "duplicate"}]})
      assert {:ok, %Adinize.Result{status: :duplicate}} = track(event_id: "o1")
    end

    test "rejected carries the server's errors" do
      err = %{"field" => "event_time", "code" => "TOO_OLD", "message" => "old"}

      respond(200, %{
        "results" => [%{"event_id" => "o1", "status" => "rejected", "errors" => [err]}]
      })

      assert {:ok,
              %Adinize.Result{
                status: :rejected,
                errors: [%{field: "event_time", code: "TOO_OLD", message: "old"}]
              }} = track(event_id: "o1")
    end

    test "without a results list is INVALID_RESPONSE" do
      respond(200, %{"nope" => 1})
      assert {:error, %Adinize.Error{status: 200, code: "INVALID_RESPONSE"}} = track()
    end

    test "with an unknown status is INVALID_RESPONSE" do
      respond(200, %{"results" => [%{"event_id" => "o1", "status" => "queued"}]})
      assert {:error, %Adinize.Error{status: 200, code: "INVALID_RESPONSE"}} = track()
    end
  end
end
