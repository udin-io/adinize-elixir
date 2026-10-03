# adinize

Elixir SDK for the adinize server events API. Your server reports
conversions to adinize, which attributes them to the ad click and forwards
them to Meta, TikTok and Google Ads.

Personal data leaves your server only as SHA-256 hashes.

## Install

```elixir
def deps do
  [{:adinize, "~> 0.1"}]
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
  hashed before sending. `data:` goes as given, so any key in it, at any
  depth, named `*email*`, `*phone*`, `first_name`, `last_name` or
  `street_address` is refused with the key's path.
- `page_url` goes without its query string, which can hold an email or a
  token. Pass `query_string: true` to keep it.
- `event_id` defaults to a UUIDv4 and `event_time` to now. Send your order
  number as `event_id` so a retry never counts twice: the server answers
  `:duplicate` for an `event_id` it already holds.
- Phones become E.164 before hashing. A local number takes
  `default_country`'s code; one without a `+`, a `00` prefix or a default
  country is left out. Arabic-Indic digits work, and for EG, SA, AE, GB and
  JO a `0` written after the country code is dropped.
- `phone:` sends two hashes of the same E.164 number: `phone_hash` (with the
  `+`, read by Google Ads and TikTok) and `phone_digits_hash` (digits only,
  the form Meta matches). A number with no E.164 form sends neither.
- Pre-hashed keys (`email_hash:`, `phone_hash:`, `phone_digits_hash:`,
  `first_name_hash:`, `last_name_hash:`, `street_address_hash:`) take 64
  lowercase hex characters. The SDK cannot derive one phone hash from the
  other, so pass both `phone_hash:` and `phone_digits_hash:`. With only
  `phone_hash:`, Google and TikTok match the phone and Meta does not.
  `phone:` beside either pre-hashed phone key is `INVALID_OPTION`.
- `platform_event_names: [tiktok: "Contact"]` sends Meta or TikTok its own
  name instead of adinize's mapping. Your pixel's Forwarding settings still
  match on the event name you pass to `track/2`, and revenue follows it.
  A renamed event no longer deduplicates against a browser event with the
  same `event_id`, since the platforms match on name and `event_id`. Only
  `meta` and `tiktok` are accepted; the server refuses a name over 50
  characters (Unicode code points).
- `Adinize.track_many/2` sends up to 100 events in one request.

From a Phoenix controller, add the visitor cookie, Meta's and TikTok's
cookies, the IP and the User-Agent:

```elixir
Adinize.track("Purchase", Adinize.Plug.context(conn) ++ [event_id: order.id])
```

## Hashing

The SDK hashes these fields with SHA-256 before the request leaves your
server. It trims and lowercases text first, as Meta's customer information
rules say.

| Field | Hashed from |
|---|---|
| `email` | the trimmed, lowercased address |
| `phone` | the E.164 digits (see the phone rule above); Meta gets them without the `+` |
| `first_name`, `last_name` | the trimmed, lowercased name |
| `street_address` | the trimmed, lowercased text |

A field that is empty after trimming, or a phone that cannot become E.164,
is left out of the request. IP address, User-Agent, the `_fbc` and `_fbp`
cookies, and the `_ttp` cookie (as `ttp:`) go as given: Meta and TikTok
match them unhashed.
`Adinize.Hash` exposes each function if you need a hash elsewhere.

## Deduplicate with the browser pixel

When the adinize pixel in the browser and your server both report the same
purchase, give both the same `event_id`, and use the same event name. The
platforms keep one of the two: Meta and TikTok merge a browser and a server
event that share `event_id` within 48 hours.

Your server call carries the order number the browser event carries as
its `event_id`:

```elixir
Adinize.track("Purchase", event_id: "order_10482", data: [value: 129.5, currency: "EGP"])
```

Your pixel's page in adinize shows how to send an `event_id` from the
browser. A retry from your server is safe for the same reason: adinize answers
`:duplicate` for an `event_id` its pixel already holds.

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

`Adinize.Error` lists every code. `track/2` does not retry unless you pass
`retry: true` (see below).

## Sending in the background

A developer who does not want a web request to wait on adinize adds a
batcher to the supervision tree and sends asynchronously:

```elixir
children = [{Adinize.Batcher, flush_interval: 1_000, max_batch: 100}]

Adinize.track_async("Purchase",
  event_id: "order_10482",
  data: [value: 129.5, currency: "EGP"]
)
#=> :ok
```

- Sends every `flush_interval` ms (default 1,000) or at `max_batch`
  events (default 100, capped at 100). Past `max_queue` (default 10,000)
  it drops the newest event and emits telemetry, rather than growing
  memory without bound.
- On a 429 it waits `Retry-After` (falling back to the same backoff as a
  5xx when the server gives none); on a 5xx, a timeout or a transport
  error it backs off with jitter, up to 5 attempts total, the same
  `event_id` each time — the server answers a retried event `:duplicate`,
  never twice. A 400 or 401 is never retried.
- On a supervised stop it flushes what it holds, best effort, within
  `shutdown` ms (default 5,000).
- `track/2` (sync) takes the same retry policy with `retry: true`
  (default `false`).
- Telemetry: `[:adinize, :request, :start | :stop | :exception]` around
  every send, `[:adinize, :event, :rejected]` for a rejected result, and
  `[:adinize, :event, :dropped]` when an event is dropped (queue full,
  retries exhausted, a non-retryable error, or shutdown). Metadata never
  holds the secret key, a raw personal field or the request/response —
  only ids, names and the server's own field/code/message strings.

## The secret key

The SDK never logs the key and never puts it in an error or in its own
telemetry. Finch's telemetry events carry the request headers, key
included: if your app logs Finch telemetry metadata, filter the
`authorization` header first.

## Contract

The API behind this SDK is described by one OpenAPI file:
<https://adinize.ai/api/server/v1/openapi.yaml>. `spec/server-events-v1.yaml`
holds a copy that CI compares with the live file. Docs: <https://hexdocs.pm/adinize>.

## License

MIT
