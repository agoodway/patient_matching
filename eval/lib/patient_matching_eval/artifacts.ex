defmodule PatientMatchingEval.Artifacts do
  @moduledoc "Deterministic JSON artifacts, SHA-256 provenance and overwrite protection."

  @doc "SHA-256 of a file's bytes."
  def hash(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  @doc "Hashes files relative to a directory."
  def hashes(dir, files), do: Map.new(files, &{&1, hash(Path.join(dir, &1))})

  @doc "Hashes the static generator inputs."
  def inputs do
    Path.wildcard("eval/data/{curated,reference}/*")
    |> Enum.sort()
    |> Map.new(&{&1, hash(&1)})
  end

  @doc "Checks stored output hashes; legacy manifests are accepted with a warning."
  def verify!(dir, manifest, files) do
    actual = hashes(dir, files)
    expected = manifest["output_hashes"]

    if expected do
      for file <- files,
          expected[file] != actual[file],
          do:
            Mix.raise(
              "dataset hash mismatch: #{Path.join(dir, file)}; explicitly regenerate with mix eval.gen --out #{dir} --force"
            )
    end

    actual
  end

  @doc "Rejects replacement of an existing path without explicit force."
  def available!(out, force) do
    if File.exists?(out) and not force,
      do: Mix.raise("#{out} already exists; use --force to replace the generated dataset")

    if File.exists?(out) and force and not replaceable?(out),
      do:
        Mix.raise(
          "#{out} is not a generated dataset directory; --force cannot replace unrelated files"
        )
  end

  defp replaceable?(path) do
    File.dir?(path) and
      (File.ls!(path) == [] or File.regular?(Path.join(path, "index.json")) or
         Enum.all?(
           ~w(manifest.json records.jsonl truth.jsonl people.jsonl),
           &File.regular?(Path.join(path, &1))
         ) or
         Enum.all?(~w(manifest.json cases.jsonl), &File.regular?(Path.join(path, &1))))
  end

  @doc "Writes reports while preventing writes into any input dataset directory."
  def report!(path, value, protected_dirs) do
    expanded = canonical(path, 40)

    for dir <- protected_dirs do
      root = canonical(dir, 40)

      if expanded == root or String.starts_with?(expanded, root <> "/"),
        do: Mix.raise("report path must be outside dataset files; use eval/results/")
    end

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".report-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:exclusive])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp canonical(_path, 0), do: Mix.raise("too many symlinks in report/dataset path")

  defp canonical(path, remaining) do
    [root | components] = path |> Path.expand() |> Path.split()

    Enum.reduce(components, root, fn part, resolved ->
      candidate = Path.join(resolved, part)

      case File.read_link(candidate) do
        {:ok, target} -> canonical(Path.expand(target, Path.dirname(candidate)), remaining - 1)
        {:error, _} -> candidate
      end
    end)
  end

  @doc "Writes JSON with a trailing newline."
  def json(path, value), do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n")

  @doc "Writes JSONL in the supplied row order."
  def jsonl(path, rows), do: File.write!(path, Enum.map(rows, &[Jason.encode!(&1), "\n"]))

  @doc "Reads JSONL without silently discarding duplicate IDs."
  def rows(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  @doc "Reads an expected artifact or raises an actionable generation error."
  def require!(dir, files, command) do
    for file <- files,
        not File.regular?(Path.join(dir, file)),
        do: Mix.raise("missing dataset file #{Path.join(dir, file)}; run `#{command}`")
  end

  @doc "Converts metrics structs and tuples to JSON terms."
  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  def jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(other), do: other
end
