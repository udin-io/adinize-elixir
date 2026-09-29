defmodule Adinize.Test.Stub do
  @moduledoc false
  # A Req.Test stub of the server events API that sends each request's
  # conn and raw body back to the test process.

  def opts(name), do: [secret_key: key(), req_options: [plug: {Req.Test, name}]]

  def key, do: "adzsk_test_not_a_real_key"

  def respond(name, status, body, headers \\ []) do
    test = self()

    Req.Test.stub(name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, raw})

      conn =
        Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
        |> Plug.Conn.put_status(status)

      case body do
        {:text, text} -> Req.Test.text(conn, text)
        json -> Req.Test.json(conn, json)
      end
    end)
  end

  def accepted(id), do: %{"results" => [%{"event_id" => id, "status" => "accepted"}]}
end
