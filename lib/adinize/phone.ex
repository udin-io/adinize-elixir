defmodule Adinize.Phone do
  # ISO 3166 alpha-2 => {calling code, trunk prefix}
  @countries %{
    "AE" => {"971", "0"},
    "BH" => {"973", nil},
    "EG" => {"20", "0"},
    "GB" => {"44", "0"},
    "JO" => {"962", "0"},
    "KW" => {"965", nil},
    "OM" => {"968", nil},
    "QA" => {"974", nil},
    "SA" => {"966", "0"},
    "US" => {"1", "1"}
  }

  @moduledoc """
  Turns a phone number into E.164 (`+` and 7 to 15 digits), the form TikTok
  and Google hash, and the browser pixel hashes.

      iex> Adinize.Phone.e164("010-0123-4567", "EG")
      "+201001234567"
      iex> Adinize.Phone.e164("+44 7700 900123", "EG")
      "+447700900123"
      iex> Adinize.Phone.e164("0501234567", nil)
      nil

  A number that starts with `+` or `00` keeps its own country code. A local
  number drops its trunk prefix and gains the default country's code; with
  no default country it has no E.164 form. There is no US fallback.

  Default countries: #{@countries |> Map.keys() |> Enum.sort() |> Enum.join(", ")}.
  A number with a `+` works for any country.
  """

  @doc false
  def countries, do: @countries |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  @doc "The calling code for an ISO 3166 alpha-2 country, if the SDK knows it."
  @spec country_code(String.t()) :: {:ok, String.t()} | :error
  def country_code(country) when is_binary(country) do
    case Map.fetch(@countries, String.upcase(country)) do
      {:ok, {code, _trunk}} -> {:ok, code}
      :error -> :error
    end
  end

  def country_code(_country), do: :error

  @doc "The E.164 form, or `nil` when the number has none."
  @spec e164(String.t() | nil, String.t() | nil) :: String.t() | nil
  def e164(value, default_country) when is_binary(value) do
    trimmed = String.trim(value)
    digits = String.replace(trimmed, ~r/[^0-9]/, "")

    cond do
      String.starts_with?(trimmed, "+") ->
        valid("+" <> digits)

      String.starts_with?(digits, "00") ->
        valid("+" <> binary_part(digits, 2, byte_size(digits) - 2))

      true ->
        local(digits, default_country)
    end
  end

  def e164(_value, _default_country), do: nil

  defp local(digits, country) when is_binary(country) and digits != "" do
    case Map.fetch(@countries, String.upcase(country)) do
      {:ok, {code, trunk}} -> valid("+" <> code <> drop_trunk(digits, trunk))
      :error -> nil
    end
  end

  defp local(_digits, _country), do: nil

  defp drop_trunk(digits, nil), do: digits

  defp drop_trunk(digits, trunk) do
    if String.starts_with?(digits, trunk),
      do: binary_part(digits, byte_size(trunk), byte_size(digits) - byte_size(trunk)),
      else: digits
  end

  defp valid("+" <> digits = number) do
    if byte_size(digits) in 7..15 and not String.starts_with?(digits, "0"), do: number
  end
end
