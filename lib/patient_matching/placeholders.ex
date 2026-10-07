defmodule PatientMatching.Placeholders do
  @moduledoc """
  Values that registration systems enter when the real value is unknown.

  Normalization treats them as missing, so they neither agree nor block:
  two `JOHN DOE` records, or two records with SSN `999-99-9999`, carry no
  evidence of being the same patient. Pass a modified map as the config's
  `:placeholders` option to change the lists, or `%{}` to disable them:

      placeholders = PatientMatching.Placeholders.default()
      config = PatientMatching.Presets.patient_mpi(
        placeholders: Map.update!(placeholders, :family_name, &["NOTGIVEN" | &1])
      )

  Lists hold normalized values: uppercase letters with spaces removed for
  names, digits for identifiers, `%{year:, month:, day:}` for dates.

    * `:given_name`, `:family_name`, `:ssn`, `:phone`, `:zip`, `:dob` -
      values that are always placeholders.
    * `:alias_family_names` - family names that are placeholders only when
      the given name is one too (`TRAUMA ALPHA`, `UNKNOWN MALE`, `JOHN DOE`).
    * `:alias_given_names` - given names that turn a family name from
      `:alias_family_names` into a placeholder, and are then dropped too.

  Structurally invalid identifiers are always missing, whatever the lists say:
  SSNs with area 000 or 666, group 00, serial 0000, or one repeated digit;
  phones whose last seven digits repeat one digit or are 555-1212.
  Newborn labels such as `BABY GIRL A` or `INFANT BOY` are always placeholders.
  """

  @newborn ~r/^(BABY|INFANT|NEWBORN|NB)(GIRL|BOY|G|B)?(TWIN)?[A-D1-4]?$/

  @doc "The default placeholder lists."
  def default do
    %{
      given_name:
        ~w(UNKNOWN UNK NONE NA FNU NOFIRSTNAME NFN TEST PATIENT TRAUMA BB BG BBB BBG GIRL BOY X XX XXX),
      family_name: ~w(UNKNOWN UNK NONE NA LNU NOLASTNAME NLN TEST PATIENT TRAUMA X XX XXX),
      alias_given_names: ~w(JOHN JANE),
      alias_family_names:
        ~w(DOE ROE MALE FEMALE ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIET KILO LIMA MIKE NOVEMBER OSCAR PAPA QUEBEC ROMEO SIERRA TANGO UNIFORM VICTOR WHISKEY XRAY YANKEE ZULU),
      dob: [
        %{year: 1900, month: 1, day: 1},
        %{year: 1901, month: 1, day: 1},
        %{year: 1800, month: 1, day: 1},
        %{year: 1899, month: 12, day: 31}
      ],
      ssn: ~w(123456789 987654321 078051120 219099999),
      phone: ~w(1234567890 0123456789),
      zip: ~w(00000 99999 11111)
    }
  end

  @doc "Validates a placeholder map, resolving `:default`."
  def validate!(:default), do: default()

  def validate!(map) when is_map(map) do
    unless Enum.all?(map, fn {k, v} -> is_atom(k) and is_list(v) end),
      do: raise(ArgumentError, "placeholders must map field atoms to lists of normalized values")

    map
  end

  def validate!(_),
    do: raise(ArgumentError, "placeholders must be :default or a map of field => values")

  @doc "True when a normalized value is a placeholder for the field."
  def placeholder?(_field, nil, _lists), do: false

  def placeholder?(:given_name, value, lists),
    do: Regex.match?(@newborn, value) or listed?(lists, :given_name, value)

  def placeholder?(:ssn, value, lists), do: invalid_ssn?(value) or listed?(lists, :ssn, value)

  def placeholder?(:phone, value, lists),
    do: invalid_phone?(value) or listed?(lists, :phone, value)

  def placeholder?(:zip, value, lists), do: repeated?(value) or listed?(lists, :zip, value)
  def placeholder?(field, value, lists), do: listed?(lists, field, value)

  @doc "True when a given/family pair is an alias such as JOHN DOE or TRAUMA ALPHA."
  def alias?(given, family, lists) do
    given != nil and family in Map.get(lists, :alias_family_names, []) and
      (given in Map.get(lists, :alias_given_names, []) or placeholder?(:given_name, given, lists))
  end

  defp listed?(lists, field, value), do: value in Map.get(lists, field, [])

  defp invalid_ssn?(<<area::binary-3, group::binary-2, serial::binary-4>> = ssn),
    do: area in ["000", "666"] or group == "00" or serial == "0000" or repeated?(ssn)

  defp invalid_ssn?(_), do: false

  defp invalid_phone?(phone) do
    last7 = String.slice(phone, -7, 7)

    repeated?(phone) or repeated?(last7) or last7 == "5551212"
  end

  defp repeated?(<<c, rest::binary>>), do: rest == String.duplicate(<<c>>, byte_size(rest))
  defp repeated?(_), do: false
end
