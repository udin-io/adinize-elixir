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

  describe "platform_event_names" do
    test "sends the name each platform gets instead of adinize's mapping" do
      respond(200, Stub.accepted("o1"))

      Adinize.track(
        "Lead",
        Keyword.merge(Stub.opts(__MODULE__), platform_event_names: [tiktok: "Contact"])
      )

      event = sent_event()
      assert event["event_name"] == "Lead"
      assert event["platform_event_names"] == %{"tiktok" => "Contact"}
    end

    test "takes a map with string keys for both platforms" do
      respond(200, Stub.accepted("o1"))
      track(platform_event_names: %{"meta" => "Purchase", "tiktok" => "CompletePayment"})

      assert sent_event()["platform_event_names"] == %{
               "meta" => "Purchase",
               "tiktok" => "CompletePayment"
             }
    end

    test "an empty list sends no platform_event_names" do
      respond(200, Stub.accepted("o1"))
      track(platform_event_names: [])

      refute Map.has_key?(sent_event(), "platform_event_names")
    end

    test "a refusal names the platform, never the event name" do
      respond(200, Stub.accepted("o1"))

      assert {:error, %Adinize.Error{code: "INVALID_OPTION", message: message}} =
               track(platform_event_names: [google_ads: "secret_campaign_name"])

      assert message =~ "google_ads"
      assert message =~ "meta and tiktok"
      refute message =~ "secret_campaign_name"
    end
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
               "phone_digits_hash" =>
                 "6993ec5cc979510592725a267129b73cee2e99c29488027fe094dd24a9e1bfb3",
               "client_ip_address" => "203.0.113.7"
             }

      assert event["event_data"] == %{"value" => 129.5, "currency" => "EGP"}
      refute raw =~ "Jane"
      refute raw =~ "100 123"
      refute raw =~ @key
    end

    test "no personal field leaves in plain text, in any form" do
      respond(200, Stub.accepted("o1"))

      track(
        default_country: "EG",
        user: [
          email: "Jane.Doe@Example.com",
          phone: "0100 123 4567",
          first_name: "Janeth",
          last_name: "Qassem",
          street_address: "17 Tahrir Square"
        ]
      )

      assert_received {:request, _conn, raw}

      for plain <- ~w(jane Janeth janeth Qassem qassem Tahrir tahrir 1001234567 1234567) do
        refute raw =~ plain, "the body holds #{plain}"
      end

      %{"events" => [event]} = Jason.decode!(raw)

      assert Map.keys(event["user_data"]) |> Enum.sort() ==
               ~w(email_hash first_name_hash last_name_hash phone_digits_hash phone_hash street_address_hash)
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

    test "drops the query string from a page_url passed directly" do
      respond(200, Stub.accepted("x"))
      track(page_url: "https://shop.example.com/done?email=jane@example.com#thanks")
      assert sent_event()["page_url"] == "https://shop.example.com/done#thanks"
    end

    test "keeps the query string with query_string: true" do
      respond(200, Stub.accepted("x"))
      track(page_url: "https://shop.example.com/done?utm_source=meta", query_string: true)
      assert sent_event()["page_url"] == "https://shop.example.com/done?utm_source=meta"
    end

    test "track_many drops each page_url's query string too" do
      respond(200, %{
        "results" => [
          %{"event_id" => "a", "status" => "accepted"},
          %{"event_id" => "b", "status" => "accepted"}
        ]
      })

      Adinize.track_many(
        [
          {"Lead", [event_id: "a", page_url: "https://s.example.com/a?x=1"]},
          {"Lead", [event_id: "b", page_url: "https://s.example.com/b?y=2", query_string: true]}
        ],
        Stub.opts(__MODULE__)
      )

      assert_received {:request, _conn, raw}
      %{"events" => [a, b]} = Jason.decode!(raw)
      assert a["page_url"] == "https://s.example.com/a"
      assert b["page_url"] == "https://s.example.com/b?y=2"
    end

    test "leaves out a phone that has no E.164 form" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "0501234567"])
      refute Map.has_key?(sent_event(), "user_data")
    end

    test "a phone sends both hashes, from one E.164 number" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "0100 123 4567"], default_country: "EG")
      user_data = sent_event()["user_data"]

      assert user_data["phone_hash"] ==
               "9476e557c9e413deae474978709659f5b4f1c6a18553eddff8f042702843d0c7"

      assert user_data["phone_digits_hash"] ==
               "6993ec5cc979510592725a267129b73cee2e99c29488027fe094dd24a9e1bfb3"
    end

    test "the digits of a phone never leave, only their hash" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "+20 100 123 4567"])
      assert_received {:request, _conn, raw}
      refute raw =~ "201001234567"
    end

    test "pre-hashed phone keys reach the body as given, alone or together" do
      digits = String.duplicate("b", 64)
      plus = String.duplicate("c", 64)

      for {user, expected} <- [
            {[phone_digits_hash: digits], %{"phone_digits_hash" => digits}},
            {[phone_hash: plus], %{"phone_hash" => plus}},
            {[phone_hash: plus, phone_digits_hash: digits],
             %{"phone_hash" => plus, "phone_digits_hash" => digits}}
          ] do
        respond(200, Stub.accepted("x"))
        track(user: user)
        assert sent_event()["user_data"] == expected
      end
    end

    test "a nil phone beside a pre-hashed phone key sends the pre-hashed key" do
      respond(200, Stub.accepted("x"))
      hash = String.duplicate("b", 64)
      track(user: [phone: nil, phone_digits_hash: hash])
      assert sent_event()["user_data"] == %{"phone_digits_hash" => hash}
    end
  end

  describe "default_country" do
    test "turns a local phone into E.164 before hashing" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "010 0123 4567"], default_country: "EG")

      assert sent_event()["user_data"]["phone_hash"] ==
               "9476e557c9e413deae474978709659f5b4f1c6a18553eddff8f042702843d0c7"
    end

    test "leaves a + number's own code alone" do
      respond(200, Stub.accepted("x"))
      track(user: [phone: "+966 50 123 4567"], default_country: "EG")
      assert sent_event()["user_data"]["phone_hash"] == Adinize.Hash.phone("+966501234567")
    end

    test "an unknown country is INVALID_OPTION and nothing is sent" do
      respond(200, Stub.accepted("x"))

      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
               track(user: [phone: "0501234567"], default_country: "ZZ")

      refute_received {:request, _, _}
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

    test "a 200 whose JSON body does not parse is INVALID_RESPONSE" do
      respond(200, {:json_text, "{not json"})
      assert {:error, %Adinize.Error{status: 200, code: "INVALID_RESPONSE"}} = track()
    end

    test "a 500 whose JSON body does not parse is HTTP_ERROR with its status" do
      respond(500, {:json_text, "{not json"})
      assert {:error, %Adinize.Error{status: 500, code: "HTTP_ERROR"}} = track()
    end

    test "a negative Retry-After is dropped" do
      respond(429, error_body("RATE_LIMITED"), [{"retry-after", "-5"}])
      assert {:error, %Adinize.Error{status: 429, retry_after: nil}} = track()
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
          {"digits hash with the plus form of a phone",
           [user: [phone_digits_hash: "16505551212"]]},
          {"digits hash in uppercase", [user: [phone_digits_hash: String.duplicate("B", 64)]]},
          {"phone with phone_hash",
           [user: [phone: "+16505551212", phone_hash: String.duplicate("a", 64)]]},
          {"phone with phone_digits_hash",
           [user: [phone: "+16505551212", phone_digits_hash: String.duplicate("a", 64)]]},
          {"consent not a keyword list", [user: [consent: [1]]]},
          {"consent with an unknown key", [user: [consent: [ads: true]]]},
          {"consent with a tuple key", [user: [consent: %{{:a} => true}]]},
          {"user not a list", [user: "jane"]},
          {"empty event_id", [event_id: ""]},
          {"event_time as text", [event_time: "yesterday"]},
          {"page_url not a string", [page_url: URI.parse("https://s/")]},
          {"platform_event_names not a list", [platform_event_names: "Contact"]},
          {"platform_event_names for an unknown platform",
           [platform_event_names: [google_ads: "submit_lead_form"]]},
          {"platform_event_names with a tuple key", [platform_event_names: %{{:tiktok} => "X"}]},
          {"platform_event_names with an empty name", [platform_event_names: [tiktok: ""]]},
          {"platform_event_names with an atom name", [platform_event_names: [meta: :Contact]]},
          {"platform_event_names with invalid UTF-8", [platform_event_names: [meta: <<255>>]]},
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

    test "a bad phone_digits_hash names the field and the rule, never the value" do
      respond(200, Stub.accepted("o1"))

      assert {:error, %Adinize.Error{code: "INVALID_OPTION", message: message}} =
               track(user: [phone_digits_hash: "16505551212"])

      assert message =~ "phone_digits_hash"
      assert message =~ "64 lowercase hex characters"
      refute message =~ "16505551212"
    end

    for key <- [:email, "phone", "Email"] do
      test "INVALID_OPTION naming the key, nothing sent: data holds #{inspect(key)}" do
        respond(200, Stub.accepted("o1"))

        assert {:error, %Adinize.Error{code: "INVALID_OPTION", message: message}} =
                 track(data: %{unquote(key) => "jane@example.com", "value" => 1})

        assert message =~ to_string(unquote(key))
        refute message =~ "jane"
        refute_received {:request, _, _}
      end
    end

    for {label, data, path} <- [
          {"a nested email", [customer: %{email: "jane@example.com"}], "data.customer.email"},
          {"a key containing email", [customer_email: "jane@example.com"], "data.customer_email"},
          {"a key containing phone", %{"Phone Number" => "0100"}, "data.Phone Number"},
          {"first_name", [first_name: "Jane"], "data.first_name"},
          {"last_name at depth 2", [a: [b: %{"last_name" => "Doe"}]], "data.a.b.last_name"},
          {"street_address in a list", [items: [%{sku: "1"}, %{street_address: "1 Nile St"}]],
           "data.items[1].street_address"},
          {"a key with a leading space", %{" email" => "jane@example.com"}, "data. email"}
        ] do
      test "INVALID_OPTION naming the key path, nothing sent: #{label}" do
        respond(200, Stub.accepted("o1"))

        assert {:error, %Adinize.Error{code: "INVALID_OPTION", message: message}} =
                 track(data: unquote(Macro.escape(data)))

        assert message =~ unquote(path)
        refute message =~ "jane"
        refute message =~ "Nile"
        refute_received {:request, _, _}
      end
    end

    test "a struct inside data does not raise" do
      respond(200, Stub.accepted("o1"))
      assert {:ok, _} = track(data: [placed_at: ~U[2026-09-29 10:00:00Z], value: 1])
    end

    test "an improper list inside data is INVALID_OPTION" do
      respond(200, Stub.accepted("o1"))

      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
               track(data: [items: [%{sku: "1"} | :tail]])

      refute_received {:request, _, _}
    end

    test "data keys that only look close still go out" do
      respond(200, Stub.accepted("o1"))

      assert {:ok, _} =
               track(data: [value: 1, contents: [%{id: "a", quantity: 2}], shipping_name: "x"])
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

    test "an exception carrying the auth header never reaches the error" do
      respond(200, {:raise, RuntimeError.exception("bad header: Bearer " <> @key)})
      {:error, error} = track()
      assert error.code == "TRANSPORT_ERROR"
      refute inspect(error, limit: :infinity) =~ @key
      refute Exception.message(error) =~ @key
    end

    test "an exit inside the HTTP client is TRANSPORT_ERROR" do
      respond(200, {:exit, {:shutdown, "Bearer " <> @key}})
      {:error, error} = track()
      assert error.code == "TRANSPORT_ERROR"
      refute inspect(error, limit: :infinity) =~ @key
    end

    test "the error never holds the secret key" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      {:error, error} = track()
      refute inspect(error, limit: :infinity) =~ @key
      refute Exception.message(error) =~ @key
    end
  end
end
