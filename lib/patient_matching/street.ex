defmodule PatientMatching.Street do
  @moduledoc false
  # Street lines in USPS Publication 28 standard form, by word position: the
  # suffix and the directionals around a street name are abbreviated, words
  # inside the name are kept (`RIDGE AVENUE` is `RIDGE AVE`, and `EAST ST`
  # stays apart from `E ST`), every unit designator becomes `UNIT` after the
  # street, and box lines read `PO BOX`, `RR` or `HC`. Addresses are not
  # validated.
  alias PatientMatching.Normalize

  @unit "UNIT"

  # Publication 28 Appendix C1: standard suffix => accepted spellings.
  @suffix_spellings %{
    "ALY" => ~w(ALLEY ALLEE ALLY ALY),
    "AVE" => ~w(AVENUE AV AVE AVEN AVENU AVN AVNUE),
    "BLVD" => ~w(BOULEVARD BLVD BOUL BOULV),
    "BND" => ~w(BEND BND),
    "CIR" => ~w(CIRCLE CIR CIRC CIRCL CRCL CRCLE),
    "CRES" => ~w(CRESCENT CRES CRSENT CRSNT),
    "CRK" => ~w(CREEK CRK),
    "CT" => ~w(COURT CT),
    "CTR" => ~w(CENTER CEN CENT CENTR CENTRE CNTER CNTR CTR),
    "CV" => ~w(COVE CV),
    "CYN" => ~w(CANYON CANYN CNYN CYN),
    "DR" => ~w(DRIVE DR DRIV DRV),
    "ESTS" => ~w(ESTATES ESTS),
    "EXPY" => ~w(EXPRESSWAY EXP EXPR EXPRESS EXPW EXPY),
    "FWY" => ~w(FREEWAY FREEWY FRWAY FRWY FWY),
    "GDNS" => ~w(GARDENS GDNS GRDNS),
    "GLN" => ~w(GLEN GLN),
    "GRV" => ~w(GROVE GROV GRV),
    "HOLW" => ~w(HOLLOW HLLW HOLLOWS HOLW HOLWS),
    "HTS" => ~w(HEIGHTS HTS),
    "HWY" => ~w(HIGHWAY HIGHWY HIWAY HIWY HWAY HWY),
    "LN" => ~w(LANE LN),
    "LNDG" => ~w(LANDING LNDG LNDNG),
    "LOOP" => ~w(LOOP LOOPS),
    "MDWS" => ~w(MEADOWS MDWS),
    "MNR" => ~w(MANOR MNR),
    "PARK" => ~w(PARK PARKS PRK),
    "PKWY" => ~w(PARKWAY PARKWY PKWAY PKWY PKY),
    "PL" => ~w(PLACE PL),
    "PLZ" => ~w(PLAZA PLZ PLZA),
    "PT" => ~w(POINT PT),
    "RD" => ~w(ROAD RD),
    "RDG" => ~w(RIDGE RDG RDGE),
    "RTE" => ~w(ROUTE RTE),
    "SQ" => ~w(SQUARE SQ SQR SQRE SQU),
    "ST" => ~w(STREET ST STR STRT),
    "TER" => ~w(TERRACE TER TERR),
    "TPKE" => ~w(TURNPIKE TPKE TRNPK TURNPK),
    "TRCE" => ~w(TRACE TRACES TRCE),
    "TRL" => ~w(TRAIL TRAILS TRL TRLS),
    "VLG" => ~w(VILLAGE VILL VILLAG VILLG VILLIAGE VLG),
    "VLY" => ~w(VALLEY VALLY VLLY VLY),
    "WAY" => ~w(WAY WY),
    "XING" => ~w(CROSSING CRSSNG XING)
  }
  @suffixes for {std, spellings} <- @suffix_spellings, s <- spellings, into: %{}, do: {s, std}

  @directionals %{
    "NORTH" => "N",
    "SOUTH" => "S",
    "EAST" => "E",
    "WEST" => "W",
    "NORTHEAST" => "NE",
    "NORTHWEST" => "NW",
    "SOUTHEAST" => "SE",
    "SOUTHWEST" => "SW",
    "N" => "N",
    "S" => "S",
    "E" => "E",
    "W" => "W",
    "NE" => "NE",
    "NW" => "NW",
    "SE" => "SE",
    "SW" => "SW"
  }

  # Publication 28 Appendix C2 designators that take a unit number. All become
  # one marker, so `APT 4`, `SUITE 4` and `#4` agree.
  @designators ~w(APT APARTMENT BLDG BUILDING FL FLOOR HNGR HANGAR LOT OFC OFFICE
    RM ROOM SPC SPACE STE SUITE TRLR TRAILER UNIT)
  # Designators that mean nothing without a number (`12 ELM ST APT`).
  @bare_designators ~w(APT APARTMENT STE SUITE UNIT)
  @floors ~w(FL FLOOR)

  @doc "Standard form of a street line, or nil."
  def normalize(value) when is_binary(value) do
    value
    # Dotted initialisms: U.S. is US and P.O. is PO, not U S and P O.
    |> String.replace(~r/\b([A-Za-z])\.(?=[A-Za-z]\b)/, "\\1")
    # A lettered house number is one token: 4922-N, not a directional N.
    |> String.replace(~r/\b([0-9]+)-([A-Za-z])\b/, "\\1\\2")
    |> String.replace("#", " #{@unit} ")
    |> Normalize.string()
    |> standardize()
  end

  def normalize(value), do: value |> Normalize.string() |> standardize()

  @doc ~S|Splits a normalized street at its unit marker: `{"12 OAK ST", "4"}`; the unit is nil when absent.|
  def unit(nil), do: {nil, nil}

  def unit(street) do
    case String.split(street, " #{@unit} ", parts: 2) do
      [building, unit] -> {building, unit}
      [building] -> {building, nil}
    end
  end

  defp standardize(nil), do: nil

  defp standardize(text) do
    tokens = text |> box_phrases() |> String.split(" ") |> Enum.flat_map(&unglue/1)
    words = if box?(tokens), do: Enum.reject(tokens, &(&1 == @unit)), else: address(tokens)

    case Enum.join(words, " ") do
      "" -> nil
      street -> street
    end
  end

  defp box_phrases(text) do
    text
    |> String.replace(~r/\b(P O|POST OFFICE) BOX\b/, "PO BOX")
    |> String.replace(~r/^BOX\b/, "PO BOX")
    |> String.replace(~r/^(RURAL (ROUTE|RTE)|R R)\b/, "RR")
    |> String.replace(
      ~r/^((HIGHWAY|HWY) CONTRACT (ROUTE|RTE)|STAR (ROUTE|RTE)|HCR|HC (ROUTE|RTE|R))\b/,
      "HC"
    )
  end

  # Box lines have no street to standardize; a `#` before a box or route
  # number is not a unit.
  defp box?(["PO", "BOX" | _]), do: true
  defp box?([route, _ | _]) when route in ["RR", "HC"], do: true
  defp box?(_), do: false

  # A designator written against its number: APT4B.
  defp unglue(word) do
    case Enum.find(@designators, &glued?(word, &1)) do
      nil -> [word]
      designator -> [@unit, String.replace_prefix(word, designator, "")]
    end
  end

  defp glued?(word, designator) do
    String.starts_with?(word, designator) and
      match?(<<d, _::binary>> when d in ?0..?9, String.replace_prefix(word, designator, ""))
  end

  defp address(tokens) do
    {street, unit} = split_unit(tokens)
    street_words(street) ++ unit_words(unit)
  end

  # The unit runs from its first designator to the end, or is moved there from
  # the front of the line (`APT 1B 626 E KILBOURN AVE`).
  defp split_unit(tokens) do
    case Enum.find_index(Enum.with_index(tokens), fn {_, i} -> unit_start?(tokens, i) end) do
      nil ->
        {drop_bare_designator(tokens), []}

      0 ->
        {markers, rest} = Enum.split_while(tokens, &(&1 == @unit or &1 in @designators))
        {id, street} = Enum.split(rest, 1)
        {street, markers ++ id}

      i ->
        Enum.split(tokens, i)
    end
  end

  defp unit_start?(tokens, i) do
    [token | rest] = Enum.drop(tokens, i)
    next = rest |> Enum.drop_while(&(&1 == @unit)) |> List.first()

    cond do
      token == @unit -> true
      token in @designators -> identifier?(next)
      ordinal?(token) -> i >= 2 and next in @floors
      true -> false
    end
  end

  # STE GENEVIEVE is a name; STE 4 is a unit.
  defp identifier?(nil), do: false
  defp identifier?(token), do: token =~ ~r/[0-9]/ or String.length(token) <= 2

  defp ordinal?(token), do: token =~ ~r/^[0-9]+(ST|ND|RD|TH)$/

  defp drop_bare_designator(tokens) do
    if length(tokens) > 1 and List.last(tokens) in @bare_designators,
      do: Enum.drop(tokens, -1),
      else: tokens
  end

  defp unit_words(unit) do
    unit
    |> canonical_unit()
    |> Enum.chunk_by(&(&1 == @unit))
    |> Enum.flat_map(fn
      [@unit | _] -> [@unit]
      words -> words
    end)
    |> then(&if(List.last(&1) == @unit, do: Enum.drop(&1, -1), else: &1))
  end

  # `3RD FLOOR` and `FL 3` are both `UNIT 3`.
  defp canonical_unit([ordinal, floor | rest]) when floor in @floors do
    if ordinal?(ordinal),
      do: [@unit, cardinal(ordinal) | canonical_unit(rest)],
      else: [cardinal(ordinal) | canonical_unit([floor | rest])]
  end

  defp canonical_unit([designator | rest]) when designator in @designators,
    do: [@unit | canonical_unit(rest)]

  defp canonical_unit([token | rest]), do: [cardinal(token) | canonical_unit(rest)]
  defp canonical_unit([]), do: []

  defp cardinal(token), do: String.replace(token, ~r/^([0-9]+)(ST|ND|RD|TH)$/, "\\1")

  # Positions: house number, optional predirectional, name, suffix and
  # postdirectionals. Without a suffix, a type word before a route number
  # (`US HWY 50`, `COUNTY RD AA NE`) is abbreviated instead.
  defp street_words(tokens) do
    start = name_start(tokens)
    words = tokens |> merge_compound(start) |> List.to_tuple()
    n = tuple_size(words)
    suffix = suffix_index(words, start, n)

    positions =
      if suffix,
        do: suffix_positions(words, start, suffix, n),
        else: route_positions(words, start, n)

    positions = predirectional(words, start, suffix, positions)

    for {word, i} <- Enum.with_index(Tuple.to_list(words)) do
      if i in positions,
        do: Map.get(@suffixes, word) || Map.get(@directionals, word, word),
        else: word
    end
  end

  # A directional before at least one name word. A half-address letter may
  # precede it (4922 B SOUTH CORNELL AVE). The name ends before the suffix,
  # quadrant or trailing directional; a route type (N HWY 71) is followed by
  # its name.
  defp predirectional(words, start, suffix, positions) do
    n = tuple_size(words)

    pre =
      if start + 1 < n and single_letter?(elem(words, start)) and directional?(words, start + 1),
        do: start + 1,
        else: start

    last_name =
      positions
      |> Enum.reject(&(suffix == nil and Map.has_key?(@suffixes, elem(words, &1))))
      |> then(&(Enum.min([n | &1]) - 1))

    if directional?(words, pre) and pre < last_name,
      do: MapSet.put(positions, pre),
      else: positions
  end

  # The suffix, directionals after it, and a quadrant between name and suffix
  # (NEW MEXICO NW AVE).
  defp suffix_positions(words, start, suffix, n) do
    quadrant =
      if directional?(words, suffix - 1) and suffix - 1 > start and
           Enum.any?(start..(suffix - 2)//1, &(not directional?(words, &1))),
         do: [suffix - 1],
         else: []

    MapSet.new(quadrant ++ Enum.to_list(suffix..(n - 1)//1))
  end

  defp route_positions(words, start, n) do
    route_type =
      Enum.find(start..(n - 2)//1, fn i ->
        Map.has_key?(@suffixes, elem(words, i)) and route_id?(elem(words, i + 1))
      end)

    trailing =
      directional?(words, n - 1) and n - 1 > start and
        Enum.any?(start..(n - 2)//1, &(not directional?(words, &1)))

    MapSet.new(List.wrap(route_type) ++ if(trailing, do: [n - 1], else: []))
  end

  @north_south ~w(N NORTH S SOUTH)
  @east_west ~w(E EAST W WEST)

  # A compound predirectional written in two words: S W FARM RD is SW FARM RD.
  defp merge_compound(tokens, start) do
    case Enum.split(tokens, start) do
      {number, [ns, ew | rest]} when ns in @north_south and ew in @east_west ->
        if Enum.any?(
             rest,
             &(not Map.has_key?(@directionals, &1) and not Map.has_key?(@suffixes, &1))
           ),
           do: number ++ [@directionals[ns] <> @directionals[ew] | rest],
           else: tokens

      _ ->
        tokens
    end
  end

  # The house number: a first token with a digit plus any all-digit parts
  # (59-17 JUNCTION BLVD).
  defp name_start([first | rest]) do
    if first =~ ~r/[0-9]/,
      do: 1 + Enum.count(Enum.take_while(rest, &(&1 =~ ~r/^[0-9]+$/))),
      else: 0
  end

  defp name_start([]), do: 0

  # The last suffix word after at least one name word and followed only by up
  # to two directionals.
  defp suffix_index(words, start, n) do
    Enum.find((n - 1)..(start + 1)//-1, fn i ->
      Map.has_key?(@suffixes, elem(words, i)) and n - 1 - i <= 2 and
        Enum.all?((i + 1)..(n - 1)//1, &directional?(words, &1))
    end)
  end

  defp directional?(words, i),
    do: i >= 0 and i < tuple_size(words) and Map.has_key?(@directionals, elem(words, i))

  defp single_letter?(word),
    do: String.length(word) == 1 and not Map.has_key?(@directionals, word)

  defp route_id?(word), do: word =~ ~r/[0-9]/ or String.length(word) <= 3
end
