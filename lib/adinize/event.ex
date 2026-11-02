defmodule Adinize.Event do
  @moduledoc false
  # Builds one event map for the request body. Personal fields leave this
  # module only as hashes. An unknown `user` key is an error, not a
  # pass-through, so a misspelt `phone_number:` never goes out in plain text.
  # Error messages name the field, never its value: the value may be an
  # email or a phone.

  alias Adinize.{Error, Hash}

  @event_keys [
    :event_id,
    :event_time,
    :visitor_id,
    :page_url,
    :query_string,
    :user,
    :app,
    :data,
    :platform_event_names
  ]

  @hashed %{
    email: "email_hash",
    first_name: "first_name_hash",
    last_name: "last_name_hash",
    street_address: "street_address_hash"
  }

  @prehashed ~w(email_hash phone_hash phone_digits_hash first_name_hash last_name_hash street_address_hash)a

  @prehashed_phones ~w(phone_hash phone_digits_hash)a

  @plain ~w(external_id client_ip_address client_user_agent fbp fbc ttp gclid ttclid city state postal_code country_code)a

  # Sent raw, and only on an app event: the server refuses them on any other.
  @device_ids ~w(madid idfv anon_id)a
  @click_ids ~w(gbraid wbraid)a

  @user_keys Map.keys(@hashed) ++
               [:phone] ++ @prehashed ++ @plain ++ @device_ids ++ @click_ids ++ [:consent]

  @app_required ~w(os os_version advertiser_tracking_enabled)a
  @app_strings ~w(os_version bundle_id app_version app_store_id device_model locale timezone carrier)a
  @app_booleans ~w(advertiser_tracking_enabled application_tracking_enabled)a
  @att_statuses ~w(AUTHORIZED DENIED NOT_DETERMINED RESTRICTED NOT_APPLICABLE)
  @app_keys [:os, :att_status] ++ @app_strings ++ @app_booleans

  @spec build(term(), term(), String.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def build(name, opts, default_country) when is_binary(name) and name != "" do
    with :ok <- known_keys(opts, @event_keys, "event option"),
         {:ok, event_id} <- event_id(Keyword.get(opts, :event_id)),
         {:ok, event_time} <- event_time(Keyword.get(opts, :event_time)),
         {:ok, visitor_id} <- optional_string(opts, :visitor_id),
         {:ok, page_url} <- optional_string(opts, :page_url),
         page_url = page_url(page_url, Keyword.get(opts, :query_string) == true),
         {:ok, app_data} <- app_data(Keyword.get(opts, :app)),
         {:ok, user_data} <-
           user_data(Keyword.get(opts, :user, []), default_country, app_data != nil),
         {:ok, event_data} <- event_data(Keyword.get(opts, :data, [])),
         {:ok, platform_names} <-
           platform_event_names(Keyword.get(opts, :platform_event_names, [])) do
      {:ok,
       %{
         "event_id" => event_id,
         "event_name" => name,
         "event_time" => event_time,
         "visitor_id" => visitor_id,
         "page_url" => page_url,
         "action_source" => if(app_data, do: "app"),
         "app_data" => app_data,
         "user_data" => user_data,
         "event_data" => event_data,
         "platform_event_names" => platform_names
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

  # Every form of user and password a WHATWG parser still reads as userinfo:
  # any number of slashes or backslashes after the scheme (`https:jane:pw@host`,
  # `https:\\jane@host`), or a bare `//`. Same pattern as adinize-js.
  @userinfo ~r/^(?:([a-z][a-z0-9+.-]*:)[\\\/]*|[\\\/]{2})[^\\\/?#]*@/i

  # The user and password never go: they hold a credential. The query string
  # and the fragment can hold an email or a token, so they go only when asked.
  # Leading control characters and spaces, tabs and newlines drop first, as a
  # browser drops them, so they cannot hide the userinfo from the pattern.
  defp page_url(nil, _keep_query?), do: nil

  defp page_url(url, keep_query?) do
    without_user =
      url
      |> String.replace(~r/^[\x00-\x20]+/, "")
      |> String.replace(~r/[\t\n\r]/, "")
      |> then(&Regex.replace(@userinfo, &1, fn _all, scheme -> scheme <> "//" end))

    if keep_query?, do: without_user, else: String.replace(without_user, ~r/[?#].*$/s, "")
  end

  defp user_data(user, default_country, app?)
       when is_list(user) or (is_map(user) and not is_struct(user)) do
    user = Enum.to_list(user)

    with :ok <- known_keys(user, @user_keys, "user field"),
         :ok <- one_phone_source(user),
         :ok <- device_ids_on_app_only(user, app?) do
      Enum.reduce_while(user, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        put_user_field(acc, user_field(key, value, default_country))
      end)
    end
  end

  defp user_data(_user, _default_country, _app?),
    do: invalid("user must be a keyword list or map")

  # The server refuses a device id on a web event; refuse it here, before
  # the request, and name the field.
  defp device_ids_on_app_only(user, app?) do
    case for({key, value} <- user, key in (@device_ids ++ @click_ids) and value != nil, do: key) do
      [key | _] when not app? -> invalid("user #{key} needs the app: option")
      _ -> :ok
    end
  end

  # A raw phone and a pre-hashed phone key could name two different numbers.
  defp one_phone_source(user) do
    present = for {key, value} <- user, value != nil, do: key

    if :phone in present and Enum.any?(present, &(&1 in @prehashed_phones)),
      do: invalid("user phone cannot be sent with phone_hash or phone_digits_hash; pass one"),
      else: :ok
  end

  defp put_user_field(acc, {:ok, nil}), do: {:cont, {:ok, acc}}

  defp put_user_field(acc, {:ok, pairs}) when is_list(pairs),
    do: {:cont, {:ok, Enum.into(pairs, acc)}}

  defp put_user_field(acc, {:ok, {name, value}}), do: {:cont, {:ok, Map.put(acc, name, value)}}
  defp put_user_field(_acc, {:error, _} = error), do: {:halt, error}

  defp user_field(_key, nil, _default_country), do: {:ok, nil}

  # Meta reads the hash of the digits, Google and TikTok the hash with the +.
  # Both come from one E.164 number, so a phone sends both or neither.
  defp user_field(:phone, value, default_country) do
    if is_binary(value) and String.valid?(value) do
      hashes = [
        {"phone_hash", Hash.phone(value, default_country)},
        {"phone_digits_hash", Hash.phone_digits(value, default_country)}
      ]

      {:ok, for({name, hash} <- hashes, hash != nil, do: {name, hash})}
    else
      invalid("user phone must be a UTF-8 string")
    end
  end

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

  defp user_field(key, value, _default_country) when key in @device_ids,
    do: id_field(key, value, 128)

  defp user_field(key, value, _default_country) when key in @click_ids,
    do: id_field(key, value, 255)

  defp user_field(key, value, _default_country) when key in @plain and is_binary(value),
    do: {:ok, {Atom.to_string(key), value}}

  defp user_field(:consent, value, _default_country) when is_list(value) or is_map(value) do
    if pairs?(value) and
         Enum.all?(value, fn {k, v} ->
           to_string(k) in ~w(analytics marketing functional) and is_boolean(v)
         end),
       do: {:ok, {"consent", Map.new(value, fn {k, v} -> {to_string(k), v} end)}},
       else: invalid("user consent takes analytics, marketing and functional booleans")
  end

  defp user_field(key, _value, _default_country), do: invalid("user #{key} has the wrong type")

  defp id_field(key, value, max) do
    if text?(value, max),
      do: {:ok, {Atom.to_string(key), value}},
      else: invalid("user #{key} must be 1 to #{max} characters")
  end

  defp hash(:email, value, _country), do: Hash.email(value)
  defp hash(:street_address, value, _country), do: Hash.street_address(value)
  defp hash(_name, value, _country), do: Hash.name(value)

  defp app_data(nil), do: {:ok, nil}

  defp app_data(app) when is_list(app) or (is_map(app) and not is_struct(app)) do
    if pairs?(app) do
      app = app |> Enum.to_list() |> Enum.map(fn {k, v} -> {to_atom_key(k), v} end)

      with :ok <- known_app_keys(app),
           :ok <- each_app_key_once(app),
           :ok <- app_required(app) do
        cast_app_fields(app)
      end
    else
      invalid("app must be a keyword list or map")
    end
  end

  defp app_data(_app), do: invalid("app must be a keyword list or map")

  # A string key becomes an atom only when it names a known field, so an
  # unknown string key stays a string and is refused without minting an atom.
  defp to_atom_key(key) when is_atom(key), do: key

  defp to_atom_key(key) when is_binary(key) do
    Enum.find(@app_keys, key, &(Atom.to_string(&1) == key))
  end

  defp known_app_keys(app) do
    case for({key, _value} <- app, key not in @app_keys, do: key) do
      [] -> :ok
      unknown -> invalid("unknown app field: #{inspect(unknown)}")
    end
  end

  defp each_app_key_once(app) do
    keys = Enum.map(app, fn {key, _value} -> key end)

    if keys == Enum.uniq(keys), do: :ok, else: invalid("app names a field more than once")
  end

  defp cast_app_fields(app) do
    app
    |> Enum.reject(fn {_key, value} -> value == nil end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case app_field(key, value) do
        {:ok, cast} -> {:cont, {:ok, Map.put(acc, Atom.to_string(key), cast)}}
        error -> {:halt, error}
      end
    end)
  end

  defp app_required(app) do
    given = for {key, value} <- app, value != nil, do: key

    case Enum.find(@app_required, &(&1 not in given)) do
      nil -> :ok
      key -> invalid("app #{key} is required")
    end
  end

  defp app_field(:os, value) when value in [:ios, :android, "ios", "android"],
    do: {:ok, to_string(value)}

  defp app_field(:os, _value), do: invalid("app os must be :ios or :android")

  defp app_field(:att_status, value) when is_atom(value) and value != nil,
    do: app_field(:att_status, value |> Atom.to_string() |> String.upcase())

  defp app_field(:att_status, value) when value in @att_statuses, do: {:ok, value}

  defp app_field(:att_status, _value),
    do: invalid("app att_status must be one of #{Enum.join(@att_statuses, ", ")}")

  defp app_field(key, value) when key in @app_booleans do
    if is_boolean(value), do: {:ok, value}, else: invalid("app #{key} must be true or false")
  end

  defp app_field(key, value) when key in @app_strings do
    if text?(value, 128),
      do: {:ok, value},
      else: invalid("app #{key} must be 1 to 128 characters")
  end

  # A UTF-8 string of 1 to `max` code points with a visible character, as
  # the server counts them.
  defp text?(value, max) do
    is_binary(value) and String.valid?(value) and String.trim(value) != "" and
      not String.contains?(value, <<0>>) and length(String.codepoints(value)) <= max
  end

  defp event_data(data) when is_list(data) or is_map(data) do
    if pairs?(data) do
      data = Map.new(data, fn {k, v} -> {to_string(k), v} end)

      # event_data is sent as given, so personal data here would leave in
      # plain text. Send it under `user:`, which hashes it.
      case personal_key_path(data, "data") do
        nil -> {:ok, data}
        {:improper, path} -> invalid("#{path} must be a proper list")
        path -> invalid(personal_message(path))
      end
    else
      invalid("data must be a keyword list or a map with string keys")
    end
  end

  defp event_data(_data), do: invalid("data must be a keyword list or map")

  # A keyword list, or a map keyed by atoms or strings. A struct is a value:
  # enumerating one raises.
  defp pairs?(value) when is_struct(value), do: false

  defp pairs?(value) when is_map(value),
    do: Enum.all?(value, fn {k, _v} -> is_atom(k) or is_binary(k) end)

  defp pairs?(value) when is_list(value), do: Keyword.keyword?(value)
  defp pairs?(_value), do: false

  @platforms_named ~w(meta tiktok)

  # The server checks blank, NUL and length (50 code points), as it does for
  # event_name. A refusal names the key, never the event name.
  defp platform_event_names(names) do
    with :ok <- platform_names_shape(names),
         :ok <- known_platforms(names),
         :ok <- each_platform_once(names),
         :ok <- platform_name_values(names) do
      {:ok, Map.new(names, fn {k, v} -> {to_string(k), v} end)}
    end
  end

  defp platform_names_shape(names) do
    if pairs?(names),
      do: :ok,
      else: invalid("platform_event_names must be a keyword list or map")
  end

  defp known_platforms(names) do
    case for({k, _v} <- names, to_string(k) not in @platforms_named, do: k) do
      [] ->
        :ok

      unknown ->
        invalid("platform_event_names takes only meta and tiktok, not #{inspect(unknown)}")
    end
  end

  # `[meta: "a", meta: "b"]` or `%{:meta => "a", "meta" => "b"}` would
  # send one of the two without saying which.
  defp each_platform_once(names) do
    keys = Enum.map(names, fn {k, _v} -> to_string(k) end)

    if keys == Enum.uniq(keys),
      do: :ok,
      else: invalid("platform_event_names names a platform more than once")
  end

  defp platform_name_values(names) do
    if Enum.all?(names, fn {_k, v} -> is_binary(v) and v != "" and String.valid?(v) end),
      do: :ok,
      else: invalid("platform_event_names values must be non-empty UTF-8 strings")
  end

  @personal_names ~w(first_name last_name street_address)
  @device_names ~w(madid idfv anon_id)

  # The path of the first key, at any depth, whose name marks personal data.
  # A struct such as a DateTime is a value, not a container.
  defp personal_key_path(struct, _path) when is_struct(struct), do: nil

  defp personal_key_path(map, path) when is_map(map) do
    Enum.find_value(map, fn {key, value} ->
      name = if is_atom(key) or is_binary(key), do: to_string(key)
      key_path = "#{path}.#{name}"

      if name && personal_name?(name), do: key_path, else: personal_key_path(value, key_path)
    end)
  end

  defp personal_key_path(list, path) when is_list(list) do
    cond do
      List.improper?(list) ->
        {:improper, path}

      Keyword.keyword?(list) and list != [] ->
        personal_key_path(Map.new(list), path)

      true ->
        list
        |> Enum.with_index()
        |> Enum.find_value(fn {value, i} -> personal_key_path(value, "#{path}[#{i}]") end)
    end
  end

  defp personal_key_path(_value, _path), do: nil

  defp personal_message(path) do
    key = path |> String.split(".") |> List.last() |> String.downcase()

    if key in @device_names,
      do: "data must not hold #{path}; pass it under user: with app:",
      else: "data must not hold #{path}; pass it under user: so it is hashed"
  end

  defp personal_name?(name) do
    name = name |> String.trim() |> String.downcase()

    String.contains?(name, ["email", "phone"]) or name in @personal_names or
      name in @device_names
  end

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
