defmodule Adinize.Hash do
  @moduledoc """
  Normalises and SHA-256 hashes the personal fields the server events API
  takes only as hashes. Each function returns 64 lowercase hex characters, or
  `nil` when nothing is left after normalising.

      iex> Adinize.Hash.email(" Jane@Example.com ")
      "8c87b489ce35cf2e2f39f80e282cb2e804932a56a213983eeeb428407d43b52d"

  Text is trimmed and lowercased, following Meta's customer information
  parameters. Phones go through `Adinize.Phone` first; see `phone/2`.
  """

  @spec email(String.t() | nil) :: String.t() | nil
  def email(value), do: value |> text() |> sha256()

  @doc "Hashes the E.164 form of `value`; `nil` when it has none. See `Adinize.Phone`."
  @spec phone(String.t() | nil, String.t() | nil) :: String.t() | nil
  def phone(value, default_country \\ nil),
    do: value |> Adinize.Phone.e164(default_country) |> sha256()

  @spec name(String.t() | nil) :: String.t() | nil
  def name(value), do: value |> text() |> sha256()

  @spec street_address(String.t() | nil) :: String.t() | nil
  def street_address(value), do: value |> text() |> sha256()

  @doc false
  def sha256(nil), do: nil
  def sha256(""), do: nil
  def sha256(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp text(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp text(_value), do: nil
end
