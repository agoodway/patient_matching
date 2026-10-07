defmodule PatientMatching.Assign do
  @moduledoc false
  alias PatientMatching.Blocking

  @doc "Greedily keeps highest-probability pairs while preventing any id from being reused."
  def assign(pairs) do
    {kept, _used} =
      pairs
      |> Enum.sort_by(fn p ->
        {-p.probability, Blocking.sort_key(p.left_id), Blocking.sort_key(p.right_id)}
      end)
      |> Enum.reduce({[], MapSet.new()}, fn pair, {kept, used} ->
        if MapSet.member?(used, pair.left_id) or MapSet.member?(used, pair.right_id) do
          {kept, used}
        else
          {[pair | kept], used |> MapSet.put(pair.left_id) |> MapSet.put(pair.right_id)}
        end
      end)

    Enum.reverse(kept)
  end
end
