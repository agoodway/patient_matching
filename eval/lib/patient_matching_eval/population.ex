defmodule PatientMatchingEval.Population do
  @moduledoc """
  Builds synthetic people grouped into households, with the life events that
  make real-world matching hard: marriage name changes, moves, phone churn,
  twins, juniors, compound Hispanic surnames, Jan-1 immigrant birthdays,
  ITINs and borrowed SSNs.

  A person is a plain map. Time-varying attributes are histories of
  `{effective_date, value}` sorted ascending; `at/2` resolves them.
  """
  alias PatientMatchingEval.Rng

  @today ~D[2026-09-30]

  @doc "Reference date for ages and history windows."
  def today, do: @today

  @doc "Generates at least `target` people, or exactly `target` with `exact: true`, retaining only modeled relationships."
  def build(ref, target, opts \\ []) do
    {people, _next} = households(ref, target, [], 1, 1)
    people = Enum.reverse(people)
    people = if opts[:exact], do: limit_people(people, target), else: people
    people = assign_borrowed_ssns(ref, people)
    %{people: people, by_id: Map.new(people, &{&1.pid, &1})}
  end

  defp limit_people(people, target) do
    people = Enum.take(people, target)
    ids = MapSet.new(people, & &1.pid)
    household_sizes = Enum.frequencies_by(people, & &1.household)

    Enum.map(people, fn person ->
      Enum.reduce([:mother, :father, :spouse, :twin, :junior_of], person, fn role, acc ->
        if acc[role] && not MapSet.member?(ids, acc[role]), do: Map.put(acc, role, nil), else: acc
      end)
      |> Map.put(:household_size, household_sizes[person.household])
    end)
  end

  @doc "Resolves a `{date, value}` history at a date, falling back to the earliest value."
  def at([{_, first} | _] = history, date) do
    Enum.reduce_while(history, first, fn {from, value}, acc ->
      if Date.compare(from, date) == :gt, do: {:halt, acc}, else: {:cont, value}
    end)
  end

  @doc "Age in whole years at a date."
  def age(%Date{} = dob, %Date{} = on) do
    years = on.year - dob.year
    if {on.month, on.day} < {dob.month, dob.day}, do: years - 1, else: years
  end

  defp households(_ref, target, acc, pid, _hid) when pid > target, do: {acc, pid}

  defp households(ref, target, acc, pid, hid) do
    {members, next_pid} = household(ref, pid, hid)
    households(ref, target, Enum.reverse(members) ++ acc, next_pid, hid + 1)
  end

  # ---------------------------------------------------------------- households

  defp household(ref, pid, hid) do
    metro = ref.metro
    # Group shares are per person, so households are drawn at share / mean size.
    group =
      metro["group_shares"]
      |> atomize()
      |> Enum.map(fn {g, share} -> {g, share / metro["household_size_mean"][to_string(g)]} end)
      |> Rng.weighted_key()

    renter = Rng.chance?(metro["renter_rate"][to_string(group)])
    addresses = address_history(ref, group, renter)
    head = person(ref, pid, hid, group, sex: Rng.pick(["M", "F"]), min_age: 19, headship: true)
    head_age = age(head.dob, @today)
    mean = metro["household_size_mean"][to_string(group)]
    # Older householders are mostly empty-nesters.
    mean = if head_age >= 60, do: 1.7, else: mean + 0.3
    size = max(1, 1 + Rng.poisson(mean - 1)) |> min(9)
    {members, pid} = {[head], pid + 1}

    {members, pid} =
      if size >= 2 and Rng.chance?(0.62) and age(head.dob, @today) in 21..85,
        do: add_spouse(ref, members, pid, hid),
        else: {members, pid}

    {members, pid} = add_children(ref, members, pid, hid, size - length(members))

    {members, pid} =
      if Rng.chance?(0.12) and age(head.dob, @today) in 25..60,
        do: add_elder(ref, members, pid, hid),
        else: {members, pid}

    landline =
      if Rng.chance?(Enum.at(metro["landline_rate_by_age_bin"], bin(head.dob))),
        do: phone_number(metro["area_codes"]["landline"]),
        else: nil

    members =
      Enum.map(members, fn p ->
        p
        |> Map.put(:addresses, addresses)
        |> Map.put(:landline, landline)
        |> Map.put(:household_size, length(members))
      end)

    {members, pid}
  end

  defp add_spouse(ref, [head | _] = members, pid, hid) do
    group =
      if Rng.chance?(ref.metro["intermarriage_rate"]),
        do: Rng.weighted_key(atomize(ref.metro["group_shares"])),
        else: head.group

    sex = if Rng.chance?(0.96), do: other_sex(head.sex), else: head.sex
    dob = Date.add(head.dob, round(Rng.normal(0, 4) * 365))

    dob =
      if Date.compare(dob, Date.add(@today, -19 * 365)) == :gt,
        do: Date.add(@today, -19 * 365),
        else: dob

    same = group == head.group

    spouse =
      person(ref, pid, hid, group,
        sex: sex,
        dob: dob,
        origin: if(same, do: head.origin),
        foreign_born: head.foreign_born and same
      )

    marriage = marriage_date(head, spouse)
    {head, spouse} = marry(ref, head, spouse, marriage)
    head = Map.put(head, :spouse, spouse.pid)
    spouse = Map.put(spouse, :spouse, head.pid)
    {[head, spouse | tl(members)], pid + 1}
  end

  defp marriage_date(a, b) do
    older_adult = Date.add(Enum.max([a.dob, b.dob], Date), 21 * 365)
    Rng.date(older_adult, Date.add(@today, -30))
  end

  # The wife (or, rarely, either partner) takes or hyphenates the other's surname.
  defp marry(ref, head, spouse, date) do
    {husband, wife, swap?} =
      cond do
        head.sex == "M" and spouse.sex == "F" -> {head, spouse, false}
        head.sex == "F" and spouse.sex == "M" -> {spouse, head, true}
        true -> {head, spouse, false}
      end

    takes = ref.metro["takes_spouse_surname"][to_string(wife.group)]

    wife =
      cond do
        wife.foreign_born and
            wife.origin in ~w(mexican central_american other_hispanic vietnamese chinese korean) ->
          wife

        Rng.chance?(ref.metro["hyphenates_surname"]) ->
          change_surname(
            wife,
            date,
            birth_surname(wife) <> "-" <> legal_surname(husband),
            "hyphenated_married"
          )

        Rng.chance?(takes) ->
          change_surname(wife, date, legal_surname(husband), "married")

        true ->
          wife
      end

    if swap?, do: {wife, husband}, else: {husband, wife}
  end

  defp change_surname(person, date, surname, kind) do
    %{
      person
      | surnames: person.surnames ++ [{date, surname}],
        name_events: [kind | person.name_events]
    }
  end

  defp add_children(_ref, members, pid, _hid, n) when n <= 0, do: {members, pid}

  defp add_children(ref, [head | _] = members, pid, hid, n) do
    mother = Enum.find(members, &(&1.sex == "F"))
    father = Enum.find(members, &(&1.sex == "M"))
    youngest_parent_age = members |> Enum.map(&age(&1.dob, @today)) |> Enum.min()

    {kids, pid} =
      Enum.reduce(1..n, {[], pid}, fn _, {kids, pid} ->
        age = Rng.int(max(0, youngest_parent_age - 42), max(0, youngest_parent_age - 17))
        dob = Rng.date(Date.add(@today, -(age + 1) * 365 + 1), Date.add(@today, -age * 365))
        dob = if Date.compare(dob, @today) == :gt, do: @today, else: dob
        child = child(ref, pid, hid, head, mother, father, dob)

        if Rng.chance?(ref.metro["twin_rate"]) and length(kids) + 1 < n do
          twin = child(ref, pid + 1, hid, head, mother, father, child.dob) |> twin_name(child)
          twin = %{twin | dob: child.dob, jan1_dob: child.jan1_dob, surnames: child.surnames}
          {[%{twin | twin: child.pid}, %{child | twin: twin.pid} | kids], pid + 2}
        else
          {[child | kids], pid + 1}
        end
      end)

    {members ++ Enum.reverse(kids), pid}
  end

  defp child(ref, pid, hid, head, mother, father, dob) do
    group =
      Rng.pick([
        head.group | Enum.map([mother, father], &(&1 && &1.group)) |> Enum.reject(&is_nil/1)
      ])

    sex = Rng.pick(["M", "F"])
    parent = father || mother
    foreign_born = head.foreign_born and age(dob, @today) > 12 and Rng.chance?(0.5)

    kid =
      person(ref, pid, hid, group,
        sex: sex,
        dob: dob,
        origin: parent.origin,
        foreign_born: foreign_born
      )

    surname = child_surname(ref, kid, father, mother)

    kid = %{
      kid
      | surnames: [{dob, surname}],
        mother: mother && mother.pid,
        father: father && father.pid,
        birth_surname_of_mother: mother && legal_surname_at(mother, dob)
    }

    junior_rate = origin_value(ref, parent, "junior_rate") || ref.metro["junior_rate_default"]

    if father && sex == "M" && Rng.chance?(junior_rate) do
      %{kid | given: father.given, middle: father.middle, suffix: "JR", junior_of: father.pid}
    else
      kid
    end
  end

  # Spanish convention: paternal first surname + maternal first surname.
  defp child_surname(ref, kid, father, mother) do
    paternal =
      (father && first_token(legal_surname(father))) ||
        (mother && first_token(birth_surname(mother)))

    double? =
      mother && father && origin_value(ref, kid, "double_surname") &&
        (kid.foreign_born or Rng.chance?(0.3))

    if double?, do: paternal <> " " <> first_token(birth_surname(mother)), else: paternal
  end

  # Twins usually get distinct but often alliterative or rhyming names.
  defp twin_name(twin, sibling) do
    if twin.given == sibling.given, do: %{twin | given: twin.given <> "A"}, else: twin
  end

  defp add_elder(ref, [head | _] = members, pid, hid) do
    dob = Date.add(head.dob, -Rng.int(20, 35) * 365)

    elder =
      person(ref, pid, hid, head.group,
        sex: Rng.pick(["F", "F", "M"]),
        dob: dob,
        origin: head.origin,
        foreign_born: head.foreign_born or Rng.chance?(0.4)
      )

    elder = %{
      elder
      | surnames: [
          {elder.dob, if(elder.sex == "M", do: legal_surname(head), else: birth_surname(elder))}
        ]
    }

    {members ++ [elder], pid + 1}
  end

  # -------------------------------------------------------------------- people

  defp person(ref, pid, hid, group, opts) do
    origin_spec =
      (opts[:origin] && find_origin(ref, group, opts[:origin])) || pick_origin(ref, group)

    origin = origin_spec["origin"]

    foreign_born =
      Keyword.get_lazy(opts, :foreign_born, fn -> Rng.chance?(origin_spec["foreign_born"]) end)

    sex = Keyword.fetch!(opts, :sex)

    dob =
      Keyword.get_lazy(opts, :dob, fn ->
        sample_dob(ref, group, opts[:min_age] || 0, opts[:headship])
      end)

    jan1 = foreign_born and Rng.chance?(origin_spec["jan1_dob"] || 0)
    dob = if jan1, do: Date.new!(dob.year, 1, 1), else: dob
    {given, middle} = given_names(ref, group, origin, sex, dob, foreign_born)

    surname =
      surname(
        ref,
        group,
        origin,
        foreign_born and Rng.chance?(origin_spec["double_surname"] || 0)
      )

    %{
      pid: pid,
      household: hid,
      group: group,
      origin: origin,
      foreign_born: foreign_born,
      sex: sex,
      dob: dob,
      jan1_dob: jan1,
      given: given,
      middle: middle,
      english_name: english_name(ref, group, origin, sex, dob, foreign_born),
      surnames: [{dob, surname}],
      name_events: [],
      suffix: nil,
      spouse: nil,
      mother: nil,
      father: nil,
      twin: nil,
      junior_of: nil,
      birth_surname_of_mother: nil,
      cells: cell_history(ref, dob),
      ssn: ssn(ref, foreign_born, dob),
      insured: nil,
      name_order_swap: Rng.chance?(origin_spec["name_order_swap"] || 0)
    }
    |> then(fn p -> %{p | insured: insured?(ref, p)} end)
  end

  defp pick_origin(ref, group) do
    specs = ref.metro["origins"][to_string(group)]
    Rng.weighted_key(Enum.map(specs, &{&1, &1["share"]}))
  end

  defp find_origin(ref, group, origin) do
    Enum.find(ref.metro["origins"][to_string(group)], &(&1["origin"] == origin))
  end

  defp origin_value(ref, person, key) do
    ref.metro["origins"]
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1["origin"] == person.origin))
    |> then(&(&1 && &1[key]))
  end

  # Rough householder rates by five-year bin from age 20; a person is likelier to head a household with age.
  @headship [
    0,
    0,
    0,
    0,
    0.2,
    0.4,
    0.48,
    0.52,
    0.55,
    0.57,
    0.6,
    0.62,
    0.63,
    0.65,
    0.68,
    0.7,
    0.7,
    0.65
  ]

  defp sample_dob(ref, group, min_age, headship) do
    weights = ref.metro["age_weights"][to_string(group)]

    bins =
      for {w, i} <- Enum.with_index(weights),
          i * 5 + 4 >= min_age,
          do: {i, if(headship, do: w * Enum.at(@headship, i), else: w)}

    i = Rng.weighted_key(bins)
    years = Rng.int(max(i * 5, min_age), if(i == 17, do: 99, else: i * 5 + 4))
    Rng.date(Date.add(@today, -(years + 1) * 365 + 1), Date.add(@today, -years * 365))
  end

  # US-born draw from SSA by cohort weighted toward the group; foreign-born from curated origin lists.
  defp given_names(ref, group, origin, sex, dob, foreign_born) do
    immigrant = Map.get(ref.immigrant_given, {origin, sex})

    draw = fn ->
      if (foreign_born and immigrant) && Rng.chance?(0.85),
        do: Rng.sample(immigrant),
        else: ssa_name(ref, group, sex, dob)
    end

    first = draw.()

    {first, middle} =
      case String.split(first, " ", parts: 2) do
        [a, b] -> {a, b}
        [a] -> {a, nil}
      end

    middle =
      cond do
        middle != nil -> middle
        origin == "vietnamese" and Rng.chance?(0.7) -> if(sex == "M", do: "VAN", else: "THI")
        foreign_born -> if Rng.chance?(0.25), do: first_token(draw.())
        Rng.chance?(0.8) -> first_token(ssa_name(ref, group, sex, dob))
        true -> nil
      end

    {first, if(middle == first, do: nil, else: middle)}
  end

  defp english_name(ref, :api, origin, sex, dob, true)
       when origin in ~w(chinese vietnamese korean) do
    if Rng.chance?(0.25), do: ssa_name(ref, :white, sex, dob)
  end

  defp english_name(_, _, _, _, _, _), do: nil

  defp ssa_name(ref, group, sex, dob) do
    cohort = dob.year |> div(5) |> Kernel.*(5) |> max(1925) |> min(2010)
    Rng.sample(ref.given[{group, sex, cohort}])
  end

  defp surname(ref, group, origin, double?) do
    draw = fn ->
      case ref.origin_surnames do
        %{^origin => table} ->
          if Rng.chance?(0.9), do: Rng.sample(table), else: Rng.sample(ref.surnames[group])

        _ ->
          Rng.sample(ref.surnames[group])
      end
    end

    first = draw.()
    if double?, do: first <> " " <> draw.(), else: first
  end

  # ---------------------------------------------------------- contact history

  defp address_history(ref, group, renter) do
    rate = ref.metro["annual_move_rate"][if(renter, do: "renter", else: "owner")]
    start = ~D[2008-01-01]
    moves = Rng.poisson(rate * Date.diff(@today, start) / 365)

    dates = [
      start | Enum.sort(for _ <- 1..moves//1, do: Rng.date(start, @today), into: [], uniq: false)
    ]

    Enum.map(dates, &{&1, address(ref, group, renter)})
  end

  defp address(ref, group, renter) do
    zip =
      Rng.weighted_key(
        for z <- ref.metro["zips"],
            do: {z["zip"], z["population_k"] * z["shares"][to_string(group)]}
      )

    street = "#{Rng.int(100, 19_999)} #{Rng.pick(ref.streets)}"

    street =
      if renter and Rng.chance?(0.7),
        do:
          "#{street} APT #{Rng.int(1, 40)}#{Rng.pick(~w(01 02 03 04 05 06 07 08 09 10 11 12 14 16 18 20))}",
        else: street

    %{zip: zip, street: street}
  end

  defp cell_history(ref, dob) do
    start = Enum.max([Date.add(dob, 13 * 365), ~D[2008-01-01]], Date)

    if Date.compare(start, @today) == :gt do
      [{dob, nil}]
    else
      changes =
        Rng.poisson(ref.metro["annual_phone_change_rate"] * Date.diff(@today, start) / 365)

      dates = [start | Enum.sort(for _ <- 1..changes//1, do: Rng.date(start, @today))]
      [{dob, nil} | Enum.map(dates, &{&1, phone_number(ref.metro["area_codes"]["cell"])})]
    end
  end

  @doc "A NANP-shaped ten-digit number; exchange avoids N11 and 555."
  def phone_number(area_codes) do
    exchange = Rng.int(201, 989)
    exchange = if exchange == 555 or rem(exchange, 100) == 11, do: exchange + 1, else: exchange

    Rng.pick(area_codes) <>
      Integer.to_string(exchange) <>
      String.pad_leading(Integer.to_string(Rng.int(0, 9999)), 4, "0")
  end

  # ------------------------------------------------------------------ identity

  defp ssn(ref, foreign_born, dob) do
    rules = ref.metro["ssn"]

    cond do
      not foreign_born -> {:ssn, valid_ssn(dob)}
      not Rng.chance?(rules["no_ssn_given_foreign_born"]) -> {:ssn, valid_ssn(dob)}
      Rng.chance?(rules["borrowed_ssn_given_no_ssn"]) -> {:borrowed, nil}
      Rng.chance?(rules["itin_given_no_ssn"]) -> {:itin, itin()}
      true -> {:none, nil}
    end
  end

  # Pre-2011 Texas-issued area numbers (449–467, 627–645) for older people; randomized afterwards.
  defp valid_ssn(dob) do
    area =
      if dob.year < 2008 and Rng.chance?(0.7),
        do: Rng.pick(Enum.to_list(449..467) ++ Enum.to_list(627..645)),
        else: Enum.find(Stream.repeatedly(fn -> Rng.int(1, 899) end), &(&1 != 666))

    pad(area, 3) <> pad(Rng.int(1, 99), 2) <> pad(Rng.int(1, 9999), 4)
  end

  defp itin,
    do:
      "9" <>
        pad(Rng.int(0, 99), 2) <>
        Integer.to_string(
          Rng.pick(Enum.to_list(70..88) ++ Enum.to_list(90..92) ++ Enum.to_list(94..99))
        ) <> pad(Rng.int(1, 9999), 4)

  # A small share of people without SSNs use one belonging to a relative or acquaintance.
  defp assign_borrowed_ssns(_ref, people) do
    lenders =
      for %{ssn: {:ssn, value}} = p <- people, age(p.dob, @today) >= 18, do: {p.pid, value}

    lenders = List.to_tuple(lenders)

    Enum.map(people, fn
      %{ssn: {:borrowed, nil}} = p when tuple_size(lenders) > 0 ->
        {lender, value} = elem(lenders, Rng.int(0, tuple_size(lenders) - 1))
        %{p | ssn: {:borrowed, value}} |> Map.put(:ssn_lender, lender)

      %{ssn: {:borrowed, nil}} = p ->
        %{p | ssn: {:none, nil}}

      p ->
        p
    end)
  end

  defp insured?(ref, person) do
    base = ref.metro["insured_rate"][to_string(person.group)]
    base = if match?({:ssn, _}, person.ssn), do: base, else: base * 0.45

    base =
      if age(person.dob, @today) >= 65 or age(person.dob, @today) < 19,
        do: min(1.0, base + 0.15),
        else: base

    Rng.chance?(base)
  end

  # ------------------------------------------------------------------- helpers

  @doc "Current legal surname."
  def legal_surname(person), do: person.surnames |> List.last() |> elem(1)

  @doc "Surname at a date."
  def legal_surname_at(person, date), do: at(person.surnames, date)

  @doc "Surname at birth."
  def birth_surname(person), do: person.surnames |> hd() |> elem(1)

  @doc "Five-year age bin index (0..17) for today."
  def bin(dob), do: min(div(age(dob, @today), 5), 17)

  defp first_token(name), do: name |> String.split([" ", "-"]) |> hd()
  defp other_sex("M"), do: "F"
  defp other_sex(_), do: "M"
  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
  defp atomize(map), do: Enum.map(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
end
