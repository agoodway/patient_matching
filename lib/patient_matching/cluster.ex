defmodule PatientMatching.Cluster do
  @moduledoc false
  alias PatientMatching.Blocking

  @max_checks 10_000

  @doc "Union-find on match edges. Only connected records are returned; singleton records are omitted."
  def clusters(pairs) do
    {parents, _ranks} = Enum.reduce(pairs, {%{}, %{}}, &union/2)
    groups(parents)
  end

  @doc """
  Union-find that refuses to join two clusters when `conflict?.(id_a, id_b)`
  holds for any pair of their members. Edges are taken by descending
  probability, so the strongest links form clusters first. Returns
  `{clusters, rejected_edges}`. Joins needing more than #{@max_checks}
  member checks are rejected too: chains that long are themselves suspect.
  """
  def guarded(pairs, conflict?) do
    {parents, _ranks, _members, rejected} =
      pairs
      |> Enum.sort_by(fn p ->
        {-p.probability, Blocking.sort_key(p.left_id), Blocking.sort_key(p.right_id)}
      end)
      |> Enum.reduce({%{}, %{}, %{}, []}, fn pair, {parents, ranks, members, rejected} ->
        a = pair.left_id
        b = pair.right_id
        parents = parents |> Map.put_new(a, a) |> Map.put_new(b, b)
        {ra, parents} = find(a, parents)
        {rb, parents} = find(b, parents)
        ma = Map.get(members, ra, [ra])
        mb = Map.get(members, rb, [rb])

        cond do
          ra === rb ->
            {parents, ranks, members, rejected}

          length(ma) * length(mb) > @max_checks or
              Enum.any?(ma, fn x -> Enum.any?(mb, &conflict?.(x, &1)) end) ->
            {parents, ranks, members, [pair | rejected]}

          true ->
            {parents, ranks} = merge_roots(ra, rb, parents, ranks)
            {root, parents} = find(ra, parents)
            members = members |> Map.drop([ra, rb]) |> Map.put(root, ma ++ mb)
            {parents, ranks, members, rejected}
        end
      end)

    {groups(parents), Enum.reverse(rejected)}
  end

  defp groups(parents) do
    {groups, _parents} =
      Enum.reduce(Map.keys(parents), {%{}, parents}, fn id, {groups, parents} ->
        {root, parents} = find(id, parents)
        {Map.update(groups, root, [id], &[id | &1]), parents}
      end)

    groups
    |> Map.values()
    |> Enum.reject(&match?([_], &1))
    |> Enum.map(fn ids ->
      members = Enum.sort_by(ids, &Blocking.sort_key/1)
      %{root_id: hd(members), member_ids: members}
    end)
    |> Enum.sort_by(&Blocking.sort_key(&1.root_id))
  end

  defp union(pair, {parents, ranks}) do
    a = pair.left_id
    b = pair.right_id
    parents = parents |> Map.put_new(a, a) |> Map.put_new(b, b)
    {ra, parents} = find(a, parents)
    {rb, parents} = find(b, parents)
    merge_roots(ra, rb, parents, ranks)
  end

  defp merge_roots(ra, rb, parents, ranks) when ra === rb, do: {parents, ranks}

  defp merge_roots(ra, rb, parents, ranks) do
    rank_a = Map.get(ranks, ra, 0)
    rank_b = Map.get(ranks, rb, 0)

    cond do
      rank_a > rank_b -> {Map.put(parents, rb, ra), ranks}
      rank_b > rank_a -> {Map.put(parents, ra, rb), ranks}
      true -> {Map.put(parents, rb, ra), Map.put(ranks, ra, rank_a + 1)}
    end
  end

  defp find(id, parents) do
    parent = Map.fetch!(parents, id)

    if parent === id do
      {id, parents}
    else
      {root, parents} = find(parent, parents)
      {root, Map.put(parents, id, root)}
    end
  end
end
