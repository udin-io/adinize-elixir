defmodule Adinize.Event do
  @moduledoc false
  # Builds one event map for the request body. Personal fields leave this
  # module only as hashes.

  alias Adinize.Hash

  @hashed %{
    email: "email_hash",
    phone: "phone_hash",
    first_name: "first_name_hash",
    last_name: "last_name_hash",
    street_address: "street_address_hash"
  }

  @spec build(String.t(), keyword(), String.t() | nil) :: {:ok, map()}
  def build(name, opts, default_country) do
    {:ok,
     %{
       "event_id" => Keyword.get_lazy(opts, :event_id, &uuid4/0),
       "event_name" => name,
       "event_time" => event_time(Keyword.get(opts, :event_time)),
       "visitor_id" => Keyword.get(opts, :visitor_id),
       "page_url" => Keyword.get(opts, :page_url),
       "user_data" => user_data(Keyword.get(opts, :user, []), default_country),
       "event_data" => Map.new(Keyword.get(opts, :data, []), fn {k, v} -> {to_string(k), v} end)
     }
     |> Map.reject(fn {_k, v} -> v == nil or v == %{} end)}
  end

  defp event_time(nil), do: System.os_time(:second)
  defp event_time(%DateTime{} = time), do: DateTime.to_unix(time)
  defp event_time(seconds) when is_integer(seconds), do: seconds

  defp user_data(user, default_country) do
    for {key, value} <- user,
        (field = user_field(key, value, default_country)) != nil,
        into: %{},
        do: field
  end

  defp user_field(key, value, default_country) when is_map_key(@hashed, key) do
    case hash(key, value, default_country) do
      nil -> nil
      hash -> {Map.fetch!(@hashed, key), hash}
    end
  end

  defp user_field(:consent, value, _default_country),
    do: {"consent", Map.new(value, fn {k, v} -> {to_string(k), v} end)}

  defp user_field(key, value, _default_country), do: {Atom.to_string(key), value}

  defp hash(:email, value, _country), do: Hash.email(value)
  defp hash(:phone, value, country), do: Hash.phone(value, country)
  defp hash(:street_address, value, _country), do: Hash.street_address(value)
  defp hash(_name, value, _country), do: Hash.name(value)

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
