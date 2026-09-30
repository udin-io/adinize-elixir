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
      assert Hash.phone_digits(row["input"], row["default_country"]) == row["digits_sha256"]
    end
  end

  test "digits_sha256 is the SHA-256 of the E.164 number without its +, null where there is none" do
    for row <- @vectors do
      expected =
        case row["e164"] do
          nil ->
            nil

          e164 ->
            :sha256 |> :crypto.hash(String.trim_leading(e164, "+")) |> Base.encode16(case: :lower)
        end

      assert row["digits_sha256"] == expected, "row #{inspect(row["input"])}"
    end
  end

  # Meta, Customer Information Parameters: 16505551212 hashes to this.
  test "the US row equals Meta's documented phone hash" do
    row =
      Enum.find(@vectors, &(&1["input"] == "(650) 555-1212" and &1["default_country"] == "US"))

    assert row["digits_sha256"] ==
             "e323ec626319ca94ee8bff2e4c87cf613be6ea19919ed1364124e16807ab3176"
  end

  test "invalid UTF-8 has no E.164 form and does not raise" do
    assert Phone.e164(<<255, ?1, ?2>>, "EG") == nil
  end

  test "an unknown default country is an error, never a guess" do
    assert Phone.country_code("ZZ") == :error
    assert Phone.country_code("eg") == {:ok, "20"}
  end
end
