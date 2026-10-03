defmodule Adinize.ContractTest do
  @moduledoc """
  Every request body the SDK builds validates against the vendored
  `spec/server-events-v1.yaml`. CI's spec-drift job keeps that file equal to
  the live contract.

  Not covered: the server's own checks beyond the schema, such as the
  7-day `event_time` limit, the 32 KB `event_data` limit and `RAW_PII`.
  The schema allows extra `user_data` keys, so it cannot catch a raw
  `email`; `AdinizeTest` checks that the body never holds one.
  """
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  @spec_path Path.expand("../../spec/server-events-v1.yaml", __DIR__)
  @external_resource @spec_path

  setup_all do
    schemas = YamlElixir.read_from_file!(@spec_path)["components"]["schemas"]

    # ex_json_schema reads draft 7, where refs point at #/definitions.
    root =
      schemas["EventBatch"]
      |> Map.put("definitions", schemas)
      |> rewrite_refs()
      |> ExJsonSchema.Schema.resolve()

    %{root: root}
  end

  defp rewrite_refs(%{"$ref" => "#/components/schemas/" <> name} = map),
    do: Map.put(map, "$ref", "#/definitions/" <> name)

  defp rewrite_refs(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, rewrite_refs(v)} end)
  defp rewrite_refs(list) when is_list(list), do: Enum.map(list, &rewrite_refs/1)
  defp rewrite_refs(other), do: other

  defp body_sent(name, opts) do
    Stub.respond(__MODULE__, 200, Stub.accepted("x"))
    {:ok, _} = Adinize.track(name, opts ++ Stub.opts(__MODULE__))
    assert_received {:request, _conn, raw}
    Jason.decode!(raw)
  end

  test "a full event validates", %{root: root} do
    json =
      body_sent("Purchase",
        event_id: "order_1",
        event_time: DateTime.utc_now(),
        visitor_id: "mb.1.abc",
        page_url: "https://shop.example.com/",
        default_country: "EG",
        user: [
          email: "a@b.co",
          phone: "0100 123 4567",
          first_name: "Jane",
          last_name: "Doe",
          street_address: "1 Nile St",
          external_id: "u1",
          client_ip_address: "203.0.113.7",
          client_user_agent: "UA",
          fbp: "fb.1.1.1",
          fbc: "fb.1.1.abc",
          ttp: "ttp-value",
          gclid: "g",
          ttclid: "t",
          city: "cairo",
          state: "c",
          postal_code: "11511",
          country_code: "eg",
          consent: [analytics: true, marketing: false, functional: true]
        ],
        data: [value: 1.5, currency: "EGP", order_id: "1", content_ids: ["a"]]
      )

    assert map_size(json["events"] |> hd() |> Map.fetch!("user_data")) == 19
    assert ExJsonSchema.Validator.validate(root, json) == :ok
  end

  test "the spec documents ttp as TikTok's _ttp cookie", %{root: root} do
    props = root.schema["definitions"]["UserData"]["properties"]
    assert props["ttp"]["type"] == "string"
    assert props["ttp"]["description"] =~ "`_ttp` cookie"
  end

  test "the spec documents phone_digits_hash", %{root: root} do
    props = root.schema["definitions"]["UserData"]["properties"]
    assert Map.has_key?(props, "phone_digits_hash")
  end

  test "both phone hashes validate; a digits hash that is not a SHA-256 does not", %{root: root} do
    json = body_sent("Lead", user: [phone: "+1 650 555 1212"])
    assert %{"phone_digits_hash" => _, "phone_hash" => _} = hd(json["events"])["user_data"]
    assert ExJsonSchema.Validator.validate(root, json) == :ok

    bad = put_in(json, ["events", Access.at(0), "user_data", "phone_digits_hash"], "16505551212")
    assert {:error, _} = ExJsonSchema.Validator.validate(root, bad)
  end

  test "an event with platform_event_names validates", %{root: root} do
    json = body_sent("Lead", platform_event_names: [meta: "Lead", tiktok: "Contact"])

    assert hd(json["events"])["platform_event_names"] == %{
             "meta" => "Lead",
             "tiktok" => "Contact"
           }

    assert ExJsonSchema.Validator.validate(root, json) == :ok
  end

  test "the schema refuses platform_event_names for another platform, so the check has teeth",
       %{root: root} do
    json = body_sent("Lead", platform_event_names: [tiktok: "Contact"])
    bad = put_in(json, ["events", Access.at(0), "platform_event_names", "google_ads"], "x")
    assert {:error, _} = ExJsonSchema.Validator.validate(root, bad)
  end

  test "a minimal event validates", %{root: root} do
    assert ExJsonSchema.Validator.validate(root, body_sent("Lead", [])) == :ok
  end

  test "the schema refuses an email_hash that is not a SHA-256, so the check has teeth",
       %{root: root} do
    bad = %{
      "events" => [
        %{
          "event_id" => "x",
          "event_name" => "L",
          "event_time" => 1,
          "user_data" => %{"email_hash" => "raw@x.co"}
        }
      ]
    }

    assert {:error, _} = ExJsonSchema.Validator.validate(root, bad)
  end
end
