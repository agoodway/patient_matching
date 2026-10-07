defmodule PatientMatchingEval.Rng do
  @moduledoc """
  Sampling helpers over the process-dictionary `:rand` state. Generation is
  single-process and sequential, so one `seed/1` call makes output reproducible.
  """

  @doc "Seeds the process RNG."
  def seed(seed), do: :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

  @doc "Uniform float in [0, 1)."
  def uniform, do: :rand.uniform()

  @doc "Uniform integer in lo..hi inclusive."
  def int(lo, hi) when hi >= lo, do: lo + :rand.uniform(hi - lo + 1) - 1

  @doc "True with probability p (nil or 0 never fires)."
  def chance?(nil), do: false
  def chance?(p), do: :rand.uniform() < p

  @doc "Uniform element of a non-empty list."
  def pick(list), do: Enum.at(list, :rand.uniform(length(list)) - 1)

  @doc "Samples a key from a map or keyword list of weights."
  def weighted_key(weights) do
    total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    target = :rand.uniform() * total

    Enum.reduce_while(weights, target, fn {key, w}, left ->
      if left < w, do: {:halt, {:found, key}}, else: {:cont, left - w}
    end)
    |> case do
      {:found, key} -> key
      _ -> weights |> Enum.to_list() |> List.last() |> elem(0)
    end
  end

  @doc "Samples from a `Reference.weighted/1` table by binary search."
  def sample({cumulative, values, total}) do
    target = :rand.uniform() * total
    elem(values, search(cumulative, target, 0, tuple_size(cumulative) - 1))
  end

  defp search(_cumulative, _target, lo, hi) when lo >= hi, do: lo

  defp search(cumulative, target, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(cumulative, mid) > target,
      do: search(cumulative, target, lo, mid),
      else: search(cumulative, target, mid + 1, hi)
  end

  @doc "Poisson sample (Knuth); fine for the small means used here."
  def poisson(mean) do
    limit = :math.exp(-mean)
    poisson_step(limit, 1.0, -1)
  end

  defp poisson_step(limit, p, k) when p <= limit, do: k
  defp poisson_step(limit, p, k), do: poisson_step(limit, p * :rand.uniform(), k + 1)

  @doc "Number of extra trials until failure: 0 with probability 1 - p."
  def geometric(p), do: if(chance?(p), do: 1 + geometric(p), else: 0)

  @doc "Normal sample via Box–Muller."
  def normal(mean, sd), do: mean + sd * :rand.normal()

  @doc "Uniform date in the inclusive range."
  def date(%Date{} = from, %Date{} = to) do
    if Date.compare(to, from) == :lt, do: from, else: Date.add(from, int(0, Date.diff(to, from)))
  end
end
