defmodule Adinize.TrackManyTest do
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  defp opts(extra \\ []), do: Keyword.merge(Stub.opts(__MODULE__), extra)

  test "sends every event in one request and returns results in input order" do
    Stub.respond(__MODULE__, 200, %{
      "results" => [
        %{"event_id" => "a", "status" => "accepted"},
        %{"event_id" => "b", "status" => "duplicate"}
      ]
    })

    assert {:ok, [%Adinize.Result{event_id: "a", status: :accepted}, %{status: :duplicate}]} =
             Adinize.track_many(
               [
                 {"Lead", [event_id: "a", user: [phone: "0501234567"]]},
                 {"Purchase", [event_id: "b"]}
               ],
               opts(default_country: "SA")
             )

    assert_received {:request, _conn, raw}
    assert %{"events" => [first, second]} = Jason.decode!(raw)
    assert first["event_name"] == "Lead"
    assert first["user_data"]["phone_hash"] == Adinize.Hash.phone("+966501234567")
    assert second["event_id"] == "b"
    refute_received {:request, _, _}
  end

  test "100 events go out; 101 are TOO_MANY_EVENTS and nothing is sent" do
    results = for i <- 1..100, do: %{"event_id" => "e#{i}", "status" => "accepted"}
    Stub.respond(__MODULE__, 200, %{"results" => results})

    events = for i <- 1..100, do: {"Lead", [event_id: "e#{i}"]}
    assert {:ok, list} = Adinize.track_many(events, opts())
    assert length(list) == 100
    assert_received {:request, _, _}

    assert {:error, %Adinize.Error{code: "TOO_MANY_EVENTS"}} =
             Adinize.track_many(events ++ [{"Lead", []}], opts())

    refute_received {:request, _, _}
  end

  test "a result count that differs from the events sent is INVALID_RESPONSE" do
    Stub.respond(__MODULE__, 200, Stub.accepted("a"))

    assert {:error, %Adinize.Error{status: 200, code: "INVALID_RESPONSE"}} =
             Adinize.track_many([{"Lead", []}, {"Lead", []}], opts())
  end

  for {label, events, extra} <- [
        {"an empty list", [], []},
        {"an improper list", [{"Lead", []} | :x], []},
        {"not a list", :events, []},
        {"an entry that is not {name, opts}", ["Lead"], []},
        {"one malformed event among good ones", [{"Lead", []}, {"Lead", [evnt_id: 1]}], []},
        {"options that are not a keyword list", [{"Lead", []}], [:a]},
        {"an event-level option given for the batch", [{"Lead", []}], [event_id: "x"]}
      ] do
    test "INVALID_OPTION, nothing sent: #{label}" do
      Stub.respond(__MODULE__, 200, Stub.accepted("a"))
      extra = unquote(Macro.escape(extra))
      batch_opts = if Keyword.keyword?(extra), do: opts(extra), else: extra

      assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
               Adinize.track_many(unquote(Macro.escape(events)), batch_opts)

      refute_received {:request, _, _}
    end
  end
end
