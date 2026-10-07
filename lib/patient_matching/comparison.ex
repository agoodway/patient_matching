defmodule PatientMatching.Comparison do
  @moduledoc false
  alias PatientMatching.{Comparators, Level}
  defstruct [:field, :levels, fields: nil]

  @doc "Normalized fields a comparison reads: its `fields` list, or just its `field`."
  def fields(%__MODULE__{fields: nil, field: field}), do: [field]
  def fields(%__MODULE__{fields: fields}), do: fields

  @doc """
  The value a comparison's matchers receive: the field's normalized value, or
  a tuple of the `fields` values (nil when all of them are nil).
  """
  def value(%__MODULE__{fields: nil, field: field}, record), do: Map.get(record.normalized, field)

  def value(%__MODULE__{fields: fields}, record) do
    values = Enum.map(fields, &Map.get(record.normalized, &1))
    if Enum.all?(values, &is_nil/1), do: nil, else: List.to_tuple(values)
  end

  @doc "Selects the first winning level; null and else semantics override their predicates."
  def run(%__MODULE__{levels: levels} = comparison, left, right) do
    a = value(comparison, left)
    b = value(comparison, right)

    if a == nil or b == nil do
      hd(levels)
    else
      Enum.find(levels, fn level ->
        not level.null_level? and (level.name == :else or level.match?.(a, b))
      end)
    end
  end

  @doc "Rejects malformed levels, invalid null/else ordering, or non-equality TF matchers."
  def validate!(%__MODULE__{field: field, levels: levels, fields: fields})
      when is_atom(field) and not is_nil(field) and is_list(levels) and length(levels) >= 2 do
    validate_fields!(fields, levels)
    validate_shapes!(levels)
    validate_names!(levels)
    validate_boundaries!(levels)
    Enum.each(levels, &validate_level!/1)
    :ok
  end

  def validate!(_),
    do: raise(ArgumentError, "comparison requires a field and at least null/else levels")

  defp validate_fields!(nil, _levels), do: :ok

  defp validate_fields!(fields, levels) do
    unless is_list(fields) and fields != [] and Enum.all?(fields, &is_atom/1),
      do: raise(ArgumentError, "comparison fields must be nil or a nonempty list of atoms")

    if Enum.any?(levels, &(is_struct(&1, Level) and &1.tf?)),
      do: raise(ArgumentError, "TF requires a single-field comparison")
  end

  defp validate_shapes!(levels) do
    unless Enum.all?(levels, fn level ->
             is_struct(level, Level) and is_boolean(level.tf?) and is_boolean(level.null_level?)
           end),
           do: raise(ArgumentError, "levels must be Level structs with boolean flags")
  end

  defp validate_names!(levels) do
    names = Enum.map(levels, & &1.name)

    unless Enum.uniq(names) == names and Enum.all?(names, &(is_atom(&1) and not is_nil(&1))),
      do: raise(ArgumentError, "comparison levels require unique non-nil atom names")
  end

  defp validate_boundaries!(levels) do
    unless hd(levels).null_level? and Enum.count(levels, & &1.null_level?) == 1,
      do: raise(ArgumentError, "comparison requires one first null level")

    last = List.last(levels)

    unless last.name == :else and not last.null_level?,
      do: raise(ArgumentError, "comparison requires a last non-null :else level")
  end

  defp validate_level!(%Level{tf?: true} = level) do
    unless equality_matcher?(level) and not level.null_level? and level.name != :else,
      do:
        raise(
          ArgumentError,
          "TF requires the exact equality matcher on a non-null agreement level"
        )
  end

  defp validate_level!(%Level{null_level?: true}), do: :ok
  defp validate_level!(%Level{name: :else}), do: :ok
  defp validate_level!(%Level{match?: matcher}) when is_function(matcher, 2), do: :ok
  defp validate_level!(_), do: raise(ArgumentError, "comparison requires arity-two matchers")

  @doc "Certifies TF equality using the canonical exact comparison function capture."
  def equality_matcher?(%Level{match?: matcher}), do: matcher == (&Comparators.exact?/2)

  @doc "Recognizes canonical or reserved-name exact levels for training stability, excluding null/else."
  def exact_style?(%Level{null_level?: true}), do: false
  def exact_style?(%Level{name: :else}), do: false

  def exact_style?(%Level{} = level),
    do: equality_matcher?(level) or level.name in [:exact, :dob_exact]
end
