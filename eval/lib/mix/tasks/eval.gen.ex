defmodule Mix.Tasks.Eval.Gen do
  @shortdoc "Explicitly generates a stored synthetic population or benchmark bundle"
  @moduledoc """
  Generate once, then validate or evaluate without regenerating:

      mix eval.gen [--people 4000] [--seed 2026] [--out eval/data/population] [--force]
      mix eval.gen --benchmark --out eval/data/benchmark [--force]

  Benchmark populations have fixed sizes/seeds; --people and --seed cannot be combined
  with --benchmark. Replacing any existing output directory requires --force.
  """
  use Mix.Task
  alias PatientMatchingEval.Generation

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          people: :integer,
          seed: :integer,
          out: :string,
          benchmark: :boolean,
          force: :boolean
        ]
      )

    if positional != [] or invalid != [],
      do: Mix.raise("invalid generation arguments: #{inspect(positional ++ invalid)}")

    if opts[:benchmark] == true and
         (Keyword.has_key?(opts, :people) or Keyword.has_key?(opts, :seed)),
       do: Mix.raise("--benchmark cannot be combined with --people or --seed")

    out =
      opts[:out] || if(opts[:benchmark], do: "eval/data/benchmark", else: "eval/data/population")

    if opts[:benchmark] do
      Generation.benchmark(out, opts[:force] || false)
      Mix.shell().info("benchmark bundle → #{out}")
    else
      manifest =
        Generation.population(
          out,
          opts[:people] || 4000,
          opts[:seed] || 2026,
          opts[:force] || false
        )

      Mix.shell().info("#{manifest["people"]} people, #{manifest["records"]} records → #{out}")
    end
  end
end
