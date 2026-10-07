defmodule PatientMatching.Blocking do
  @moduledoc false
  require Logger
  alias PatientMatching.{Comparators, Normalize}

  @doc "Normalizes a file and rejects records with missing or duplicate ids."
  def prepare(records) when is_list(records) do
    {_ids, normalized} =
      Enum.reduce(records, {MapSet.new(), []}, fn record, {ids, normalized} ->
        unless is_map(record) and Map.has_key?(record, :id),
          do: raise(ArgumentError, "every record must have :id")

        if MapSet.member?(ids, record.id),
          do: raise(ArgumentError, "duplicate ids in file of #{length(records)} records")

        {MapSet.put(ids, record.id), [Normalize.record(record) | normalized]}
      end)

    Enum.reverse(normalized)
  end

  @doc "Returns unique blocked id pairs from a file or a {left, right} file tuple."
  def pairs(records, rules, link_type, opts \\ []),
    do: candidates(records, rules, link_type, opts).pairs

  @doc "Returns blocked pairs and the number of blocks omitted for exceeding max_block_size."
  def candidates(records, rules, link_type, opts \\ []) do
    prepared =
      case {link_type, records} do
        {:dedupe_only, records} when is_list(records) ->
          prepare(records)

        {:link_only, {left, right}} ->
          {prepare(left), prepare(right)}

        _ ->
          raise ArgumentError, "blocking expects a file for dedupe or {left, right} for linking"
      end

    candidates_prepared(prepared, rules, link_type, opts)
  end

  @doc "Builds candidates from already normalized and validated records."
  def candidates_prepared(records, rules, link_type, opts \\ []) do
    maximum = Keyword.get(opts, :max_block_size, 500)

    {pairs, dropped} =
      rules
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), 0}, fn {rule, rule_index}, acc ->
        records
        |> block_index(rule, link_type)
        |> Enum.reduce(acc, fn block, acc ->
          emit_block(block, acc, rule_index, link_type, maximum)
        end)
      end)

    %{pairs: sort_pairs(MapSet.to_list(pairs)), dropped_blocks: dropped}
  end

  defp block_index(records, rule, :dedupe_only), do: index(records, rule, :single)

  defp block_index({left, right}, rule, :link_only) do
    Map.merge(index(left, rule, :left), index(right, rule, :right), fn _, a, b -> a ++ b end)
  end

  defp emit_block({key, members}, {pairs, dropped}, rule_index, link_type, maximum) do
    count = length(members)

    if maximum != :infinity and count > maximum do
      Logger.warning(
        "patient_matching dropped block hash=#{:erlang.phash2({rule_index, key})} count=#{count}"
      )

      {pairs, dropped + 1}
    else
      pairs = Enum.reduce(block_pairs(members, link_type), pairs, &MapSet.put(&2, &1))
      {pairs, dropped}
    end
  end

  defp block_pairs(members, :dedupe_only), do: combinations(Enum.map(members, &elem(&1, 1)))

  defp block_pairs(members, :link_only) do
    left = for {:left, id} <- members, do: id
    right = for {:right, id} <- members, do: id
    for a <- left, b <- right, a !== b, do: {a, b}
  end

  @doc "Returns source/MRN agreements without enforcing a block-size limit."
  def mrn_pairs(records, link_type) do
    candidates_prepared(records, [[:source, :mrn]], link_type, max_block_size: :infinity).pairs
  end

  @doc "Native term ordering with binary tie-breaks for distinct ids such as 1 and 1.0."
  def sort_key(id), do: {id, :erlang.term_to_binary(id)}

  @doc "Orders pairs by their left and right id sort keys."
  def sort_pairs(pairs), do: Enum.sort_by(pairs, fn {a, b} -> {sort_key(a), sort_key(b)} end)

  @doc "Evaluates a normalized field, derived blocking key, or caller-supplied key function."
  def key(record, function) when is_function(function, 1), do: function.(record)
  def key(record, :family_soundex), do: Comparators.soundex(record.normalized[:family_name])
  def key(record, :dob_year), do: get_in(record.normalized, [:dob, :year])

  def key(record, :given_name3) do
    case record.normalized[:given_name] do
      nil -> nil
      name -> String.slice(name, 0, 3)
    end
  end

  def key(record, :ssn_last4) do
    case record.normalized[:ssn] do
      nil -> nil
      ssn -> String.slice(ssn, -4, 4)
    end
  end

  def key(record, field), do: Map.get(record.normalized, field)

  defp index(records, rule, side) do
    Enum.reduce(records, %{}, fn record, acc ->
      values = Enum.map(rule, &key(record, &1))

      if Enum.any?(values, &is_nil/1),
        do: acc,
        else:
          Map.update(acc, List.to_tuple(values), [{side, record.id}], &[{side, record.id} | &1])
    end)
  end

  defp combinations(ids), do: ids |> Enum.sort_by(&sort_key/1) |> do_combinations()
  defp do_combinations([]), do: []
  defp do_combinations([first | rest]), do: Enum.map(rest, &{first, &1}) ++ do_combinations(rest)
end
