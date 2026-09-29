defmodule Adinize.Event do
  @moduledoc false
  # Builds one event map for the request body. Personal fields leave this
  # module only as hashes. An unknown `user` key is an error, not a
  # pass-through, so a misspelt `phone_number:` never goes out in plain text.
  # Error messages name the field, never its value: the value may be an
  # email or a phone.

  alias Adinize.{Error, Hash}

  @event_keys [:event_id, :event_time, :visitor_id, :page_url, :user, :data]

  @hashed %{
    email: "email_hash",
    phone: "phone_hash",
    first_name: "first_name_hash",
    last_name: "last_name_hash",
    street_address: "street_address_hash"
  }

  @prehashed ~w(email_hash phone_hash first_name_hash last_name_hash street_address_hash)a

  @plain ~w(external_id client_ip_address client_user_agent fbp fbc gclid ttclid city state postal_code country_code)a

  @user_keys Map.keys(@hashed) ++ @prehashed ++ @plain ++ [:consent]

  @spec build(term(), term(), String.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def build(name, opts, default_country) when is_binary(name) and name != "" do
    with :ok <- known_keys(opts, @event_keys, "event option"),
         {:ok, event_id} <- event_id(Keyword.get(opts, :event_id)),
         {:ok, event_time} <- event_time(Keyword.get(opts, :event_time)),
         {:ok, visitor_id} <- optional_string(opts, :visitor_id),
         {:ok, page_url} <- optional_string(opts, :page_url),
         {:ok, user_data} <- user_data(Keyword.get(opts, :user, []), default_country),
         {:ok, event_data} <- event_data(Keyword.get(opts, :data, [])) do
      {:ok,
       %{
         "event_id" => event_id,
         "event_name" => name,
         "event_time" => event_time,
         "visitor_id" => visitor_id,
         "page_url" => page_url,
         "user_data" => user_data,
         "event_data" => event_data
       }
       |> Map.reject(fn {_k, v} -> v == nil or v == %{} end)}
    end
  end

  def build(_name, _opts, _default_country),
    do: invalid("event name must be a non-empty string")

  defp event_id(nil), do: {:ok, uuid4()}
  defp event_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp event_id(_id), do: invalid("event_id must be a non-empty string")

  defp event_time(nil), do: {:ok, System.os_time(:second)}
  defp event_time(%DateTime{} = time), do: {:ok, DateTime.to_unix(time)}
  defp event_time(seconds) when is_integer(seconds), do: {:ok, seconds}
  defp event_time(_other), do: invalid("event_time must be a DateTime or Unix seconds")

  defp optional_string(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> invalid("#{key} must be a string")
    end
  end

  defp user_data(user, default_country) when is_list(user) or is_map(user) do
    user = Enum.to_list(user)

    with :ok <- known_keys(user, @user_keys, "user field") do
      Enum.reduce_while(user, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        put_user_field(acc, user_field(key, value, default_country))
      end)
    end
  end

  defp user_data(_user, _default_country), do: invalid("user must be a keyword list or map")

  defp put_user_field(acc, {:ok, nil}), do: {:cont, {:ok, acc}}
  defp put_user_field(acc, {:ok, {name, value}}), do: {:cont, {:ok, Map.put(acc, name, value)}}
  defp put_user_field(_acc, {:error, _} = error), do: {:halt, error}

  defp user_field(_key, nil, _default_country), do: {:ok, nil}

  defp user_field(key, value, default_country) when is_map_key(@hashed, key) do
    if is_binary(value) and String.valid?(value) do
      case hash(key, value, default_country) do
        nil -> {:ok, nil}
        hash -> {:ok, {Map.fetch!(@hashed, key), hash}}
      end
    else
      invalid("user #{key} must be a UTF-8 string")
    end
  end

  defp user_field(key, value, _default_country) when key in @prehashed do
    if is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/,
      do: {:ok, {Atom.to_string(key), value}},
      else: invalid("user #{key} must be 64 lowercase hex characters")
  end

  defp user_field(key, value, _default_country) when key in @plain and is_binary(value),
    do: {:ok, {Atom.to_string(key), value}}

  defp user_field(:consent, value, _default_country) when is_list(value) or is_map(value) do
    if (is_map(value) or Keyword.keyword?(value)) and
         Enum.all?(value, fn {k, v} ->
           to_string(k) in ~w(analytics marketing functional) and is_boolean(v)
         end),
       do: {:ok, {"consent", Map.new(value, fn {k, v} -> {to_string(k), v} end)}},
       else: invalid("user consent takes analytics, marketing and functional booleans")
  end

  defp user_field(key, _value, _default_country), do: invalid("user #{key} has the wrong type")

  defp hash(:email, value, _country), do: Hash.email(value)
  defp hash(:phone, value, country), do: Hash.phone(value, country)
  defp hash(:street_address, value, _country), do: Hash.street_address(value)
  defp hash(_name, value, _country), do: Hash.name(value)

  defp event_data(data) when is_list(data) or is_map(data) do
    if (is_map(data) or Keyword.keyword?(data)) and
         Enum.all?(data, fn {k, _v} -> is_atom(k) or is_binary(k) end) do
      data = Map.new(data, fn {k, v} -> {to_string(k), v} end)

      # event_data is sent as given, so personal data here would leave in
      # plain text. Send it under `user:`, which hashes it.
      case Enum.find(Map.keys(data), &(String.downcase(&1) in ["email", "phone"])) do
        nil -> {:ok, data}
        key -> invalid("data must not hold #{key}; pass it under user: so it is hashed")
      end
    else
      invalid("data must be a keyword list or a map with string keys")
    end
  end

  defp event_data(_data), do: invalid("data must be a keyword list or map")

  defp known_keys(list, allowed, what) do
    if is_list(list) and Keyword.keyword?(list) do
      case Enum.reject(Keyword.keys(list), &(&1 in allowed)) do
        [] -> :ok
        unknown -> invalid("unknown #{what}: #{inspect(unknown)}")
      end
    else
      invalid("#{what}s must be a keyword list")
    end
  end

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp invalid(message), do: {:error, %Error{code: "INVALID_OPTION", message: message}}
end
