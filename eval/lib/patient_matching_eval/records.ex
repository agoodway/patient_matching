defmodule PatientMatchingEval.Records do
  @moduledoc """
  Turns people into per-source MRN snapshots. Each source profile in
  `eval/data/curated/sources.json` sets reach, duplicate-registration rate,
  field formats, capture rates and error rates. Every deviation from the
  person's true current identity is recorded as a tag on the truth row, so
  the runner can slice recall and false matches by cause.
  """
  alias PatientMatchingEval.{Population, Rng}

  @window_start ~D[2012-01-01]

  @doc "Returns `{records, truth}` lists in generation order."
  def build(ref, %{people: people, by_id: by_id}) do
    counters = Map.new(ref.sources, &{&1["id"], 0})

    {rows, _counters} =
      Enum.flat_map_reduce(people, counters, fn person, counters ->
        birth_source = if person.insured, do: "hospital_a", else: "county_hospital"

        ref.sources
        |> Enum.flat_map(&registrations(ref, person, &1, birth_source))
        |> Enum.map_reduce(counters, fn {source, date, opts}, counters ->
          n = counters[source["id"]] + 1
          row = render(ref, person, by_id, source, date, n, opts)
          {row, Map.put(counters, source["id"], n)}
        end)
      end)

    {Enum.map(rows, &elem(&1, 0)), Enum.map(rows, &elem(&1, 1))}
  end

  # Which sources hold an MRN for this person, how many (duplicates), and as of when.
  defp registrations(ref, person, source, birth_source) do
    born = Date.compare(person.dob, @window_start) != :lt
    bin = Population.bin(person.dob)
    use = Enum.at(ref.metro["utilization_by_age_bin"], bin) / 1.4
    reach = source["reach"][if(person.insured, do: "insured", else: "uninsured")] * use
    birth_hospital = source["id"] == birth_source

    cond do
      born and birth_hospital and Rng.chance?(0.9) ->
        # Birth registration (possibly never renamed) plus, usually, a later visit.
        birth = [
          {source, person.dob, newborn: Rng.chance?(source["errors"]["newborn_placeholder"])}
        ]

        later = if Rng.chance?(0.35), do: [{source, visit_date(person), []}], else: []
        birth ++ later

      Rng.chance?(min(reach, 0.95)) ->
        for _ <- 0..Rng.geometric(source["duplicate_rate"]), do: {source, visit_date(person), []}

      true ->
        []
    end
  end

  # An MRN row reflects its last update, which skews recent for active patients.
  defp visit_date(person) do
    from = Enum.max([@window_start, person.dob], Date)
    days_back = round(-:math.log(1 - Rng.uniform()) * 365 * 3.5)
    date = Date.add(Population.today(), -days_back)
    if Date.compare(date, from) == :lt, do: Rng.date(from, Population.today()), else: date
  end

  # -------------------------------------------------------------------- render

  defp render(ref, person, by_id, source, date, n, opts) do
    errors = source["errors"]
    stale = Date.add(date, -Rng.int(0, 365 * (errors["stale_contact_years"] || 0)))
    stale = Enum.max([stale, person.dob], Date)

    ctx = %{
      ref: ref,
      person: person,
      by_id: by_id,
      source: source,
      errors: errors,
      date: date,
      tags: []
    }

    ctx =
      cond do
        Rng.chance?(errors["unknown_patient"]) ->
          unknown_patient(ctx)

        Keyword.get(opts, :newborn, false) ->
          ctx |> newborn() |> demographics(stale) |> drop_newborn_ssn()

        true ->
          ctx |> names() |> demographics(stale)
      end

    mrn =
      source["mrn_prefix"] <> String.pad_leading(Integer.to_string(n * 7 + Rng.int(0, 6)), 8, "0")

    id = source["id"] <> ":" <> mrn

    record =
      ctx.fields
      |> Map.merge(%{"id" => id, "source" => source["id"], "mrn" => mrn})
      |> Map.reject(fn {_, v} -> v == nil end)

    truth = %{
      "id" => id,
      "person_id" => person.pid,
      "source" => source["id"],
      "household" => person.household,
      "group" => to_string(person.group),
      "origin" => person.origin,
      "foreign_born" => person.foreign_born,
      "age" => Population.age(person.dob, date),
      "as_of" => Date.to_iso8601(date),
      "tags" => ctx.tags |> Enum.uniq() |> Enum.sort()
    }

    {record, truth}
  end

  defp tag(ctx, tag), do: %{ctx | tags: [tag | ctx.tags]}

  # ER aliases: no usable identity at all, but the record still belongs to the person.
  defp unknown_patient(ctx) do
    {given, family} =
      Rng.pick([
        {"UNKNOWN", "UNKNOWN"},
        {"JOHN", "DOE"},
        {"JANE", "DOE"},
        {"TRAUMA", Rng.pick(~w(ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT))},
        {"UNKNOWN", "MALE"}
      ])

    est = Date.new!(ctx.person.dob.year + Rng.int(-5, 5), 1, 1)

    fields = %{
      "given_name" => given,
      "family_name" => family,
      "dob" => format_dob(if(Rng.chance?(0.5), do: ~D[1900-01-01], else: est), ctx.source),
      "sex" => format_sex(ctx.person.sex, ctx.source)
    }

    ctx |> Map.put(:fields, fields) |> tag("unknown_patient")
  end

  defp newborn(ctx) do
    p = ctx.person

    label =
      if p.sex == "F",
        do: Rng.pick(["BABY GIRL", "BABYGIRL", "BG", "GIRL"]),
        else: Rng.pick(["BABY BOY", "BABYBOY", "BB", "BOY"])

    family = p.birth_surname_of_mother || Population.legal_surname_at(p, ctx.date)

    tags =
      if family != Population.legal_surname(p),
        do: ["newborn_placeholder", "newborn_mother_surname"],
        else: ["newborn_placeholder"]

    %{ctx | tags: tags ++ ctx.tags}
    |> Map.put(:fields, %{"given_name" => label, "family_name" => family})
  end

  # Newborns have no SSN yet; only a copied guarantor SSN can appear.
  defp drop_newborn_ssn(ctx) do
    if "ssn_guarantor" in ctx.tags,
      do: ctx,
      else: %{
        ctx
        | fields: Map.delete(ctx.fields, "ssn"),
          tags: ["ssn_missing" | ctx.tags -- ["ssn_itin", "ssn_borrowed"]]
      }
  end

  # --------------------------------------------------------------------- names

  defp names(ctx) do
    p = ctx.person
    e = ctx.errors
    family = Population.legal_surname_at(p, ctx.date)

    ctx =
      if family != Population.legal_surname(p), do: tag(ctx, "surname_changed_since"), else: ctx

    {given, ctx} = given_name(ctx, p, e)
    {family, ctx} = family_name(ctx, family, e)
    {given, family, ctx} = maybe_swap(ctx, given, family, e)

    Map.put(ctx, :fields, %{"given_name" => given, "family_name" => family})
  end

  defp given_name(ctx, p, e) do
    {given, ctx} =
      cond do
        p.english_name && Rng.chance?((e["nickname"] || 0) * 3 + 0.05) ->
          {p.english_name, tag(ctx, "english_name")}

        p.middle && Rng.chance?(e["goes_by_middle"]) ->
          {p.middle, tag(ctx, "goes_by_middle")}

        Rng.chance?(e["nickname"]) and Map.has_key?(ctx.ref.nicknames, p.given) ->
          {Rng.pick(ctx.ref.nicknames[p.given]), tag(ctx, "nickname")}

        true ->
          {p.given, ctx}
      end

    {given, ctx} =
      if p.middle && Rng.chance?(e["middle_in_given"]) do
        middle = if Rng.chance?(0.5), do: String.first(p.middle), else: p.middle
        {given <> " " <> middle, tag(ctx, "middle_in_given")}
      else
        {given, ctx}
      end

    {given, ctx}
    |> variant(e)
    |> accent(e)
    |> typo(e, "given")
    |> truncate(e["truncate_given"], "given")
  end

  defp family_name(ctx, family, e) do
    {family, ctx} =
      if String.contains?(family, " ") and
           not String.contains?(family, [
             "DE ",
             "DEL ",
             "DELA ",
             "VAN ",
             "AL ",
             "EL ",
             "ABU ",
             "JEAN "
           ]) and Rng.chance?(e["compound_surname_partial"]) do
        [a, b] = String.split(family, " ", parts: 2)

        {Rng.weighted_key([{a, 0.6}, {a <> "-" <> b, 0.25}, {b, 0.15}]),
         tag(ctx, "compound_surname_partial")}
      else
        {family, ctx}
      end

    {family, ctx} = particle(ctx, family, e)

    {family, ctx} =
      if ctx.person.suffix && Rng.chance?(e["suffix_in_family"]),
        do: {family <> " " <> ctx.person.suffix, tag(ctx, "suffix_in_family")},
        else: {family, ctx}

    {family, ctx}
    |> variant(e)
    |> accent(e)
    |> typo(e, "family")
    |> truncate(e["truncate_family"], "family")
  end

  # Census spells particle surnames joined (DELACRUZ, MCDONALD, OBRIEN); registrars
  # often split them. Spaced forms (DELA CRUZ, AL HAJJ) get joined instead.
  @split_particles %{
    "DELEON" => "DE LEON",
    "DELACRUZ" => "DE LA CRUZ",
    "DELAROSA" => "DE LA ROSA",
    "DELATORRE" => "DE LA TORRE",
    "DELOSSANTOS" => "DE LOS SANTOS",
    "DELAGARZA" => "DE LA GARZA",
    "DELAFUENTE" => "DE LA FUENTE",
    "DELAPAZ" => "DE LA PAZ",
    "DELOSREYES" => "DE LOS REYES",
    "VANDYKE" => "VAN DYKE",
    "STJOHN" => "ST JOHN",
    "STCLAIR" => "ST CLAIR",
    "LAROSA" => "LA ROSA"
  }
  @irish_o ~w(OBRIEN OCONNOR ONEAL ONEIL ONEILL ODONNELL OHARA OROURKE OCONNELL OKEEFE OMALLEY OLEARY)

  defp particle(ctx, family, e) do
    cond do
      not Rng.chance?(e["particle_join"]) ->
        {family, ctx}

      Map.has_key?(@split_particles, family) ->
        {@split_particles[family], tag(ctx, "particle_spacing")}

      String.starts_with?(family, "MC") and String.length(family) > 4 and Rng.chance?(0.4) ->
        {"MC " <> String.slice(family, 2..-1//1), tag(ctx, "particle_spacing")}

      family in @irish_o ->
        {"O'" <> String.slice(family, 1..-1//1), tag(ctx, "apostrophe")}

      Regex.match?(~r/^(DE LA|DE LOS|DELA|DE|DEL|VAN|AL|EL|ABU) \S+$/, family) ->
        {String.replace(family, " ", ""), tag(ctx, "particle_spacing")}

      true ->
        {family, ctx}
    end
  end

  defp maybe_swap(ctx, given, family, e) do
    rate = (e["name_swap"] || 0) + if(ctx.person.name_order_swap, do: 0.15, else: 0)
    if Rng.chance?(rate), do: {family, given, tag(ctx, "name_swap")}, else: {given, family, ctx}
  end

  defp variant({name, ctx}, e) do
    case ctx.ref.variants do
      %{^name => options} ->
        if Rng.chance?(e["variant"] * 4),
          do: {Rng.pick(options), tag(ctx, "spelling_variant")},
          else: {name, ctx}

      _ ->
        {name, ctx}
    end
  end

  defp accent({name, ctx}, e) do
    if Rng.chance?(e["accents"]) do
      accented =
        name |> String.split(" ") |> Enum.map_join(" ", &Map.get(ctx.ref.accents, &1, &1))

      if accented != name, do: {accented, tag(ctx, "accented")}, else: {name, ctx}
    else
      {name, ctx}
    end
  end

  defp truncate({name, ctx}, nil, _field), do: {name, ctx}

  defp truncate({name, ctx}, width, field) do
    if String.length(name) > width,
      do: {String.slice(name, 0, width), tag(ctx, "truncated_#{field}")},
      else: {name, ctx}
  end

  defp typo({name, ctx}, e, field) do
    if Rng.chance?(e["name_typo"]) and String.length(name) >= 3,
      do: {keyboard_typo(name), tag(ctx, "typo_#{field}")},
      else: {name, ctx}
  end

  @adjacent %{
    "A" => "QSZW",
    "B" => "VGHN",
    "C" => "XDFV",
    "D" => "SERFCX",
    "E" => "WSDR",
    "F" => "DRTGVC",
    "G" => "FTYHBV",
    "H" => "GYUJNB",
    "I" => "UJKO",
    "J" => "HUIKMN",
    "K" => "JIOLM",
    "L" => "KOP",
    "M" => "NJK",
    "N" => "BHJM",
    "O" => "IKLP",
    "P" => "OL",
    "Q" => "WA",
    "R" => "EDFT",
    "S" => "AWEDXZ",
    "T" => "RFGY",
    "U" => "YHJI",
    "V" => "CFGB",
    "W" => "QASE",
    "X" => "ZSDC",
    "Y" => "TGHU",
    "Z" => "ASX"
  }

  # One edit, rarely on the first character (registration errors cluster later in the word).
  @doc false
  def keyboard_typo(name) do
    chars = String.graphemes(name)
    len = length(chars)
    i = if Rng.chance?(0.1), do: 0, else: Rng.int(1, len - 1)
    c = Enum.at(chars, i)

    case Rng.weighted_key(substitute: 0.4, delete: 0.2, double: 0.15, transpose: 0.25) do
      :substitute ->
        List.replace_at(chars, i, (@adjacent[c] || c) |> String.graphemes() |> Rng.pick())

      :delete ->
        List.delete_at(chars, i)

      :double ->
        List.insert_at(chars, i, c)

      :transpose when i < len - 1 ->
        chars |> List.replace_at(i, Enum.at(chars, i + 1)) |> List.replace_at(i + 1, c)

      :transpose ->
        chars |> List.replace_at(i, Enum.at(chars, i - 1)) |> List.replace_at(i - 1, c)
    end
    |> Enum.join()
  end

  # -------------------------------------------------------------- demographics

  defp demographics(ctx, stale) do
    ctx |> dob() |> sex() |> address(stale) |> phone(stale) |> ssn()
  end

  defp dob(ctx) do
    e = ctx.errors
    d = ctx.person.dob
    ctx = if ctx.person.jan1_dob, do: tag(ctx, "jan1_dob"), else: ctx

    {d, ctx} =
      cond do
        Rng.chance?(e["dob_placeholder"]) ->
          {~D[1900-01-01], tag(ctx, "dob_placeholder")}

        Rng.chance?(e["dob_year_only"]) ->
          {Date.new!(d.year, 1, 1), tag(ctx, "dob_estimated_jan1")}

        Rng.chance?(e["dob_off_by_one_day"]) ->
          {Date.add(d, Rng.pick([-1, 1])), tag(ctx, "dob_off_by_one_day")}

        Rng.chance?(e["dob_day_month_swap"]) and d.day <= 12 and d.day != d.month ->
          {Date.new!(d.year, d.day, d.month), tag(ctx, "dob_day_month_swap")}

        Rng.chance?(e["dob_typo"]) ->
          dob_typo(ctx, d)

        true ->
          {d, ctx}
      end

    fmt = Rng.weighted_key(ctx.source["formats"]["dob"])

    ctx =
      if fmt in ~w(mdy_nopad compact dmy mdy_dash), do: tag(ctx, "dob_format_#{fmt}"), else: ctx

    put(ctx, "dob", format_dob(d, fmt))
  end

  defp dob_typo(ctx, d) do
    candidate =
      case Rng.pick([:year_digit, :decade_swap, :month_digit, :day_digit]) do
        :year_digit ->
          Date.new(d.year + Rng.pick([-1, 1]), d.month, d.day)

        :decade_swap ->
          Date.new(swap_year_digits(d.year), d.month, d.day)

        :month_digit ->
          Date.new(d.year, rem(d.month + Rng.pick([0, 1, 9, 10]), 12) + 1, d.day)

        :day_digit ->
          Date.new(
            d.year,
            d.month,
            Rng.pick(
              Enum.reject(
                [rem(d.day, 10) + 10, rem(d.day, 10) + 20, d.day + 10, d.day - 10],
                &(&1 < 1 or &1 > 28)
              )
            )
          )
      end

    case candidate do
      {:ok, new} when new != d -> {new, tag(ctx, "dob_typo")}
      _ -> {d, ctx}
    end
  end

  defp swap_year_digits(year) do
    [a, b, c, d] = year |> Integer.to_string() |> String.graphemes()
    swapped = String.to_integer(a <> b <> d <> c)
    if swapped > Population.today().year, do: year + 10, else: swapped
  end

  defp sex(ctx) do
    e = ctx.errors

    cond do
      not Rng.chance?(ctx.source["capture"]["sex"]) ->
        tag(ctx, "sex_missing")

      Rng.chance?(e["sex_error"]) ->
        ctx
        |> put("sex", format_sex(if(ctx.person.sex == "M", do: "F", else: "M"), ctx.source))
        |> tag("sex_error")

      true ->
        coded = format_sex(ctx.person.sex, ctx.source)
        ctx = if coded in ["U", "UNKNOWN", "0"], do: tag(ctx, "sex_unknown_code"), else: ctx

        if coded in ["1", "2"],
          do: tag(put(ctx, "sex", coded), "sex_numeric_code"),
          else: put(ctx, "sex", coded)
    end
  end

  defp address(ctx, stale) do
    current = Population.at(ctx.person.addresses, Population.today())
    past = Population.at(ctx.person.addresses, stale)
    ctx = if past.zip != current.zip, do: tag(ctx, "zip_stale"), else: ctx

    cond do
      not Rng.chance?(ctx.source["capture"]["zip"]) ->
        tag(ctx, "zip_missing")

      Rng.chance?(ctx.errors["zip_typo"]) ->
        zip =
          String.slice(past.zip, 0, 3) <>
            Integer.to_string(Rng.int(0, 9)) <> String.slice(past.zip, 4, 1)

        ctx |> put("zip", zip) |> put("street", past.street) |> tag("zip_typo")

      true ->
        fmt = Rng.weighted_key(ctx.source["formats"]["zip"])
        plus4 = String.pad_leading(Integer.to_string(Rng.int(1, 9999)), 4, "0")

        zip =
          case fmt do
            "plus4" -> past.zip <> "-" <> plus4
            "nine" -> past.zip <> plus4
            _ -> past.zip
          end

        street = if Rng.chance?(ctx.source["capture"]["street"]), do: street_variant(past.street)
        ctx |> put("zip", zip) |> put("street", street)
    end
  end

  defp street_variant(street) do
    if Rng.chance?(0.3),
      do:
        street
        |> String.replace(" APT ", " # ")
        |> String.replace(" RD", " ROAD")
        |> String.replace(" ST", " STREET")
        |> String.replace(" DR", " DRIVE"),
      else: street
  end

  # Minors give a parent's number; adults sometimes give the household landline or a work line.
  defp phone(ctx, stale) do
    p = ctx.person
    e = ctx.errors
    own = Population.at(p.cells, stale)
    current = Population.at(p.cells, Population.today())

    parent =
      Enum.find_value([p.mother, p.father], fn id ->
        id && ctx.by_id[id] && Population.at(ctx.by_id[id].cells, stale)
      end)

    {number, ctx} =
      cond do
        own == nil and parent ->
          {parent, tag(ctx, "phone_of_parent")}

        own == nil and p.landline ->
          {p.landline, tag(ctx, "phone_household")}

        p.landline && Rng.chance?(e["household_phone"]) ->
          {p.landline, tag(ctx, "phone_household")}

        Rng.chance?(e["phone_work"]) ->
          {Population.phone_number(["713", "281", "832"]), tag(ctx, "phone_work")}

        own != current and own != nil ->
          {own, tag(ctx, "phone_stale")}

        true ->
          {own, ctx}
      end

    cond do
      number == nil or not Rng.chance?(ctx.source["capture"]["phone"]) ->
        tag(ctx, "phone_missing")

      Rng.chance?(e["phone_placeholder"]) ->
        ctx
        |> put(
          "phone",
          Rng.pick(["0000000000", "9999999999", "7130000000", "1234567890", "713-555-1212"])
        )
        |> tag("phone_placeholder")

      true ->
        {number, ctx} =
          if Rng.chance?(e["phone_typo"]),
            do: {digit_typo(number), tag(ctx, "phone_typo")},
            else: {number, ctx}

        fmt = Rng.weighted_key(ctx.source["formats"]["phone"])
        ctx = if fmt in ~w(e164 one_prefix), do: tag(ctx, "phone_country_code"), else: ctx
        put(ctx, "phone", format_phone(number, fmt))
    end
  end

  defp ssn(ctx) do
    p = ctx.person
    e = ctx.errors
    minor = Population.age(p.dob, ctx.date) < 18

    guarantor =
      Enum.find_value([p.mother, p.father], fn id ->
        with true <- id != nil, %{ssn: {:ssn, v}} <- ctx.by_id[id], do: v, else: (_ -> nil)
      end)

    {value, ctx} =
      cond do
        (minor and guarantor) && Rng.chance?(e["ssn_guarantor_minor"]) ->
          {guarantor, tag(ctx, "ssn_guarantor")}

        not Rng.chance?(ctx.source["capture"]["ssn"]) ->
          {nil, tag(ctx, "ssn_missing")}

        Rng.chance?(e["ssn_placeholder"]) ->
          {Rng.pick(["000000000", "999999999", "123456789", "111111111", "888888888"]),
           tag(ctx, "ssn_placeholder")}

        true ->
          person_ssn(ctx, p.ssn)
      end

    {value, ctx} =
      if value && Rng.chance?(e["ssn_typo"]),
        do: {digit_typo(value), tag(ctx, "ssn_typo")},
        else: {value, ctx}

    if value do
      fmt = Rng.weighted_key(ctx.source["formats"]["ssn"])
      ctx = if fmt in ~w(last4 masked_last4), do: tag(ctx, "ssn_last4_only"), else: ctx
      put(ctx, "ssn", format_ssn(value, fmt))
    else
      ctx
    end
  end

  defp person_ssn(ctx, {:ssn, v}), do: {v, ctx}
  defp person_ssn(ctx, {:itin, v}), do: {v, tag(ctx, "ssn_itin")}
  defp person_ssn(ctx, {:borrowed, v}), do: {v, tag(ctx, "ssn_borrowed")}
  defp person_ssn(ctx, {:none, _}), do: {nil, tag(ctx, "ssn_none")}

  defp digit_typo(digits) do
    chars = String.graphemes(digits)
    i = Rng.int(0, length(chars) - 1)

    if Rng.chance?(0.5) and i < length(chars) - 1,
      do:
        chars
        |> List.replace_at(i, Enum.at(chars, i + 1))
        |> List.replace_at(i + 1, Enum.at(chars, i))
        |> Enum.join(),
      else: chars |> List.replace_at(i, Integer.to_string(Rng.int(0, 9))) |> Enum.join()
  end

  # ------------------------------------------------------------------- formats

  defp format_dob(d, %{} = source), do: format_dob(d, Rng.weighted_key(source["formats"]["dob"]))

  defp format_dob(d, fmt) do
    {y, m, dd} = {Integer.to_string(d.year), pad2(d.month), pad2(d.day)}

    case fmt do
      "iso" -> "#{y}-#{m}-#{dd}"
      "mdy" -> "#{m}/#{dd}/#{y}"
      "mdy_nopad" -> "#{d.month}/#{d.day}/#{y}"
      "compact" -> "#{y}#{m}#{dd}"
      "dmy" -> "#{dd}/#{m}/#{y}"
      "mdy_dash" -> "#{m}-#{dd}-#{y}"
    end
  end

  defp format_sex(sex, source) do
    case Rng.weighted_key(source["formats"]["sex"]) do
      "mf" -> sex
      "word" -> if sex == "M", do: "MALE", else: "FEMALE"
      "word_mixed" -> if sex == "M", do: "Male", else: "Female"
      "numeric" -> if sex == "M", do: "1", else: "2"
      "unknown_code" -> "U"
    end
  end

  defp format_phone(n, fmt) do
    {a, b, c} = {String.slice(n, 0, 3), String.slice(n, 3, 3), String.slice(n, 6, 4)}

    case fmt do
      "digits" -> n
      "dashed" -> "#{a}-#{b}-#{c}"
      "paren" -> "(#{a}) #{b}-#{c}"
      "dotted" -> "#{a}.#{b}.#{c}"
      "e164" -> "+1#{n}"
      "one_prefix" -> "1#{n}"
    end
  end

  defp format_ssn(v, fmt) do
    case fmt do
      "digits" -> v
      "dashed" -> "#{String.slice(v, 0, 3)}-#{String.slice(v, 3, 2)}-#{String.slice(v, 5, 4)}"
      "last4" -> String.slice(v, -4, 4)
      "masked_last4" -> "XXX-XX-" <> String.slice(v, -4, 4)
    end
  end

  defp put(ctx, key, value),
    do: Map.update(ctx, :fields, %{key => value}, &Map.put(&1, key, value))

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
