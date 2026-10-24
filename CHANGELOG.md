# Changelog

## 0.2.0 (2026-10-24)

- Every dependency in the lock moves to its latest release, including req 0.7.5
  and plug_crypto 2.2.1 (CVE-2026-105963). The lock only affects this
  repository's own tests; the version ranges in `mix.exs` do not change, so
  move plug_crypto to 2.2.1 in your own app's lock to get the fix.
- `page_url` loses its fragment as well as its query string unless you pass
  `query_string: true`, and always loses a user name and password in the
  URL. This matches adinize-js; a fragment can hold `#access_token=...`.
- A 429 whose `Retry-After` is over 60 seconds comes back as the error
  instead of being waited out, under `retry: true` and in the batcher. A
  `Retry-After` of 60 or less is still waited.

## 0.1.2 (2026-10-03)

- `Adinize.track/2` takes `platform_event_names:`, the name Meta or TikTok
  gets instead of adinize's mapping, such as `[tiktok: "Contact"]` for a
  `Lead`. A platform other than `meta` or `tiktok`, an empty name or a
  name that is not a UTF-8 string is `INVALID_OPTION`, as is a platform
  named twice.
- A struct passed as `user:`, `consent:` or `data:` is `INVALID_OPTION`.
  It used to raise; under `track_async/2` the raise crashed the batcher,
  which lost the events it held.
- `spec/server-events-v1.yaml` matches the server's contract, which now
  documents `platform_event_names` and lists the standard `event_name`
  values.

## 0.1.1 (2026-10-02)

- `Adinize.Plug.context/2` reads TikTok's `_ttp` cookie and sends it as
  `user_data.ttp`, which the server forwards to TikTok. `ttp:` joins the
  plain `user` keys.
- `spec/server-events-v1.yaml` matches the server's contract, which now
  documents `ttp`.

## 0.1.0 - 2026-10-02

First release on Hex.

- `Adinize.track/2` and `Adinize.track_many/2` send events to the server
  events API and return the result for each event.
- `Adinize.Hash` and `Adinize.Phone` hash personal fields; phones become
  E.164 with a `default_country`.
- `phone:` also sends `phone_digits_hash`, the hash of the E.164 number
  without its `+`, which Meta matches; `phone_digits_hash:` joins the
  pre-hashed keys. `Adinize.Hash.phone_digits/2` computes it. `phone:` with
  a pre-hashed phone key is `INVALID_OPTION`.
- `Adinize.Plug.context/2` reads the visitor and Meta cookies, the IP and
  the User-Agent from a `Plug.Conn`.
- `Adinize.Batcher` sends `Adinize.track_async/2` events in the
  background, on a timer or at `max_batch`, with retry and a bounded
  queue. `Adinize.track/2` gains `retry: true` (default `false`), the
  same policy. Telemetry: `[:adinize, :request, :start | :stop |
  :exception]`, `[:adinize, :event, :rejected]`,
  `[:adinize, :event, :dropped]`.
