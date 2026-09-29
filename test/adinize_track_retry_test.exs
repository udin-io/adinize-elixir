defmodule Adinize.TrackRetryTest do
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  defp opts(extra), do: Keyword.merge(Stub.opts(__MODULE__), extra)

  test "track/2 without retry: true does not retry a 500" do
    test = self()
    attempt = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(attempt, 1, 1)
      send(test, :hit)
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"code" => "X"}})
    end)

    assert {:error, %Adinize.Error{status: 500}} =
             Adinize.track("Lead", opts(event_id: "once"))

    assert_receive :hit
    refute_receive :hit, 200
  end

  test "track/2 with retry: true retries a 500 up to 5 attempts with the same event_id" do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:attempt, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"code" => "X"}})
    end)

    assert {:error, %Adinize.Error{status: 500}} =
             Adinize.track("Lead", opts(event_id: "same-id", retry: true))

    for _ <- 1..5 do
      assert_receive {:attempt, %{"events" => [%{"event_id" => "same-id"}]}}, 2_000
    end

    refute_receive {:attempt, _}, 500
  end

  test "track/2 with retry: true does not retry a 401" do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test, :hit)
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"code" => "INVALID_KEY"}})
    end)

    assert {:error, %Adinize.Error{status: 401, code: "INVALID_KEY"}} =
             Adinize.track("Lead", opts(event_id: "x", retry: true))

    assert_receive :hit
    refute_receive :hit, 200
  end

  test "track/2 with retry: true succeeds after a 429 with Retry-After" do
    test = self()
    attempt = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      n = :counters.get(attempt, 1)
      :counters.add(attempt, 1, 1)
      send(test, {:attempt, n})

      if n == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => "RATE_LIMITED"}})
      else
        Req.Test.json(conn, Stub.accepted("r1"))
      end
    end)

    assert {:ok, %Adinize.Result{event_id: "r1", status: :accepted}} =
             Adinize.track("Lead", opts(event_id: "r1", retry: true))

    assert_receive {:attempt, 0}
    assert_receive {:attempt, 1}
    refute_receive {:attempt, 2}, 200
  end
end
