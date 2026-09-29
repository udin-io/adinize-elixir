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

  describe "a refused request" do
    defp error_body(code, extra \\ %{}),
      do: %{"error" => Map.merge(%{"code" => code, "message" => "why"}, extra)}

    test "202 is not the documented success" do
      respond(202, Stub.accepted("o1"))
      assert {:error, %Adinize.Error{status: 202, code: "HTTP_ERROR"}} = track()
    end

    for {status, code} <- [
          {400, "INVALID_REQUEST"},
          {401, "INVALID_KEY"},
          {403, "PIXEL_INACTIVE"},
          {409, "CONFLICT"},
          {422, "UNPROCESSABLE"}
        ] do
      test "#{status} returns the server's code #{code}" do
        respond(unquote(status), error_body(unquote(code)))

        assert {:error,
                %Adinize.Error{status: unquote(status), code: unquote(code), message: "why"}} =
                 track()
      end
    end

    test "429 carries Retry-After in seconds" do
      respond(429, error_body("RATE_LIMITED", %{"retry_after" => 12}), [{"retry-after", "12"}])

      assert {:error, %Adinize.Error{status: 429, code: "RATE_LIMITED", retry_after: 12}} =
               track()
    end

    test "429 without the header falls back to the body's retry_after" do
      respond(429, error_body("RATE_LIMITED", %{"retry_after" => 7}))
      assert {:error, %Adinize.Error{retry_after: 7}} = track()
    end

    test "a 502 HTML page is HTTP_ERROR" do
      respond(502, {:text, "<html>bad gateway</html>"})
      assert {:error, %Adinize.Error{status: 502, code: "HTTP_ERROR"}} = track()
    end

    test "an error body whose message is not a string" do
      respond(400, %{"error" => %{"code" => "X", "message" => %{"a" => 1}}})
      assert {:error, %Adinize.Error{status: 400, code: "X", message: ""}} = track()
    end
  end

  describe "a request the SDK refuses to send" do
    test "no secret_key is MISSING_SECRET_KEY" do
      respond(200, Stub.accepted("o1"))

      assert {:error, %Adinize.Error{code: "MISSING_SECRET_KEY"}} =
               Adinize.track("Purchase", req_options: [plug: {Req.Test, __MODULE__}])

      refute_received {:request, _, _}
    end

    for {label, opts} <- [
          {"unknown event option", [evnt_id: "x"]},
          {"unknown user field", [user: [phone_number: "+201001234567"]]},
          {"non-string email", [user: [email: 123]]},
          {"phone with invalid UTF-8", [user: [phone: <<255, ?1>>]]},
          {"bad precomputed hash", [user: [email_hash: "ABC"]]},
          {"consent not a keyword list", [user: [consent: [1]]]},
          {"consent with an unknown key", [user: [consent: [ads: true]]]},
          {"user not a list", [user: "jane"]},
          {"empty event_id", [event_id: ""]},
          {"event_time as text", [event_time: "yesterday"]},
          {"page_url not a string", [page_url: URI.parse("https://s/")]},
          {"data not a list", [data: "x"]},
          {"data with a tuple key", [data: %{{1, 2} => 1}]},
          {"data JSON cannot encode", [data: [value: {1, 2}]]},
          {"http base_url", [base_url: "http://adinize.ai"]},
          {"negative receive_timeout", [receive_timeout: -1]},
          {"secret_key not a string", [secret_key: 42]},
          {"req_options an atom", [req_options: :x]},
          {"req_options unknown key", [req_options: [bogus: 1]]},
          {"req_options moving the base_url", [req_options: [base_url: "http://evil.example"]]},
          {"req_options replacing headers", [req_options: [headers: [x: "y"]]]}
        ] do
      test "INVALID_OPTION, nothing sent: #{label}" do
        respond(200, Stub.accepted("o1"))

        assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
                 track(unquote(Macro.escape(opts)))

        refute_received {:request, _, _}
      end
    end

    test "options that are not a keyword list" do
      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} = Adinize.track("x", [:a])
      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} = Adinize.track("x", "a")
    end

    test "an event name that is not a string" do
      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
               Adinize.track(:purchase, Stub.opts(__MODULE__))
    end

    test "the message names the field, never the value" do
      {:error, error} = track(page_url: URI.parse("https://s/?email=jane@example.com"))
      refute Exception.message(error) =~ "jane"
      {:error, error} = track(user: [email: {:jane, "jane@example.com"}])
      refute Exception.message(error) =~ "jane@"
    end

    test "a bad req_options never puts the key in a crash" do
      {:error, error} = track(req_options: :x)
      refute inspect(error, limit: :infinity) =~ @key
    end
  end

  describe "no response" do
    test "a timeout is TIMEOUT" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      assert {:error, %Adinize.Error{status: nil, code: "TIMEOUT", reason: :timeout}} = track()
    end

    test "a refused connection is TRANSPORT_ERROR" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Adinize.Error{code: "TRANSPORT_ERROR", reason: :econnrefused}} = track()
    end

    test "a refused connection on a real socket is TRANSPORT_ERROR" do
      assert {:error, %Adinize.Error{code: "TRANSPORT_ERROR", reason: :econnrefused}} =
               Adinize.track("Purchase", secret_key: @key, base_url: "http://localhost:1")
    end

    test "the error never holds the secret key" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      {:error, error} = track()
      refute inspect(error, limit: :infinity) =~ @key
      refute Exception.message(error) =~ @key
    end
  end
end
