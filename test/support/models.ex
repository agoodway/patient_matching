defmodule PatientMatching.TestModels do
  @moduledoc false
  alias PatientMatching.{Comparators, Comparison, Config, Level, Model}

  def name_comparison(tf \\ false) do
    %Comparison{
      field: :family_name,
      levels: [
        %Level{name: :null, null_level?: true},
        %Level{name: :exact, match?: &Comparators.exact?/2, tf?: tf},
        %Level{name: :jw_0_85, match?: fn a, b -> Comparators.jaro_winkler(a, b) >= 0.85 end},
        %Level{name: :else, match?: fn _, _ -> true end}
      ]
    }
  end

  def fixed(opts \\ []) do
    comparison = name_comparison(Keyword.get(opts, :tf, false))

    config =
      Config.new(
        comparisons: [comparison],
        blocking: [[:family_name]],
        training_blocking: [[:family_name]]
      )

    %Model{
      lambda: 0.1,
      comparisons: [comparison],
      config: config,
      parameters: %{
        family_name: %{
          exact: %{m: 0.8, u: 0.1},
          jw_0_85: %{m: 0.15, u: 0.2},
          else: %{m: 0.05, u: 0.7}
        }
      },
      term_frequencies: %{family_name: %{"SMITH" => 0.1, "RARE" => 0.001}},
      trained: %{lambda_source: :fixed, unstable: false, em_iters: 0}
    }
  end
end
