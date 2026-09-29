defmodule Adinize.ConfigTest do
  # Mutates the :adinize application env, which every test reads.
  use ExUnit.Case, async: false

  alias Adinize.Test.Stub

  setup do
    on_exit(fn -> Application.delete_env(:adinize, :default_country) end)
  end

  defp phone_hash_sent(opts) do
    Stub.respond(__MODULE__, 200, Stub.accepted("x"))
    Adinize.track("Lead", Keyword.merge(Stub.opts(__MODULE__), opts))
    assert_received {:request, _conn, raw}
    %{"events" => [event]} = Jason.decode!(raw)
    get_in(event, ["user_data", "phone_hash"])
  end

  test "config :adinize, default_country applies when the call gives none" do
    Application.put_env(:adinize, :default_country, "SA")

    assert phone_hash_sent(user: [phone: "0501234567"]) ==
             Adinize.Hash.phone("+966501234567")
  end

  test "a per-call default_country wins over config" do
    Application.put_env(:adinize, :default_country, "SA")

    assert phone_hash_sent(user: [phone: "0501234567"], default_country: "AE") ==
             Adinize.Hash.phone("+971501234567")
  end
end
