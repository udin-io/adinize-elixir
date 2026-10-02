# Changelog

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
