defmodule PatientMatching.Model do
  @moduledoc false
  alias PatientMatching.{Comparison, Config, Normalize}

  defstruct [
    :lambda,
    :config,
    comparisons: [],
    parameters: %{},
    term_frequencies: %{},
    trained: %{}
  ]

  @doc "Serializes parameters, level names/flags, term frequencies and training status; functions are omitted."
  def dump(model) do
    Jason.encode!(%{
      version: 2,
      lambda: model.lambda,
      comparisons: signature(model.comparisons),
      parameters: model.parameters,
      trained: model.trained,
      term_frequencies:
        Map.new(model.term_frequencies, fn {field, frequencies} ->
          {field,
           Enum.map(frequencies, fn {value, frequency} ->
             %{value: value, frequency: frequency}
           end)}
        end)
    })
  end

  @doc "Functions are not serialized. Config must supply the same ordered fields/levels/flags and matchers; no atoms are created from JSON."
  def load(json, config) do
    Config.validate!(config)
    data = Jason.decode!(json)
    validate_header!(data, config)

    %__MODULE__{
      lambda: data["lambda"] * 1.0,
      config: config,
      comparisons: config.comparisons,
      parameters: load_parameters(data["parameters"], config.comparisons),
      term_frequencies: load_frequencies(data["term_frequencies"], config.comparisons),
      trained: load_training(data["trained"])
    }
  rescue
    _error in [
      ArgumentError,
      BadMapError,
      CaseClauseError,
      FunctionClauseError,
      Jason.DecodeError,
      KeyError,
      MatchError,
      Protocol.UndefinedError
    ] ->
      reraise ArgumentError,
              [message: "invalid model dump or incompatible comparison config"],
              __STACKTRACE__
  end

  defp validate_header!(data, config) do
    true = data["version"] == 2
    true = data["comparisons"] == signature(config.comparisons)
    lambda = data["lambda"]
    true = is_number(lambda) and lambda >= 1.0e-9 and lambda <= 0.5
  end

  defp load_parameters(raw, comparisons) do
    true = Enum.sort(Map.keys(raw)) == field_names(comparisons)

    Map.new(comparisons, fn comparison ->
      params =
        raw |> Map.fetch!(Atom.to_string(comparison.field)) |> load_field_parameters(comparison)

      {comparison.field, params}
    end)
  end

  defp load_field_parameters(raw, comparison) do
    levels = Enum.reject(comparison.levels, & &1.null_level?)
    true = Enum.sort(Map.keys(raw)) == Enum.sort(Enum.map(levels, &Atom.to_string(&1.name)))

    params =
      Map.new(levels, fn level ->
        {level.name, raw |> Map.fetch!(Atom.to_string(level.name)) |> load_masses()}
      end)

    true = abs(Enum.sum(Enum.map(params, fn {_, p} -> p.m end)) - 1) < 1.0e-8
    true = abs(Enum.sum(Enum.map(params, fn {_, p} -> p.u end)) - 1) < 1.0e-8
    params
  end

  defp load_masses(values) do
    m = values["m"]
    u = values["u"]
    true = probability?(m) and probability?(u)
    %{m: m * 1.0, u: u * 1.0}
  end

  defp load_frequencies(raw, comparisons) do
    tf_comparisons = Enum.filter(comparisons, fn c -> Enum.any?(c.levels, & &1.tf?) end)
    true = Enum.sort(Map.keys(raw)) == field_names(tf_comparisons)

    Map.new(tf_comparisons, fn comparison ->
      entries = Map.fetch!(raw, Atom.to_string(comparison.field))
      {comparison.field, load_frequency_entries(entries)}
    end)
  end

  defp load_frequency_entries(entries) do
    values =
      Map.new(entries, fn entry ->
        frequency = entry["frequency"]
        true = is_number(frequency) and frequency > 0 and frequency <= 1
        {load_value(entry["value"]), frequency * 1.0}
      end)

    true = map_size(values) == length(entries)
    true = Enum.sum(Map.values(values)) <= 1 + 1.0e-8
    values
  end

  defp load_training(raw) do
    source =
      case raw["lambda_source"] do
        "fixed" -> :fixed
        "deterministic" -> :deterministic
      end

    true = is_boolean(raw["unstable"]) and is_integer(raw["em_iters"]) and raw["em_iters"] >= 0
    true = is_integer(raw["tf_records"]) and raw["tf_records"] > 0
    lambda_train = Map.get(raw, "lambda_train", [])
    true = is_list(lambda_train) and Enum.all?(lambda_train, &probability?/1)

    %{
      lambda_source: source,
      unstable: raw["unstable"],
      em_iters: raw["em_iters"],
      tf_records: raw["tf_records"],
      lambda_train: Enum.map(lambda_train, &(&1 * 1.0))
    }
  end

  defp field_names(comparisons),
    do: comparisons |> Enum.map(&Atom.to_string(&1.field)) |> Enum.sort()

  defp signature(comparisons) do
    Enum.map(comparisons, fn c ->
      %{
        "field" => Atom.to_string(c.field),
        "fields" => Enum.map(Comparison.fields(c), &Atom.to_string/1),
        "levels" =>
          Enum.map(c.levels, fn l ->
            %{"name" => Atom.to_string(l.name), "tf" => l.tf?, "null" => l.null_level?}
          end)
      }
    end)
  end

  defp probability?(p), do: is_number(p) and p >= 1.0e-6 and p <= 1
  defp load_value(value) when is_binary(value), do: value

  defp load_value(%{"year" => y, "month" => m, "day" => d}) do
    date = Normalize.date(%{year: y, month: m, day: d})
    true = date != nil
    date
  end
end
