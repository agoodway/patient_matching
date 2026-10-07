defmodule PatientMatchingEval.Dataset do
  @moduledoc """
  Loads a generated population: matcher-facing records (atom keys, exactly the
  fields the library accepts) plus the ground truth that never reaches the matcher.
  """

  @fields Map.new(
            ~w(id source mrn given_name family_name dob sex zip phone ssn street)a,
            &{Atom.to_string(&1), &1}
          )

  defstruct records: [], truth: %{}, people: %{}

  @doc "Reads records.jsonl, truth.jsonl and people.jsonl from a population directory."
  def load(dir) do
    unless File.exists?(Path.join(dir, "records.jsonl")),
      do: Mix.raise("no population in #{dir}; run `mix eval.gen` first")

    records =
      Path.join(dir, "records.jsonl")
      |> jsonl()
      |> Enum.map(fn row ->
        row |> Map.take(Map.keys(@fields)) |> Map.new(fn {k, v} -> {@fields[k], v} end)
      end)

    truth = dir |> Path.join("truth.jsonl") |> jsonl() |> Map.new(&{&1["id"], &1})
    people = dir |> Path.join("people.jsonl") |> jsonl() |> Map.new(&{&1["person_id"], &1})
    %__MODULE__{records: records, truth: truth, people: people}
  end

  @doc "Records whose source is in the list (or every record for \"all\")."
  def from_sources(%__MODULE__{records: records}, "all"), do: records

  def from_sources(%__MODULE__{records: records}, sources),
    do: Enum.filter(records, &(&1.source in sources))

  @doc "Person id for a record id."
  def person(%__MODULE__{truth: truth}, id), do: truth[id]["person_id"]

  @doc "Unordered within-file true pairs, as `{min_id, max_id}` under Erlang term order."
  def true_pairs_dedupe(dataset, records) do
    records
    |> Enum.group_by(&person(dataset, &1.id), & &1.id)
    |> Enum.flat_map(fn {_, ids} -> combinations(Enum.sort(ids)) end)
    |> MapSet.new()
  end

  @doc "Cross-file true pairs `{left_id, right_id}`."
  def true_pairs_link(dataset, left, right) do
    right_by_person = Enum.group_by(right, &person(dataset, &1.id), & &1.id)

    for l <- left,
        r_id <- Map.get(right_by_person, person(dataset, l.id), []),
        into: MapSet.new() do
      {l.id, r_id}
    end
  end

  @doc "Normalizes a pair to the orientation used by `true_pairs_*`."
  def key(:dedupe, {a, b}), do: if(a <= b, do: {a, b}, else: {b, a})
  def key(:link, pair), do: pair

  defp combinations([]), do: []
  defp combinations([h | t]), do: Enum.map(t, &{h, &1}) ++ combinations(t)

  defp jsonl(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)
end
