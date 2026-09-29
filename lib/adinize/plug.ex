if Code.ensure_loaded?(Plug.Conn) do
  defmodule Adinize.Plug do
    @moduledoc """
    Reads the shopper's context from a `Plug.Conn`, ready to append to the
    options of `Adinize.track/2`:

        Adinize.track("Purchase", Adinize.Plug.context(conn) ++ [event_id: order.id])

    It reads the `_mb_vid` visitor cookie, Meta's `_fbp` and `_fbc`
    cookies, the client IP and the User-Agent. TikTok's `ttp` cookie is
    left out: the server events API does not accept it yet.

    `page_url` leaves out the query string, which can hold an email or a
    token; pass `query_string: true` to keep it.

    The IP is `conn.remote_ip`. Behind a proxy that is the proxy's address
    unless your endpoint rewrites it first, for example with `RemoteIp`.
    Needs the optional `:plug` dependency.
    """

    import Plug.Conn

    @spec context(Plug.Conn.t(), keyword()) :: keyword()
    def context(%Plug.Conn{} = conn, opts \\ []) when is_list(opts) do
      conn = fetch_cookies(conn)
      cookies = conn.cookies

      user =
        present(
          fbp: cookies["_fbp"],
          fbc: cookies["_fbc"],
          client_ip_address: conn.remote_ip && conn.remote_ip |> :inet.ntoa() |> to_string(),
          client_user_agent: conn |> get_req_header("user-agent") |> List.first()
        )

      present(
        visitor_id: cookies["_mb_vid"],
        page_url: page_url(conn, Keyword.get(opts, :query_string) == true),
        user: user
      )
    end

    defp page_url(conn, true), do: request_url(conn)
    defp page_url(conn, false), do: request_url(%{conn | query_string: ""})

    defp present(keyword), do: Enum.reject(keyword, fn {_k, v} -> v in [nil, "", []] end)
  end
end
