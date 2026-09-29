# Changelog

## Unreleased

- `Adinize.track/2` and `Adinize.track_many/2` send events to the server
  events API and return the result for each event.
- `Adinize.Hash` and `Adinize.Phone` hash personal fields; phones become
  E.164 with a `default_country`.
- `Adinize.Plug.context/2` reads the visitor and Meta cookies, the IP and
  the User-Agent from a `Plug.Conn`.
