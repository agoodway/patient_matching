ExUnit.start()

defmodule PatientMatchingEval.AcceptanceTest do
  use ExUnit.Case, async: true
  alias PatientMatchingEval.Acceptance

  defp suite do
    %{
      "acceptance" => %{
        "golden" => %{"overlay_failures" => %{"max" => 0}, "failures" => %{"max" => 0}}
      },
      "runs" => [
        %{
          "name" => "mpi",
          "acceptance" => %{
            "precision" => %{"min" => 0.99},
            "clusters" => %{
              "overlay_clusters" => %{"max" => 0},
              "bcubed_precision" => %{"min" => 0.99},
              "bcubed_recall" => %{"min" => 0.95}
            }
          }
        }
      ]
    }
  end

  defp run do
    %{
      name: "mpi",
      precision: 0.999,
      clusters: %{largest: 8, overlay_clusters: 0, bcubed_precision: 1.0, bcubed_recall: 0.99}
    }
  end

  test "a legitimate eight-record cluster passes quality gates" do
    assert Acceptance.failures([run()], [%{pass: true, risk: "overlay"}], suite()) == []
  end

  test "an overlay or recall regression fails with the metric name" do
    bad = put_in(run().clusters.overlay_clusters, 1)
    assert [failure] = Acceptance.failures([bad], [], suite())
    assert failure =~ "mpi.clusters.overlay_clusters"
    bad = put_in(run().clusters.bcubed_recall, 0.5)
    assert [failure] = Acceptance.failures([bad], [], suite())
    assert failure =~ "mpi.clusters.bcubed_recall"
  end

  test "golden failures are checked and missing golden results cannot pass" do
    failures = Acceptance.failures([run()], [%{pass: false, risk: "overlay"}], suite())
    assert length(failures) == 2
    assert Enum.any?(failures, &String.contains?(&1, "golden.overlay_failures"))
    assert Acceptance.failures([run()], nil, suite()) != []
  end

  test "a minimum case count prevents an empty scenario directory from passing" do
    targets = put_in(suite(), ["acceptance", "golden", "cases"], %{"min" => 1})
    assert [failure] = Acceptance.failures([run()], [], targets)
    assert failure =~ "golden.cases"
  end

  test "missing metrics and malformed targets fail rather than silently passing" do
    assert Acceptance.failures([Map.delete(run(), :clusters)], [], suite()) != []

    invalid =
      put_in(suite(), ["runs", Access.at(0), "acceptance", "precision"], %{"min" => "0.99"})

    assert Acceptance.failures([run()], [], invalid) != []

    invalid =
      put_in(suite(), ["runs", Access.at(0), "acceptance", "precision"], %{
        "min" => 0.9,
        "maximum" => 1
      })

    assert Acceptance.failures([run()], [], invalid) != []
  end

  test "checking a selected run does not demand results from unselected runs" do
    assert Acceptance.failures([], [%{pass: true, risk: "overlay"}], suite()) == []
  end

  test "the CLI rejects unknown run names instead of checking no runs" do
    assert_raise Mix.Error, fn -> Mix.Tasks.Eval.Run.run(["--run", "unknown", "--check"]) end
  end

  test "the CLI rejects unknown flags instead of accidentally disabling checks" do
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Eval.Run.run(["--chekc", "--golden-only", "--no-golden"])
    end
  end
end
