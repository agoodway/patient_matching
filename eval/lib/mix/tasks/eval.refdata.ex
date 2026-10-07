defmodule Mix.Tasks.Eval.Refdata do
  @shortdoc "Downloads and trims public name-frequency tables into eval/data/reference"
  @moduledoc """
  Rebuilds the static reference tables used by `mix eval.gen`. Needs network
  access; the output is committed, so this only runs when refreshing sources.

      mix eval.refdata [--surname-min 300] [--given-min 50]

  Sources (all public domain or CC0):

    * Census 2010 surnames with race/Hispanic-origin shares
    * SSA national given names by birth year and sex, 1925–2010, through the
      pydata-book mirror because ssa.gov rejects scripted downloads
    * Tzioumis (2018) first names with race/Hispanic-origin shares, Harvard Dataverse

  Writes `surnames.csv`, `given_names.csv` and `first_name_ethnicity.csv`.
  Ethnicity columns are always ordered as `PatientMatchingEval.Reference.groups/0`.
  """
  use Mix.Task

  @census "https://www2.census.gov/topics/genealogy/2010surnames/names.zip"
  @ssa "https://raw.githubusercontent.com/wesm/pydata-book/3rd-edition/datasets/babynames/yob"
  @tzioumis "https://dataverse.harvard.edu/api/access/datafile/3078263?format=original"
  @years 1925..2010
  @out "eval/data/reference"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [surname_min: :integer, given_min: :integer])
    # Mix prunes code paths to declared applications; the library itself needs neither.
    Enum.each([:inets, :ssl, :public_key], &Mix.ensure_application!/1)
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    File.mkdir_p!(@out)

    surnames(Keyword.get(opts, :surname_min, 300))
    given_names(Keyword.get(opts, :given_min, 50))
    first_name_ethnicity()
  end

  # Census columns: name,rank,count,prop100k,cum_prop100k,pctwhite,pctblack,pctapi,pctaian,pct2prace,pcthispanic
  defp surnames(minimum) do
    {:ok, [{_, csv}]} =
      :zip.extract(fetch(@census), [:memory, file_list: [~c"Names_2010Census.csv"]])

    rows =
      for line <- csv |> String.split(["\r\n", "\n"], trim: true) |> tl(),
          [name, _rank, count, _, _, w, b, api, aian, multi, h] = String.split(line, ","),
          name != "ALL OTHER NAMES",
          count = String.to_integer(count),
          count >= minimum do
        [name, count | fill_suppressed([h, w, b, api, aian, multi])]
      end

    write("surnames.csv", ["name", "count" | groups()], rows)
  end

  # Census suppresses small cells as "(S)"; spread the unexplained share evenly over them.
  defp fill_suppressed(cells) do
    known = for c <- cells, c != "(S)", do: parse_float(c)
    suppressed = Enum.count(cells, &(&1 == "(S)"))
    fill = if suppressed > 0, do: max(100.0 - Enum.sum(known), 0.0) / suppressed, else: 0.0
    Enum.map(cells, fn c -> if c == "(S)", do: round4(fill), else: round4(parse_float(c)) end)
  end

  # Aggregated to five-year birth cohorts to keep the table small while preserving name fashion.
  defp given_names(minimum) do
    counts =
      Enum.reduce(@years, %{}, fn year, acc ->
        cohort = div(year, 5) * 5

        fetch("#{@ssa}#{year}.txt")
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.reduce(acc, fn line, acc ->
          [name, sex, count] = String.split(line, ",")

          Map.update(
            acc,
            {cohort, sex, String.upcase(name)},
            String.to_integer(count),
            &(&1 + String.to_integer(count))
          )
        end)
      end)

    rows =
      for {{cohort, sex, name}, count} <- counts, count >= minimum do
        [cohort, sex, name, count]
      end
      |> Enum.sort_by(fn [cohort, sex, name, count] -> {cohort, sex, -count, name} end)

    write("given_names.csv", ~w(cohort sex name count), rows)
  end

  # Dataverse serves the original .xlsx; read the first sheet with shared strings.
  defp first_name_ethnicity do
    {:ok, files} = :zip.extract(fetch(@tzioumis), [:memory])
    files = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)

    strings =
      Regex.scan(~r/<si>(.*?)<\/si>/s, files["xl/sharedStrings.xml"], capture: :all_but_first)
      |> Enum.map(fn [si] ->
        si |> then(&Regex.scan(~r/<t[^>]*>([^<]*)<\/t>/, &1)) |> Enum.map_join(&List.last/1)
      end)
      |> List.to_tuple()

    # The workbook holds a notes sheet too; the data sheet is the one with the most rows.
    [_header | rows] =
      files
      |> Enum.filter(fn {name, _} -> String.starts_with?(name, "xl/worksheets/sheet") end)
      |> Enum.map(fn {_, xml} ->
        Regex.scan(~r/<row[^>]*>(.*?)<\/row>/s, xml, capture: :all_but_first)
      end)
      |> Enum.max_by(&length/1)
      |> Enum.map(fn [row] ->
        Regex.scan(~r/<c ([^>]*?)\/?>(?:<v>([^<]*)<\/v>)?/, row)
        |> Enum.map(fn
          [_, attrs, v] ->
            if attrs =~ ~s(t="s"), do: elem(strings, String.to_integer(v)), else: v

          _ ->
            ""
        end)
      end)

    # Source columns: firstname,obs,pcthispanic,pctwhite,pctblack,pctapi,pctaian,pct2prace
    rows =
      for [name, obs | pcts] <- rows, name != "" do
        [String.upcase(name), round(parse_float(obs)) | Enum.map(pcts, &round4(parse_float(&1)))]
      end

    write("first_name_ethnicity.csv", ["name", "obs" | groups()], rows)
  end

  defp groups, do: Enum.map(PatientMatchingEval.Reference.groups(), &Atom.to_string/1)

  defp fetch(url) do
    Mix.shell().info("GET #{url}")
    headers = [{~c"user-agent", ~c"patient_matching-eval"}]

    http = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      autoredirect: true
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http, body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> body
      other -> Mix.raise("download failed for #{url}: #{inspect(other, limit: 5)}")
    end
  end

  defp write(file, header, rows) do
    path = Path.join(@out, file)
    lines = Enum.map([header | rows], &Enum.join(&1, ","))
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    Mix.shell().info("wrote #{path} (#{length(rows)} rows)")
  end

  defp parse_float(""), do: 0.0

  defp parse_float(text) do
    case Float.parse(text) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp round4(value), do: Float.round(value * 1.0, 4)
end
