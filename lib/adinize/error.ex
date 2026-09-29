defmodule Adinize.Error do
  @moduledoc """
  Why a request stored nothing: the SDK refused to send it, the connection
  failed, or the server refused the whole request.

  `status` is the HTTP status, or `nil` when no response arrived. `code` is
  the server's error code (`INVALID_REQUEST`, `INVALID_KEY`,
  `PIXEL_INACTIVE`, `RATE_LIMITED`) or one of the SDK's own:

  | code | when |
  |---|---|
  | `MISSING_SECRET_KEY` | no `:secret_key` in the options or `config :adinize`; nothing was sent |
  | `INVALID_OPTION` | an option or field has the wrong name or type; nothing was sent |
  | `TOO_MANY_EVENTS` | `track_many/2` got more than 100 events; nothing was sent |
  | `TIMEOUT` | no response within `:receive_timeout` |
  | `TRANSPORT_ERROR` | the connection failed, for example refused or DNS |
  | `HTTP_ERROR` | a status without the documented error body, such as a 502 page |
  | `INVALID_RESPONSE` | a 200 whose body is not the documented results list |

  `retry_after` is set on a 429: wait that many seconds, then send the same
  events again. The struct never holds the secret key, the request or the
  response.
  """

  defexception [:status, :code, :message, :retry_after, :reason]

  @type t :: %__MODULE__{
          status: pos_integer() | nil,
          code: String.t(),
          message: String.t(),
          retry_after: non_neg_integer() | nil,
          reason: atom() | nil
        }

  @impl true
  def message(%__MODULE__{status: nil, code: code, message: message}),
    do: "#{code}: #{message}"

  def message(%__MODULE__{status: status, code: code, message: message}),
    do: "HTTP #{status} #{code}: #{message}"
end
