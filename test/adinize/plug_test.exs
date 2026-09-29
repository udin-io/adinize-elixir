defmodule Adinize.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Adinize.Test.Stub

  defp shopper_conn(url) do
    conn(:post, url)
    |> put_req_cookie("_mb_vid", "mb.1790499000000.k3j9x2a1b")
    |> put_req_cookie("_fbp", "fb.1.1790.1")
    |> put_req_cookie("_fbc", "fb.1.1790.abc")
    |> put_req_cookie("ttp", "ttp-value")
    |> Plug.Conn.put_req_header("user-agent", "Mozilla/5.0")
    |> Map.put(:remote_ip, {203, 0, 113, 7})
  end

  test "reads the visitor and Meta cookies, IP, User-Agent and page URL; not ttp" do
    assert Adinize.Plug.context(shopper_conn("https://shop.example.com/checkout")) == [
             visitor_id: "mb.1790499000000.k3j9x2a1b",
             page_url: "https://shop.example.com/checkout",
             user: [
               fbp: "fb.1.1790.1",
               fbc: "fb.1.1790.abc",
               client_ip_address: "203.0.113.7",
               client_user_agent: "Mozilla/5.0"
             ]
           ]
  end

  test "drops the query string from page_url by default" do
    ctx =
      Adinize.Plug.context(shopper_conn("https://shop.example.com/done?email=jane@example.com"))

    assert ctx[:page_url] == "https://shop.example.com/done"
  end

  test "keeps the query string when asked" do
    ctx =
      shopper_conn("https://shop.example.com/done?utm_source=meta")
      |> Adinize.Plug.context(query_string: true)

    assert ctx[:page_url] == "https://shop.example.com/done?utm_source=meta"
  end

  test "an IPv6 client address" do
    ctx =
      conn(:get, "https://shop.example.com/")
      |> Map.put(:remote_ip, {8193, 3512, 0, 0, 0, 0, 0, 1})

    assert Adinize.Plug.context(ctx)[:user][:client_ip_address] == "2001:db8::1"
  end

  test "a conn with no cookies leaves the cookie fields out" do
    ctx = Adinize.Plug.context(conn(:get, "https://shop.example.com/"))
    assert ctx[:page_url] == "https://shop.example.com/"
    refute Keyword.has_key?(ctx, :visitor_id)
    refute Keyword.has_key?(ctx[:user], :fbp)
  end

  test "the context feeds track/2 as is" do
    Stub.respond(__MODULE__, 200, Stub.accepted("o"))
    ctx = Adinize.Plug.context(shopper_conn("https://shop.example.com/checkout"))

    assert {:ok, %Adinize.Result{status: :accepted}} =
             Adinize.track("Purchase", ctx ++ [event_id: "o"] ++ Stub.opts(__MODULE__))

    assert_received {:request, _conn, raw}
    %{"events" => [event]} = Jason.decode!(raw)
    assert event["visitor_id"] == "mb.1790499000000.k3j9x2a1b"
    assert event["user_data"]["fbp"] == "fb.1.1790.1"
    refute raw =~ "ttp-value"
  end
end
