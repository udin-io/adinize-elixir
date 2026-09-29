# adinize

Elixir SDK for the adinize server events API. Your server reports
conversions to adinize, which attributes them to the ad click and forwards
them to Meta, TikTok and Google Ads.

Personal data leaves your server only as SHA-256 hashes.

## Install

```elixir
def deps do
  [{:adinize, github: "udin-io/adinize-elixir"}]
end
```

Create a secret key on your pixel's page in adinize, and keep it on your
server:

```elixir
# config/runtime.exs
config :adinize,
  secret_key: System.fetch_env!("ADINIZE_SECRET_KEY"),
  default_country: "EG"
```

## Send an event

```elixir
Adinize.track("Purchase",
  event_id: "order_10482",
  user: [email: " Jane@Example.com ", phone: "0100 123 4567"],
  data: [value: 129.5, currency: "EGP", order_id: "10482"]
)
#=> {:ok, %Adinize.Result{event_id: "order_10482", status: :accepted, errors: []}}
```

- `email`, `phone`, `first_name`, `last_name` and `street_address` are
  hashed before sending. `data:` goes as given, so an `email` or `phone`
  key there is refused.
- `event_id` defaults to a UUIDv4 and `event_time` to now. Send your order
  number as `event_id` so a retry never counts twice: the server answers
  `:duplicate` for an `event_id` it already holds.
- Phones become E.164 before hashing. A local number takes
  `default_country`'s code; one without a `+`, a `00` prefix or a default
  country is left out.
- `Adinize.track_many/2` sends up to 100 events in one request.

From a Phoenix controller, add the visitor cookie, Meta's cookies, the IP
and the User-Agent:

```elixir
Adinize.track("Purchase", Adinize.Plug.context(conn) ++ [event_id: order.id])
```

## Results and errors

Every call returns a value and never raises.

| You get | When |
|---|---|
| `{:ok, %Adinize.Result{status: :accepted}}` | stored |
| `{:ok, %Adinize.Result{status: :duplicate}}` | the pixel already held this `event_id` |
| `{:ok, %Adinize.Result{status: :rejected, errors: [...]}}` | the server refused this event, with reasons |
| `{:error, %Adinize.Error{status: 401, code: "INVALID_KEY"}}` | the key is missing, unknown or revoked |
| `{:error, %Adinize.Error{status: 429, retry_after: 12}}` | wait 12 seconds, then send the same events again |
| `{:error, %Adinize.Error{code: "INVALID_OPTION"}}` | a malformed option; nothing was sent |

`Adinize.Error` lists every code. This release does not retry.

## The secret key

The SDK never logs the key and never puts it in an error. Finch's
telemetry events carry the request headers, key included: if your app logs
Finch telemetry metadata, filter the `authorization` header first.

## License

MIT
