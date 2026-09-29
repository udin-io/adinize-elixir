defmodule Adinize.Batcher do
  @moduledoc """
  Sends events queued by `Adinize.track_async/2` in the background.

      children = [{Adinize.Batcher, flush_interval: 1_000, max_batch: 100}]

  A thin supervisor over the process that holds the queue
  (`Adinize.Batcher.Queue`) and the `Task.Supervisor` that runs each HTTP
  send, so a crash mid-send never loses the rest of the queue.

  Options: `:name` (default `Adinize.Batcher`), `:flush_interval` (ms,
  default 1,000), `:max_batch` (1 to 100, default 100), `:max_queue`
  (default 10,000 — past this, `track_async/2` returns
  `{:error, :queue_full}` and `[:adinize, :event, :dropped]` fires),
  `:shutdown` (ms, default 5,000 — how long a stop gets to flush what is
  held), plus `:secret_key`, `:base_url`, `:receive_timeout`,
  `:req_options`, `:default_country` (see `Adinize.Client`).
  """

  use Supervisor

  alias Adinize.Batcher.Queue

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(name))
  end

  def child_spec(opts) do
    default = super(opts)
    Map.put(default, :shutdown, Keyword.get(opts, :shutdown, Queue.default_shutdown()))
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    children = [
      {Task.Supervisor, name: task_supervisor_name(name)},
      {Queue, Keyword.put(opts, :name, name)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def queue_name(name), do: Module.concat(name, :Queue)
  @doc false
  def task_supervisor_name(name), do: Module.concat(name, :TaskSupervisor)
  defp supervisor_name(name), do: Module.concat(name, :Supervisor)

  @doc """
  Enqueues one event for the batcher named `name` (default
  `Adinize.Batcher`) to send later. Returns `{:error, :batcher_not_started}`
  when no batcher by that name is running, `{:error, :queue_full}` at
  `:max_queue`, or the same `{:error, %Adinize.Error{}}` `track/2` would
  return for the same options — the event was never queued.
  """
  @spec enqueue(atom(), String.t(), keyword()) ::
          :ok | {:error, :batcher_not_started | :queue_full | Adinize.Error.t()}
  def enqueue(name \\ __MODULE__, event_name, opts) do
    case Process.whereis(queue_name(name)) do
      nil -> {:error, :batcher_not_started}
      pid -> GenServer.call(pid, {:enqueue, event_name, opts})
    end
  end
end
