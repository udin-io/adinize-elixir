# Changelog

## Unreleased

- `Adinize.track/2` and `Adinize.track_many/2` send events to the server
  events API and return the result for each event.
- `Adinize.Hash` and `Adinize.Phone` hash personal fields; phones become
  E.164 with a `default_country`.
- `Adinize.Plug.context/2` reads the visitor and Meta cookies, the IP and
  the User-Agent from a `Plug.Conn`.
- `Adinize.Batcher` sends `Adinize.track_async/2` events in the
  background, on a timer or at `max_batch`, with retry and a bounded
  queue. `Adinize.track/2` gains `retry: true` (default `false`), the
  same policy. Telemetry: `[:adinize, :request, :start | :stop |
  :exception]`, `[:adinize, :event, :rejected]`,
  `[:adinize, :event, :dropped]`.
