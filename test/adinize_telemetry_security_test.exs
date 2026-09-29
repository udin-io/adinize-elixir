defmodule Adinize.TelemetrySecurityTest do
  use ExUnit.Case, async: true

  # No secret key and no raw PII (an email, a phone, a name) appear in any
  # telemetry measurement or metadata — across every event this ticket
  # adds: the request span and a rejected event.
  test "no secret key and no raw PII in any [:adinize, ...] telemetry payload" do
    secret = "adzsk_topsecret_#{System.unique_integer([:positive])}"
    email = "jane.doe@example.com"
    phone = "+201001234567"
    name = :"telemetry_sec_#{__ENV__.line}"

    handler_id = "telemetry-security-#{__ENV__.line}"
    test = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:adinize, :request, :start],
        [:adinize, :request, :stop],
        [:adinize, :request, :exception],
        [:adinize, :event, :rejected],
        [:adinize, :event, :dropped]
      ],
      fn event, measurements, metadata, _config ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # A request whose only per-event response is a rejection, so both the
    # request span and the :rejected event fire.
    Req.Test.stub(name, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)

      Req.Test.json(conn, %{
        "results" => [
          %{
            "event_id" => "e1",
            "status" => "rejected",
            "errors" => [
              %{"field" => "user.email", "code" => "INVALID", "message" => "bad email"}
            ]
          }
        ]
      })
    end)

    assert {:ok, %Adinize.Result{status: :rejected}} =
             Adinize.track("Purchase",
               event_id: "e1",
               user: [email: email, phone: phone, first_name: "Jane"],
               secret_key: secret,
               req_options: [plug: {Req.Test, name}]
             )

    payloads = drain_telemetry()
    assert payloads != []

    Enum.each(payloads, fn {_event, measurements, metadata} ->
      dump = inspect({measurements, metadata})
      refute dump =~ secret, "telemetry payload leaked the secret key: #{dump}"
      refute dump =~ email, "telemetry payload leaked the raw email: #{dump}"
      refute dump =~ phone, "telemetry payload leaked the raw phone: #{dump}"
      refute dump =~ "Jane", "telemetry payload leaked the raw name: #{dump}"
    end)
  end

  defp drain_telemetry(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      500 -> acc
    end
  end
end
