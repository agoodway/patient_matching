defmodule Mix.Tasks.Eval.Test do
  @shortdoc "Runs dev-only evaluation harness tests"
  @moduledoc "Runs eval/test/*_test.exs with the dev-only harness compiled."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :dev, do: Mix.raise("run mix eval.test in the default dev environment")
    if args != [], do: Mix.raise("mix eval.test takes no arguments")
    Mix.Task.run("app.start")
    ExUnit.start(autorun: false)
    Path.wildcard("eval/test/*_test.exs") |> Enum.each(&Code.require_file/1)
    if ExUnit.run().failures > 0, do: Mix.raise("eval tests failed")
  end
end
