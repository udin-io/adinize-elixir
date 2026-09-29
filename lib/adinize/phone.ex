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

  For EG, SA, AE, GB and JO, whose numbers start with a trunk `0` at home:
  a `0` written after the country code is dropped, and digits that already
  start with the country code count as international. Arabic-Indic and
  Persian digits become ASCII first.

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
    if String.valid?(value), do: normalise(value, default_country)
  end

  def e164(_value, _default_country), do: nil

  defp normalise(value, default_country) do
    # A fullwidth plus counts as +; an extension is not part of the number;
    # "(0)" after a country code is a written trunk hint, not a digit.
    number =
      value
      |> ascii_digits()
      |> String.replace("＋", "+")
      |> String.split(~r/(?:ext\.?|x|#|;)/iu, parts: 2)
      |> hd()
      |> String.replace(~r/\(\s*0\s*\)/u, "")

    digits = String.replace(number, ~r/[^0-9]/, "")

    cond do
      number =~ ~r/\A[^0-9]*\+/u ->
        international(digits)

      String.starts_with?(digits, "00") ->
        international(binary_part(digits, 2, byte_size(digits) - 2))

      true ->
        local(digits, default_country)
    end
  end

  # Arabic-Indic (U+0660..0669) and Persian (U+06F0..06F9) digits.
  defp ascii_digits(value) do
    for <<char::utf8 <- value>>, into: "" do
      cond do
        char in 0x0660..0x0669 -> <<char - 0x0660 + ?0>>
        char in 0x06F0..0x06F9 -> <<char - 0x06F0 + ?0>>
        true -> <<char::utf8>>
      end
    end
  end

  # A trunk 0 written after the country code ("+20 0100...") is dropped for
  # the countries that dial one at home. Other codes keep their 0: Italian
  # numbers start with it.
  @trunk_zero_codes for {_country, {code, "0"}} <- @countries, do: code

  defp international(digits) do
    case Enum.find(@trunk_zero_codes, &String.starts_with?(digits, &1 <> "0")) do
      nil ->
        valid("+" <> digits)

      code ->
        valid(
          "+" <>
            code <>
            binary_part(digits, byte_size(code) + 1, byte_size(digits) - byte_size(code) - 1)
        )
    end
  end

  defp local(digits, country) when is_binary(country) and digits != "" do
    case Map.fetch(@countries, String.upcase(country)) do
      # Digits that already start with a trunk-0 country's own code were
      # written without the +: a local number there starts with 0.
      {:ok, {code, "0"}} ->
        if String.starts_with?(digits, code),
          do: international(digits),
          else: valid("+" <> code <> drop_trunk(digits, "0"))

      {:ok, {code, trunk}} ->
        valid("+" <> code <> drop_trunk(digits, trunk))

      :error ->
        nil
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
