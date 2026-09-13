defmodule Postbeam.SentStore.ETS do
  @moduledoc """
  Bounded, volatile archive backed by a protected ETS table.

  Postbeam supervises the default instance, retaining the last 10 accepted
  emails. Archiving is opt-in (`sent_store: Postbeam.SentStore.ETS`). Entries are
  newest first in insertion order; concurrent SMTP calls may finish in a different
  order. Writes/eviction are serialized by the owner; reads access ETS directly.
  Entries disappear on owner/node restart and are local to this node.

  For a different capacity, add an instance to your application's children:

      {Postbeam.SentStore.ETS, name: MyApp.SentEmails, limit: 100}

  Then use `sent_store: {Postbeam.SentStore.ETS, name: MyApp.SentEmails}` and
  `Postbeam.SentStore.ETS.list(name: MyApp.SentEmails)`.

  `limit` bounds the number of emails, not their total byte size. Bodies and
  attachments (when supported) are retained in memory; use durable storage for
  audit requirements. Never create instance names from untrusted input.
  """
  use GenServer
  @behaviour Postbeam.SentStore

  @type option :: {:name, atom()} | {:limit, pos_integer()}

  @doc "Starts a named archive owner; options are `:name` and positive `:limit`."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options \\ []) do
    case validate(options) do
      {:ok, name, limit} -> GenServer.start_link(__MODULE__, {name, limit}, name: name)
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{id: Keyword.get(options, :name, __MODULE__), start: {__MODULE__, :start_link, [options]}}
  end

  @impl true
  def init({name, limit}) do
    table = :ets.new(name, [:named_table, :protected, :ordered_set, read_concurrency: true])
    {:ok, %{table: table, limit: limit, sequence: 0}}
  end

  @impl true
  def put(entry, options) do
    with {:ok, name} <- name(options) do
      GenServer.call(name, {:put, entry})
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Returns retained entries newest first, or `{:error, :unavailable}` during restart."
  @spec list(keyword()) :: {:ok, [Postbeam.SentStore.entry()]} | {:error, term()}
  def list(options \\ []) do
    with {:ok, name} <- name(options) do
      entries =
        name |> :ets.tab2list() |> Enum.sort_by(&elem(&1, 0), :desc) |> Enum.map(&elem(&1, 1))

      {:ok, entries}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def handle_call({:put, entry}, _from, state) do
    sequence = state.sequence + 1

    if sequence > state.limit do
      true = :ets.delete(state.table, sequence - state.limit)
    end

    true = :ets.insert(state.table, {sequence, entry})
    {:reply, :ok, %{state | sequence: sequence}}
  end

  defp name(options) do
    if match?({:ok, _}, Postbeam.Config.keyword(options, :store)) and
         Keyword.keys(options) -- [:name] == [] do
      name = Keyword.get(options, :name, __MODULE__)

      if is_atom(name) and name not in [nil, true, false],
        do: {:ok, name},
        else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp validate(options) do
    with {:ok, options} <- Postbeam.Config.keyword(options, :store),
         {:ok, name} <- name(Keyword.delete(options, :limit)) do
      limit = Keyword.get(options, :limit, 10)
      if is_integer(limit) and limit > 0, do: {:ok, name, limit}, else: {:error, :invalid_options}
    end
  end
end
