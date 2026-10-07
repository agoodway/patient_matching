defmodule PatientMatchingEval.Reference do
  @moduledoc """
  Loads the static reference and curated tables under `eval/data` into
  sampling-ready structures. Everything is read once per task run.
  """

  @root "eval/data"
  @groups [:hispanic, :white, :black, :api, :aian, :multi]
  @uncovered_factor 0.35

  @doc "Ethnicity groups in the column order used by every reference table."
  def groups, do: @groups

  @doc "Loads all tables. Weighted tables are `{cumulative_weights_tuple, values_tuple, total}`."
  def load(root \\ @root) do
    metro = json!(Path.join([root, "curated", "metro.json"]))
    first_shares = first_name_shares(root)

    %{
      metro: metro,
      sources: json!(Path.join([root, "curated", "sources.json"]))["sources"],
      surnames: surnames(root),
      origin_surnames: origin_surnames(root),
      given: given_names(root, first_shares),
      immigrant_given: immigrant_given(root),
      nicknames: nicknames(root),
      variants: variants(root),
      accents: accents(root),
      streets: metro["streets"]
    }
  end

  @doc "Reads a JSON file with string keys."
  def json!(path), do: path |> File.read!() |> Jason.decode!()

  # Surname | group: weight = count * pct(group). Kept per group for direct sampling.
  defp surnames(root) do
    rows =
      csv(Path.join([root, "reference", "surnames.csv"]))
      |> Enum.map(fn [name, count | pcts] ->
        {name, String.to_integer(count), Enum.map(pcts, &String.to_float/1)}
      end)

    Map.new(Enum.with_index(@groups), fn {group, i} ->
      {group,
       weighted(for {name, count, pcts} <- rows, do: {name, count * Enum.at(pcts, i) / 100})}
    end)
  end

  # P(name | group, sex, cohort) ∝ P(name | sex, cohort) * P(group | name) / P(group).
  # SSA lacks ethnicity; the Tzioumis shares supply it for the names they cover,
  # and uncovered names get a discounted neutral factor.
  defp given_names(root, shares) do
    rows =
      csv(Path.join([root, "reference", "given_names.csv"]))
      |> Enum.map(fn [cohort, sex, name, count] ->
        {String.to_integer(cohort), sex, name, String.to_integer(count)}
      end)

    base = base_rates(shares)

    for {{cohort, sex}, entries} <- Enum.group_by(rows, &{elem(&1, 0), elem(&1, 1)}),
        {group, i} <- Enum.with_index(@groups),
        into: %{} do
      weights =
        for {_, _, name, count} <- entries do
          factor =
            case shares do
              %{^name => {_obs, pcts}} -> Enum.at(pcts, i) / max(Enum.at(base, i), 1.0e-3)
              # The covered list holds most of every group's names, so unknown
              # tail names get a discounted, group-neutral factor.
              _ -> @uncovered_factor
            end

          {name, count * factor}
        end

      {{group, sex, cohort}, weighted(weights)}
    end
  end

  defp first_name_shares(root) do
    Path.join([root, "reference", "first_name_ethnicity.csv"])
    |> csv()
    |> Map.new(fn [name, obs | pcts] ->
      {name, {String.to_integer(obs), Enum.map(pcts, &String.to_float/1)}}
    end)
  end

  # Observation-weighted group shares across the covered names.
  defp base_rates(shares) do
    total = shares |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> max(1)

    shares
    |> Map.values()
    |> Enum.map(fn {obs, pcts} -> Enum.map(pcts, &(&1 * obs)) end)
    |> Enum.zip_with(& &1)
    |> Enum.map(&(Enum.sum(&1) / total))
  end

  # Given names common among foreign-born residents and therefore thin in SSA data.
  defp immigrant_given(root) do
    Path.join([root, "curated", "immigrant_given_names.csv"])
    |> csv()
    |> Enum.group_by(fn [origin, sex, _name, _w] -> {origin, sex} end, fn [_, _, name, w] ->
      {name, String.to_integer(w)}
    end)
    |> Map.new(fn {key, entries} -> {key, weighted(entries)} end)
  end

  defp origin_surnames(root) do
    Path.join([root, "curated", "origin_surnames.csv"])
    |> csv()
    |> Enum.group_by(&hd/1, fn [_, name, w] -> {name, String.to_integer(w)} end)
    |> Map.new(fn {origin, entries} -> {origin, weighted(entries)} end)
  end

  defp accents(root) do
    Path.join([root, "curated", "accents.csv"])
    |> csv()
    |> Map.new(fn [plain, accented] -> {plain, accented} end)
  end

  defp nicknames(root) do
    Path.join([root, "curated", "nicknames.csv"])
    |> csv()
    |> Enum.group_by(&hd/1, &Enum.at(&1, 1))
  end

  defp variants(root) do
    Path.join([root, "curated", "name_variants.csv"])
    |> csv()
    |> Enum.flat_map(fn [_kind | names] -> Enum.map(names, &{&1, names -- [&1]}) end)
    |> Map.new()
  end

  @doc "Builds a cumulative-weight table for O(log n) sampling, dropping non-positive weights."
  def weighted(entries) do
    entries = Enum.filter(entries, fn {_, w} -> w > 0 end)

    {cumulative, total} =
      Enum.map_reduce(entries, 0.0, fn {_, w}, acc -> {acc + w, acc + w} end)

    {List.to_tuple(cumulative), entries |> Enum.map(&elem(&1, 0)) |> List.to_tuple(), total}
  end

  defp csv(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Stream.drop(1)
    |> Enum.map(&String.split(&1, ","))
  end
end
