defmodule Adinize.EventPageUrlTest do
  use ExUnit.Case, async: true

  alias Adinize.Event

  # Shared with adinize-js: each row gives a page_url, whether the caller
  # passed query_string: true, and the page_url that goes to adinize.
  @vectors "../fixtures/page_url_vectors.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> Jason.decode!()

  for row <- @vectors do
    test "#{row["note"]}: #{inspect(row["input"])}" do
      row = unquote(Macro.escape(row))
      opts = [page_url: row["input"], query_string: row["query_string"]]

      assert {:ok, %{"page_url" => sent}} = Event.build("Lead", opts, nil)
      assert sent == row["expected"]
    end
  end

  test "no vector leaves a user name or password in the URL" do
    assert length(@vectors) >= 10

    for row <- @vectors do
      opts = [page_url: row["input"], query_string: row["query_string"]]
      {:ok, %{"page_url" => sent}} = Event.build("Lead", opts, nil)
      parsed = URI.parse(sent)
      assert parsed.userinfo == nil, row["input"]
    end
  end

  test "a page_url of nil stays nil" do
    assert {:ok, %{} = event} = Event.build("Lead", [], nil)
    refute Map.has_key?(event, "page_url")
  end
end
