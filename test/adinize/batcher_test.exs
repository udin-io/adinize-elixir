defmodule Adinize.BatcherTest do
  use ExUnit.Case, async: true

  alias Adinize.Test.Stub

  defp opts(name, extra) do
    Keyword.merge(
      [flush_interval: 20, max_batch: 100, max_queue: 10_000, name: name],
      Keyword.merge(Stub.opts(name), extra)
    )
  end

  defp start_batcher!(name, extra \\ []) do
    start_supervised!({Adinize.Batcher, opts(name, extra)}, id: name)
  end

  test "sends every flush_interval" do
    name = :"batcher_#{__ENV__.line}"
    start_batcher!(name)
    Stub.respond(name, 200, Stub.accepted("a"))

    assert :ok = Adinize.Batcher.enqueue(name, "Purchase", event_id: "a")
    assert_receive {:request, _conn, raw}, 1_000
    assert %{"events" => [%{"event_id" => "a"}]} = Jason.decode!(raw)
  end

  test "flushes immediately at max_batch, chunked at 100; the tick sweeps the rest" do
    name = :"batcher_#{__ENV__.line}"
    start_batcher!(name, flush_interval: 50, max_batch: 100)

    test = self()

    Req.Test.stub(name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})
      events = Jason.decode!(raw)["events"]
      results = Enum.map(events, &%{"event_id" => &1["event_id"], "status" => "accepted"})
      Req.Test.json(conn, %{"results" => results})
    end)

    for i <- 1..150 do
      assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "e#{i}")
    end

    assert_receive {:request, %{"events" => first}}, 1_000
    assert length(first) == 100
    assert_receive {:request, %{"events" => second}}, 1_000
    assert length(second) == 50
    refute_receive {:request, _}, 200
  end

  test "429 with Retry-After then 200: sent twice with the same event_id, accepted once" do
    name = :"batcher_#{__ENV__.line}"
    start_batcher!(name, flush_interval: 20)

    test = self()
    attempt = :counters.new(1, [])

    Req.Test.stub(name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      n = :counters.get(attempt, 1)
      :counters.add(attempt, 1, 1)
      send(test, {:attempt, n, Jason.decode!(raw)})

      if n == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => "RATE_LIMITED", "message" => "slow down"}})
      else
        Req.Test.json(conn, Stub.accepted("dup1"))
      end
    end)

    assert :ok = Adinize.Batcher.enqueue(name, "Purchase", event_id: "dup1")

    assert_receive {:attempt, 0, %{"events" => [%{"event_id" => "dup1"}]}}, 1_000
    assert_receive {:attempt, 1, %{"events" => [%{"event_id" => "dup1"}]}}, 1_000
    refute_receive {:attempt, 2, _}, 200
  end

  test "500 five times: dropped, [:adinize, :event, :dropped] fires once" do
    name = :"batcher_#{__ENV__.line}"

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:adinize, :event, :dropped]
      ])

    start_batcher!(name, flush_interval: 20)
    Stub.respond(name, 500, %{"error" => %{"code" => "INTERNAL", "message" => "oops"}})

    assert :ok = Adinize.Batcher.enqueue(name, "Purchase", event_id: "e500")

    assert_receive {[:adinize, :event, :dropped], ^ref, %{count: 1},
                    %{event_id: "e500", reason: :retries_exhausted}},
                   5_000

    # :telemetry handlers are process-global, not per-test: a concurrent
    # test's own drop can land in this mailbox too, so the refusal must
    # name this test's own event_id, never a bare wildcard.
    refute_receive {[:adinize, :event, :dropped], ^ref, _, %{event_id: "e500"}}, 200
  end

  test "400 does not retry" do
    name = :"batcher_#{__ENV__.line}"

    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    start_batcher!(name, flush_interval: 20)

    test = self()

    Req.Test.stub(name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"code" => "INVALID_REQUEST", "message" => "bad"}})
    end)

    assert :ok = Adinize.Batcher.enqueue(name, "Purchase", event_id: "bad1")

    assert_receive {[:adinize, :event, :dropped], ^ref, _,
                    %{event_id: "bad1", reason: :rejected_by_server}},
                   1_000

    assert_receive {:request, _}, 1_000
    refute_receive {:request, _}, 200
  end

  test "a partial result: one accepted, one rejected fires [:adinize, :event, :rejected]" do
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :rejected]])
    start_batcher!(name, flush_interval: 20)

    Stub.respond(name, 200, %{
      "results" => [
        %{"event_id" => "ok1", "status" => "accepted"},
        %{
          "event_id" => "bad2",
          "status" => "rejected",
          "errors" => [%{"field" => "event_time", "code" => "INVALID", "message" => "too old"}]
        }
      ]
    })

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "ok1")
    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "bad2")

    assert_receive {[:adinize, :event, :rejected], ^ref, %{count: 1},
                    %{event_id: "bad2", field: "event_time", code: "INVALID"}},
                   1_000
  end

  test "a result count mismatch drops the whole chunk instead of misattributing" do
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    start_batcher!(name, flush_interval: 20)

    # Only one result for two events sent — Enum.zip would silently drop
    # "b" and attribute the one result to "a" with no telemetry at all.
    Stub.respond(name, 200, %{"results" => [%{"event_id" => "a", "status" => "accepted"}]})

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "a")
    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "b")

    assert_receive {[:adinize, :event, :dropped], ^ref, _,
                    %{event_id: "a", reason: :rejected_by_server}},
                   1_000

    assert_receive {[:adinize, :event, :dropped], ^ref, _,
                    %{event_id: "b", reason: :rejected_by_server}},
                   1_000
  end

  test "a crash reason is never logged raw (no client_opts leak surface)" do
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    start_batcher!(name, flush_interval: 20, secret_key: "adzsk_should_never_be_logged")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Req.Test.stub(name, fn _conn -> Process.exit(self(), :kill) end)
        assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "crash2")
        # Telemetry.dropped/3 is the last call in the same handle_info that
        # logs the crash, same process, so this assert_receive guarantees
        # the Logger call already ran before capture_log returns.
        assert_receive {[:adinize, :event, :dropped], ^ref, _, %{event_id: "crash2"}}, 5_000
      end)

    refute log =~ "adzsk_should_never_be_logged"
  end

  test "a raised exception whose own term embeds the secret never reaches any log" do
    # OTP logs a crashed Task's exit reason automatically (via
    # Task.Supervised), independent of anything this code logs — and that
    # reason can embed a raising call's own arguments (a MatchError's
    # failing term, in particular). Verified against a bare Task in a
    # standalone probe (see the PR body): an uncaught MatchError whose
    # value held a secret printed that secret via OTP's own crash report,
    # with no line of this codebase involved; wrapping the same call in
    # try/rescue/catch (safe_flush/1) closed it completely. Here, this
    # specific shape is caught one layer earlier still — inside
    # Req.Test's stub, which runs inside Client.post_events/2's own
    # existing rescue (#608) — so this proves the whole pipeline stays
    # leak-free end to end, whichever layer catches it first.
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    secret = "adzsk_never_via_crash_report_#{System.unique_integer([:positive])}"
    start_batcher!(name, flush_interval: 20, secret_key: secret)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Req.Test.stub(name, fn conn ->
          # conn carries the real Authorization header (Bearer <secret>);
          # raising a MatchError whose term holds it is the closest local
          # stand-in for a dependency bug whose failing term holds request
          # state. Raised directly (not via a doomed `=` match) so the
          # compiler's type checker, which can already prove a literal
          # `{:ok, _} = {:error, conn}` never matches, has nothing to warn
          # about — the two produce the identical %MatchError{}.
          raise MatchError, term: {:error, conn, :never_matches}
        end)

        assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "crash3")
        assert_receive {[:adinize, :event, :dropped], ^ref, _, %{event_id: "crash3"}}, 5_000
      end)

    # async: true means another test's own log lines can land in this
    # capture too (ExUnit.CaptureLog's own documented caveat), so this
    # checks for the absence of markers unique to THIS crash rather than
    # asserting the whole capture is empty. "MatchError" alone is the
    # expected, safe module-name-only message Client.handle/1 already
    # produces (#608) — only the raw term (the secret, or the atom from
    # its failing value) must never appear.
    refute log =~ secret
    refute log =~ "never_matches"
  end

  test "queue_full: track_async returns {:error, :queue_full} and does not enqueue" do
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    # Never respond, so nothing ever drains the queue.
    start_batcher!(name, flush_interval: 60_000, max_batch: 100, max_queue: 2)

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "a")
    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "b")
    assert {:error, :queue_full} = Adinize.Batcher.enqueue(name, "Lead", event_id: "c")

    assert_receive {[:adinize, :event, :dropped], ^ref, _, %{event_id: "c", reason: :queue_full}},
                   1_000
  end

  test "a crash mid-flush drops that chunk after one attempt; the queue survives" do
    # Client.post_events/2 already rescues/catches every Req failure, so
    # the only way a flush genuinely crashes the Task (not just returns
    # {:error, _}) is an untrappable kill — the same shape an OOM kill or
    # `:brutal_kill` from a supervisor would take. A killed Task takes its
    # in-progress Retry.run/2 loop down with it, so this chunk gets no
    # further attempts (unlike an ordinary HTTP failure, which retries up
    # to 5 times inside the same Task) — see the PR body.
    name = :"batcher_#{__ENV__.line}"
    ref = :telemetry_test.attach_event_handlers(self(), [[:adinize, :event, :dropped]])
    start_batcher!(name, flush_interval: 20)

    Req.Test.stub(name, fn _conn -> Process.exit(self(), :kill) end)

    queue_pid = Process.whereis(Adinize.Batcher.queue_name(name))
    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "crash1")

    assert_receive {[:adinize, :event, :dropped], ^ref, _,
                    %{event_id: "crash1", reason: :crashed}},
                   5_000

    # The queue GenServer itself never crashed: same pid, still accepts work.
    assert Process.whereis(Adinize.Batcher.queue_name(name)) == queue_pid
    Stub.respond(name, 200, Stub.accepted("after-crash"))
    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "after-crash")
    assert_receive {:request, _conn, _raw}, 1_000
  end

  test "batcher not started: track_async returns {:error, :batcher_not_started}" do
    assert {:error, :batcher_not_started} =
             Adinize.Batcher.enqueue(:no_such_batcher_running, "Lead", event_id: "x")
  end

  test "invalid options at enqueue time: nothing is queued, the batcher stays usable" do
    name = :"batcher_#{__ENV__.line}"
    start_batcher!(name, flush_interval: 20)
    Stub.respond(name, 200, Stub.accepted("good"))

    assert {:error, %Adinize.Error{code: "INVALID_OPTION"}} =
             Adinize.Batcher.enqueue(name, "", event_id: "bad")

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "good")
    assert_receive {:request, _conn, _raw}, 1_000
  end

  test "stopping the batcher sends what it holds" do
    name = :"batcher_#{__ENV__.line}"
    # No test process supervision here: start_supervised! would kill the
    # batcher when the test exits, before we can assert on the drain.
    {:ok, _pid} = Adinize.Batcher.start_link(opts(name, flush_interval: 60_000))
    Stub.respond(name, 200, Stub.accepted("held"))

    assert :ok = Adinize.Batcher.enqueue(name, "Lead", event_id: "held")
    Supervisor.stop(Module.concat(name, :Supervisor))

    assert_received {:request, _conn, raw}
    assert %{"events" => [%{"event_id" => "held"}]} = Jason.decode!(raw)
  end
end
