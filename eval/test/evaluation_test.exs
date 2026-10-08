defmodule PatientMatchingEval.EvaluationTest do
  use ExUnit.Case
  alias PatientMatchingEval.{Artifacts, Evaluation, Generation, Validation}

  test "baseline comparison requires identical dataset hashes" do
    hashes = %{"records.jsonl" => "abc"}
    assert Evaluation.baseline(%{"runs" => %{}}, hashes) == {:unverified, nil}

    assert Evaluation.baseline(%{"dataset_hashes" => %{"records.jsonl" => "xyz"}}, hashes) ==
             {:different_dataset, nil}

    baseline = %{"dataset_hashes" => hashes}
    assert Evaluation.baseline(baseline, hashes) == {:verified, baseline}
  end

  test "evaluation and validation do not write or invoke generation" do
    dir =
      Path.join(System.tmp_dir!(), "patient-eval-readonly-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    Generation.population(dir, 300, 2027)
    files = ~w(records.jsonl truth.jsonl people.jsonl manifest.json)
    before = Artifacts.hashes(dir, files)
    parent = self()
    tracer = spawn(fn -> forward(parent) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    for function <- [:population, :benchmark, :challenges] do
      :erlang.trace_pattern({Generation, function, :_}, true, [:local])
    end

    try do
      assert Validation.population(dir).errors == []
      result = Evaluation.population(dir, run: "enterprise_mpi", no_golden: true)
      assert length(result.runs) == 1
      assert result.dataset_hashes == Map.take(before, ~w(records.jsonl truth.jsonl people.jsonl))
      assert Artifacts.hashes(dir, files) == before
      refute_receive {:trace, _, :call, {Generation, _, _}}
    after
      :erlang.trace(self(), false, [:call])
      send(tracer, :stop)

      for function <- [:population, :benchmark, :challenges],
          do: :erlang.trace_pattern({Generation, function, :_}, false, [:local])
    end
  end

  defp forward(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, message)
        forward(parent)
    end
  end
end
