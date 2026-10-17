defmodule Adinize.RetryTest do
  use ExUnit.Case, async: true

  alias Adinize.{Error, Retry}

  test "retryable?/1 classifies every status the design names" do
    assert Retry.retryable?(%Error{status: 429})
    assert Retry.retryable?(%Error{status: 500})
    assert Retry.retryable?(%Error{status: 503})
    assert Retry.retryable?(%Error{status: nil, code: "TIMEOUT"})
    assert Retry.retryable?(%Error{status: nil, code: "TRANSPORT_ERROR"})
    refute Retry.retryable?(%Error{status: 400})
    refute Retry.retryable?(%Error{status: 401})
    refute Retry.retryable?(%Error{status: nil, code: "INVALID_OPTION"})
    refute Retry.retryable?(%Error{status: nil, code: "MISSING_SECRET_KEY"})
  end

  test "run/2 returns the first success, no retry" do
    assert {:ok, :done} = Retry.run(fn -> {:ok, :done} end)
  end

  test "run/2 returns immediately on a non-retryable error" do
    calls = :counters.new(1, [])

    fun = fn ->
      :counters.add(calls, 1, 1)
      {:error, %Error{status: 400}}
    end

    assert {:error, %Error{status: 400}} = Retry.run(fun)
    assert :counters.get(calls, 1) == 1
  end

  defp rate_limited(seconds),
    do: {:error, %Error{status: 429, code: "RATE_LIMITED", retry_after: seconds}}

  # Returns the sent value for each call, and records every sleep.
  defp run_recorded(responses) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fun = fn ->
      Agent.get_and_update(agent, fn
        [next] -> {next, [next]}
        [next | rest] -> {next, rest}
      end)
    end

    result = Retry.run(fun, sleep: fn ms -> send(test, {:slept, ms}) end)
    {result, drain_sleeps([])}
  end

  defp drain_sleeps(acc) do
    receive do
      {:slept, ms} -> drain_sleeps([ms | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "run/2 waits a Retry-After at the 60 s cap" do
    {result, sleeps} = run_recorded([rate_limited(60), {:ok, :sent}])
    assert result == {:ok, :sent}
    assert sleeps == [60_000]
  end

  test "run/2 returns a 429 whose Retry-After passes the cap, without waiting or retrying" do
    for seconds <- [61, 3_600, 2_200_000] do
      {result, sleeps} = run_recorded([rate_limited(seconds), {:ok, :sent}])

      assert {:error, %Error{status: 429, retry_after: ^seconds}} = result
      assert sleeps == []
    end
  end

  test "run/2 still waits a small Retry-After and then retries" do
    {result, sleeps} = run_recorded([rate_limited(3), {:ok, :sent}])
    assert result == {:ok, :sent}
    assert sleeps == [3_000]
  end

  test "run/2 backs off, not capped away, on a 429 without Retry-After" do
    {result, sleeps} = run_recorded([rate_limited(nil), {:ok, :sent}])
    assert result == {:ok, :sent}
    assert [ms] = sleeps
    assert ms in 1..200
  end
end
