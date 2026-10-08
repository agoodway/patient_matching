defmodule PatientMatching.Config do
  @moduledoc false
  alias PatientMatching.{Comparison, Guards, Placeholders}

  defstruct comparisons: [],
            blocking: [],
            training_blocking: [],
            link_type: :link_only,
            match_threshold: 0.95,
            review_threshold: 0.20,
            lambda_recall: 0.7,
            u_sample_size: 100_000,
            em_max_iters: 25,
            em_tol: 1.0e-4,
            seed: 1,
            max_block_size: 500,
            training_block_size: 200,
            placeholders: :default,
            strip_mrn_leading_zeros: true,
            common_name_frequency: nil,
            guards: []

  @doc "Builds a config from keywords, applying defaults and validating all options."
  def new(opts \\ []) do
    __MODULE__ |> struct!(opts) |> validate!()
  rescue
    e in KeyError ->
      reraise ArgumentError, [message: "unknown config option #{inspect(e.key)}"], __STACKTRACE__
  end

  @doc "Fields requiring frequencies for TF scoring or the common-name policy."
  def frequency_fields(config) do
    fields =
      config.comparisons
      |> Enum.filter(fn c -> Enum.any?(c.levels, & &1.tf?) end)
      |> Enum.map(& &1.field)

    policy_fields =
      if config.common_name_frequency == nil, do: [], else: [:given_name, :family_name]

    Enum.uniq(fields ++ policy_fields)
  end

  @doc "Validates comparison fields, blocking rules, thresholds, and estimation settings."
  def validate!(%__MODULE__{} = config) do
    validate_comparisons!(config.comparisons)
    thresholds!(config.match_threshold, config.review_threshold)

    unless config.link_type in [:dedupe_only, :link_only],
      do: raise(ArgumentError, "invalid link_type")

    validate_estimation!(config)
    Enum.each([config.blocking, config.training_blocking], &validate_blocking!/1)
    Placeholders.validate!(config.placeholders)
    Guards.validate!(config.guards)

    unless is_boolean(config.strip_mrn_leading_zeros),
      do: raise(ArgumentError, "strip_mrn_leading_zeros must be a boolean")

    unless config.common_name_frequency == nil or
             (is_number(config.common_name_frequency) and config.common_name_frequency > 0 and
                config.common_name_frequency <= 1),
           do: raise(ArgumentError, "common_name_frequency must be nil or in (0, 1]")

    config
  end

  defp validate_comparisons!(comparisons) do
    unless is_list(comparisons), do: raise(ArgumentError, "comparisons must be a list")
    Enum.each(comparisons, &Comparison.validate!/1)
    fields = Enum.map(comparisons, & &1.field)

    unless fields == Enum.uniq(fields),
      do: raise(ArgumentError, "comparison fields must be unique")
  end

  defp validate_estimation!(config) do
    unless is_number(config.lambda_recall) and config.lambda_recall > 0 and
             config.lambda_recall <= 1,
           do: raise(ArgumentError, "lambda_recall must be in (0, 1]")

    Enum.each(
      [
        u_sample_size: config.u_sample_size,
        em_max_iters: config.em_max_iters,
        max_block_size: config.max_block_size,
        training_block_size: config.training_block_size
      ],
      &positive_integer!/1
    )

    unless is_number(config.em_tol) and config.em_tol > 0,
      do: raise(ArgumentError, "em_tol must be positive")

    unless is_integer(config.seed), do: raise(ArgumentError, "seed must be an integer")
  end

  defp positive_integer!({name, value}) do
    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{name} must be a positive integer")
  end

  defp validate_blocking!(rules) do
    unless is_list(rules) and Enum.all?(rules, &valid_rule?/1),
      do:
        raise(
          ArgumentError,
          "blocking rules must be nonempty lists of key atoms or arity-one functions"
        )
  end

  defp valid_rule?(rule),
    do: is_list(rule) and rule != [] and Enum.all?(rule, &(is_atom(&1) or is_function(&1, 1)))

  @doc "Enforces 0 <= review_threshold < match_threshold <= 1."
  def thresholds!(match, review) do
    unless is_number(match) and is_number(review) and review >= 0 and match <= 1 and
             review < match,
           do:
             raise(
               ArgumentError,
               "thresholds require 0 <= review_threshold < match_threshold <= 1"
             )

    :ok
  end
end
