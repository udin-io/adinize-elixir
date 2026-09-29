defmodule Adinize.Result do
  @moduledoc """
  The server's answer for one event.

  - `:accepted`: stored and queued for the platforms.
  - `:duplicate`: the pixel already holds this `event_id`; nothing new was
    stored, so a retry is always safe.
  - `:rejected`: not stored; `errors` lists each field, code and message.
  """

  defstruct [:event_id, :status, errors: []]

  @type status :: :accepted | :duplicate | :rejected
  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          status: status(),
          errors: [%{field: String.t() | nil, code: String.t() | nil, message: String.t() | nil}]
        }

  @statuses %{"accepted" => :accepted, "duplicate" => :duplicate, "rejected" => :rejected}

  @doc false
  def from_json(%{"status" => status} = result) when is_map_key(@statuses, status) do
    {:ok,
     %__MODULE__{
       event_id: string(result["event_id"]),
       status: Map.fetch!(@statuses, status),
       errors: result["errors"] |> List.wrap() |> Enum.map(&error/1)
     }}
  end

  def from_json(_result), do: :error

  defp error(%{} = e),
    do: %{field: string(e["field"]), code: string(e["code"]), message: string(e["message"])}

  defp error(_e), do: %{field: nil, code: nil, message: nil}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
