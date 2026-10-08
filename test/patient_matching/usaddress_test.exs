defmodule PatientMatching.UsaddressTest do
  @moduledoc """
  Street normalization against the labeled addresses in `test/fixtures/usaddress`
  (datamade/usaddress test data). The usaddress labels say which tokens are
  suffixes, directionals, units and boxes; the expected short forms come from
  USPS Publication 28, written out here independently of `Normalize`.
  """
  use ExUnit.Case, async: true
  alias PatientMatching.{Comparators, Normalize}

  @fixtures Path.expand("../fixtures/usaddress", __DIR__)

  # Labels that make up a street line; place, state, ZIP, recipient,
  # building and landmark names are not part of the `:street` field.
  @street_labels ~w(AddressNumberPrefix AddressNumber AddressNumberSuffix
    StreetNamePreModifier StreetNamePreDirectional StreetNamePreType StreetName
    StreetNamePostType StreetNamePostDirectional StreetNamePostModifier
    OccupancyType OccupancyIdentifier SubaddressType SubaddressIdentifier
    USPSBoxGroupType USPSBoxGroupID USPSBoxType USPSBoxID)

  # Publication 28 Appendix C1: standard suffix => accepted spellings.
  @suffixes %{
    "ALY" => ~w(ALLEY ALY ALLEE ALLY),
    "AVE" => ~w(AVENUE AVE AV AVEN AVENU AVN AVNUE),
    "BLVD" => ~w(BOULEVARD BLVD BOUL BOULV),
    "CIR" => ~w(CIRCLE CIR CIRC CIRCL CRCL CRCLE),
    "CT" => ~w(COURT CT),
    "CTR" => ~w(CENTER CTR CEN CENT CENTR CENTRE CNTER CNTR),
    "DR" => ~w(DRIVE DR DRIV DRV),
    "EXPY" => ~w(EXPRESSWAY EXPY EXP EXPR EXPRESS EXPW),
    "FWY" => ~w(FREEWAY FWY FREEWY FRWAY FRWY),
    "HWY" => ~w(HIGHWAY HWY HIGHWY HIWAY HIWY HWAY),
    "LN" => ~w(LANE LN),
    "PARK" => ~w(PARK PRK),
    "PKWY" => ~w(PARKWAY PKWY PARKWY PKWAY PKY),
    "PL" => ~w(PLACE PL),
    "PLZ" => ~w(PLAZA PLZ PLZA),
    "RD" => ~w(ROAD RD),
    "RDG" => ~w(RIDGE RDG RDGE),
    "RTE" => ~w(ROUTE RTE),
    "SQ" => ~w(SQUARE SQ SQR SQRE SQU),
    "ST" => ~w(STREET ST STR STRT),
    "TER" => ~w(TERRACE TER TERR),
    "TPKE" => ~w(TURNPIKE TPKE TRNPK TURNPK),
    "TRL" => ~w(TRAIL TRL TRAILS TRLS),
    "WAY" => ~w(WAY WY)
  }

  @directionals %{
    "N" => "NORTH",
    "S" => "SOUTH",
    "E" => "EAST",
    "W" => "WEST",
    "NE" => "NORTHEAST",
    "NW" => "NORTHWEST",
    "SE" => "SOUTHEAST",
    "SW" => "SOUTHWEST"
  }

  # Publication 28 Appendix C2 designators that take a unit number.
  @designators %{
    "APT" => "APARTMENT",
    "BLDG" => "BUILDING",
    "FL" => "FLOOR",
    "OFC" => "OFFICE",
    "RM" => "ROOM",
    "SPC" => "SPACE",
    "STE" => "SUITE",
    "TRLR" => "TRAILER",
    "UNIT" => "UNIT"
  }

  @suffix_standard for {std, spellings} <- @suffixes, s <- spellings, into: %{}, do: {s, std}
  @directional_standard Map.merge(
                          Map.new(@directionals, fn {s, l} -> {l, s} end),
                          Map.new(@directionals, fn {s, _} -> {s, s} end)
                        )
  @designator_standard Map.merge(
                         Map.new(@designators, fn {s, l} -> {l, s} end),
                         Map.new(@designators, fn {s, _} -> {s, s} end)
                       )

  @addresses for file <- Path.wildcard(Path.join(@fixtures, "*.xml")) |> Enum.sort(),
                 [_, body] <-
                   Regex.scan(~r/<AddressString>(.*?)<\/AddressString>/s, File.read!(file)),
                 tokens =
                   for(
                     [_, label, text] <- Regex.scan(~r/<(\w+)>(.*?)<\/\1>/s, body),
                     label in @street_labels,
                     do:
                       {label,
                        text
                        |> String.replace("&amp;", "&")
                        |> String.replace(~r/&#(\d+);/, fn e ->
                          <<String.to_integer(String.slice(e, 2..-2//1))::utf8>>
                        end)}
                   ),
                 tokens != [],
                 # Intersections and two-street lines are not one address.
                 not String.contains?(body, "<IntersectionSeparator>"),
                 length(Regex.scan(~r/<StreetNamePostType>/, body)) <= 1,
                 do: {Path.basename(file), tokens}

  defp line(tokens), do: Enum.map_join(tokens, " ", &elem(&1, 1))
  defp word(text), do: Normalize.string(text)

  # Name words as the normalizer writes them: lettered house numbers are one
  # token (4922-N is 4922N) and dotted initialisms close up (U.S. is US).
  defp name_word(text) do
    text
    |> String.replace(~r/\b([0-9]+)-([A-Za-z])\b/, "\\1\\2")
    |> String.replace(~r/\b([A-Za-z])\.(?=[A-Za-z]\b)/, "\\1")
    |> word()
  end

  defp labeled(tokens, labels), do: for({l, t} <- tokens, l in labels, do: t)

  # Re-renders the labeled suffix, directional and designator tokens; street
  # names, numbers and identifiers are left as written.
  defp render(tokens, form) do
    Enum.map(tokens, fn {label, text} -> {label, rendered(label, word(text), form) || text} end)
  end

  # Short and long forms of a labeled token, or nil when the label is not
  # rewritten or the spelling is not a Publication 28 form.
  defp rendered(label, w, form) do
    {standard, long} =
      cond do
        label in ~w(StreetNamePostType StreetNamePreType) ->
          {@suffix_standard, &hd(@suffixes[&1])}

        label in ~w(StreetNamePreDirectional StreetNamePostDirectional) ->
          {@directional_standard, &@directionals[&1]}

        label == "OccupancyType" ->
          {@designator_standard, &@designators[&1]}

        true ->
          {%{}, nil}
      end

    case Map.fetch(standard, w) do
      {:ok, std} -> if form == :short, do: std, else: long.(std)
      :error -> nil
    end
  end

  defp unit_id(texts) do
    texts
    |> Enum.map(&word/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.replace(~r/^(\d+)(ST|ND|RD|TH)$/, "\\1")
  end

  test "the fixtures load" do
    assert length(@addresses) > 9_000
  end

  test "normalization is idempotent and yields uppercase words" do
    failures =
      for {file, tokens} <- @addresses,
          street = Normalize.street(line(tokens)),
          street != nil,
          Normalize.street(street) != street or not (street =~ ~r/^[A-Z0-9]+( [A-Z0-9]+)*$/),
          do: "#{file}: #{line(tokens)} -> #{street} -> #{Normalize.street(street)}"

    assert failures == [], report(failures)
  end

  test "house numbers and street-name words survive in order" do
    vocabulary =
      Map.keys(@suffix_standard) ++
        Map.keys(@directional_standard) ++ Map.keys(@designator_standard)

    failures =
      for {file, tokens} <- @addresses,
          expected =
            tokens
            |> labeled(~w(AddressNumber StreetName))
            |> Enum.flat_map(&String.split(name_word(&1) || "", " ", trim: true))
            |> Enum.reject(&(&1 in vocabulary)),
          street = Normalize.street(line(tokens)) || "",
          not subsequence?(expected, String.split(street)),
          do: "#{file}: #{line(tokens)} -> #{street}"

    assert failures == [], report(failures)
  end

  test "written, USPS-abbreviated and spelled-out suffixes, directionals and units agree" do
    failures =
      for {file, tokens} <- @addresses,
          renderings = [tokens, render(tokens, :short), render(tokens, :long)],
          streets = Enum.map(renderings, &Normalize.street(line(&1))),
          length(Enum.uniq(streets)) > 1,
          do:
            "#{file}: " <>
              Enum.map_join(Enum.zip(renderings, streets), " | ", fn {r, s} ->
                "#{line(r)} -> #{s}"
              end)

    assert failures == [], report(failures)
  end

  test "every Publication 28 spelling takes its standard abbreviation" do
    expected =
      Enum.map(@suffix_standard, fn {s, std} -> {"100 MAPLE #{s}", "100 MAPLE #{std}"} end) ++
        Enum.map(@directional_standard, fn {s, std} ->
          {"100 #{s} MAPLE AVE #{s}", "100 #{std} MAPLE AVE #{std}"}
        end) ++
        Enum.map(@designator_standard, fn {s, _} ->
          {"100 MAPLE AVE #{s} 4", "100 MAPLE AVE UNIT 4"}
        end)

    failures =
      for {input, want} <- expected,
          got = Normalize.street(input),
          got != want,
          do: "#{input} -> #{got}, expected #{want}"

    assert failures == [], report(failures)
  end

  test "labeled units split from the building, wherever they are written" do
    cases =
      for {file, tokens} <- @addresses,
          ids = labeled(tokens, ["OccupancyIdentifier"]),
          types = Enum.map(labeled(tokens, ["OccupancyType"]), &word/1),
          ids != [],
          Enum.all?(types, &Map.has_key?(@designator_standard, &1)),
          types != [] or "#" in Enum.map(ids, &String.trim(&1, ",")),
          do: {file, tokens, unit_id(ids)}

    assert length(cases) > 40

    contact = &{"60601", nil, Normalize.street(&1)}

    failures =
      for {file, tokens, unit} <- cases,
          building =
            tokens
            |> Enum.reject(&(elem(&1, 0) in ~w(OccupancyType OccupancyIdentifier)))
            |> line(),
          street = Normalize.street(line(tokens)),
          Normalize.street_unit(street) != {Normalize.street(building), unit} or
            not Comparators.building_and_zip?(contact.(line(tokens)), contact.(building)) or
            Comparators.building_and_zip?(
              contact.(line(tokens)),
              contact.(building <> " APT 99999")
            ),
          do:
            "#{file}: #{line(tokens)} -> #{inspect(Normalize.street_unit(street))}, expected " <>
              inspect({Normalize.street(building), unit})

    assert failures == [], report(failures)
  end

  test "post office boxes read PO BOX and keep their number" do
    cases =
      for {file, tokens} <- @addresses,
          Enum.all?(tokens, &(elem(&1, 0) in ~w(USPSBoxType USPSBoxID))),
          type = tokens |> labeled(["USPSBoxType"]) |> Enum.map_join(" ", &word/1),
          type in ["PO BOX", "P O BOX", "BOX"],
          do: {file, tokens, unit_id(labeled(tokens, ["USPSBoxID"]))}

    assert length(cases) >= 8

    failures =
      for {file, tokens, id} <- cases,
          got = Normalize.street(line(tokens)),
          got != "PO BOX #{id}",
          do: "#{file}: #{line(tokens)} -> #{got}"

    assert failures == [], report(failures)
  end

  test "rural and highway contract route boxes use RR and HC" do
    cases =
      for {file, tokens} <- @addresses,
          labels = Enum.map(tokens, &elem(&1, 0)) |> Enum.dedup(),
          labels == ~w(USPSBoxGroupType USPSBoxGroupID USPSBoxType USPSBoxID),
          group = tokens |> labeled(["USPSBoxGroupType"]) |> Enum.map_join(" ", &word/1),
          route = route(group),
          route != nil,
          do:
            {file, tokens,
             "#{route} #{unit_id(labeled(tokens, ["USPSBoxGroupID"]))} BOX #{unit_id(labeled(tokens, ["USPSBoxID"]))}"}

    assert length(cases) > 10

    failures =
      for {file, tokens, want} <- cases,
          got = Normalize.street(line(tokens)),
          got != want,
          do: "#{file}: #{line(tokens)} -> #{got}, expected #{want}"

    assert failures == [], report(failures)
  end

  defp route(group) do
    cond do
      group in ["RR", "R R", "RURAL ROUTE"] -> "RR"
      group =~ ~r/^(HC|HCR|HC R|HC ROUTE|STAR ROUTE|(HIGHWAY|HWY) CONTRACT (ROUTE|RTE))$/ -> "HC"
      true -> nil
    end
  end

  defp report(failures),
    do: "#{length(failures)} failures:\n" <> Enum.join(Enum.take(failures, 30), "\n")

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([x | xs], [x | ys]), do: subsequence?(xs, ys)
  defp subsequence?(xs, [_ | ys]), do: subsequence?(xs, ys)
end
