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
end
