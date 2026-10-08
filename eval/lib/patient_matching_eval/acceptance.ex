defmodule PatientMatchingEval.Acceptance do
  @moduledoc "Checks explicit min/max quality targets; cluster size remains diagnostic."

  @doc "Returns target violations for executed runs and golden scenarios, including missing metrics."
  def failures(runs, golden, suite) do
    specs = Map.new(suite["runs"], &{&1["name"], &1})

    run_failures =
      Enum.flat_map(runs, fn run ->
        check(run, Map.get(specs[run.name], "acceptance", %{}), run.name)
      end)

    summary =
      if is_list(golden) do
        failed = Enum.reject(golden, & &1.pass)

        %{
          cases: length(golden),
          failures: length(failed),
          overlay_failures: Enum.count(failed, &(&1.risk == "overlay"))
        }
      end

    run_failures ++ check(%{golden: summary}, Map.get(suite, "acceptance", %{}), "suite")
  end

  defp check(metric, targets, path) when is_map(targets) do
    if Map.has_key?(targets, "min") or Map.has_key?(targets, "max") do
      check_limits(metric, targets, path)
    else
      Enum.flat_map(targets, fn {key, limits} ->
        value =
          if is_map(metric),
            do: Enum.find_value(metric, fn {k, v} -> if to_string(k) == key, do: {:value, v} end)

        check(
          case value do
            {:value, v} -> v
            _ -> nil
          end,
          limits,
          path <> "." <> key
        )
      end)
    end
  end

  defp check(_metric, _targets, path), do: ["#{path}: invalid acceptance target"]

  defp check_limits(metric, limits, path) do
    cond do
      not Enum.all?(limits, fn {key, value} -> key in ["min", "max"] and is_number(value) end) ->
        ["#{path}: invalid min/max limits"]

      not is_number(metric) ->
        ["#{path}: missing or nonnumeric metric"]

      true ->
        Enum.flat_map(limits, fn
          {"min", value} when metric < value -> ["#{path}: #{metric} is below minimum #{value}"]
          {"max", value} when metric > value -> ["#{path}: #{metric} exceeds maximum #{value}"]
          _ -> []
        end)
    end
  end
end
