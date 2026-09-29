defmodule Adinize.PhoneTest do
  use ExUnit.Case, async: true
  doctest Adinize.Phone

  alias Adinize.{Hash, Phone}

  # Shared with the browser pixel's tests (media_buyer issue 653): each row
  # gives an input, the default country, the E.164 result (null when the
  # number is not hashed) and its SHA-256.
  @vectors "../fixtures/phone_vectors.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> Jason.decode!()

  for row <- @vectors do
    test "#{row["note"]}: #{inspect(row["input"])} with #{inspect(row["default_country"])}" do
      row = unquote(Macro.escape(row))
      assert Phone.e164(row["input"], row["default_country"]) == row["e164"]
      assert Hash.phone(row["input"], row["default_country"]) == row["sha256"]
    end
  end

  test "invalid UTF-8 has no E.164 form and does not raise" do
    assert Phone.e164(<<255, ?1, ?2>>, "EG") == nil
  end

  test "an unknown default country is an error, never a guess" do
    assert Phone.country_code("ZZ") == :error
    assert Phone.country_code("eg") == {:ok, "20"}
  end
end
