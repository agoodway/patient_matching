defmodule PatientMatching.PriorTrainingTest do
  use ExUnit.Case, async: true
  alias PatientMatching.{Presets, Synthetic}

  test "prior training preserves m base and estimates the same u and frequencies as EM" do
    config = Presets.patient_mpi()
    records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()
    base = %{sex: %{exact: 0.8, else: 0.2}}

    model =
      PatientMatching.train(records, config, m_estimation: :prior, m_init: base, lambda: 0.001)

    em = PatientMatching.train(records, config, lambda: 0.001)
    assert model.parameters.sex.exact.m == 0.8
    assert model.parameters.sex.else.m == 0.2

    for {field, levels} <- model.parameters, {level, parameter} <- levels do
      assert parameter.u == em.parameters[field][level].u
    end

    assert model.term_frequencies == em.term_frequencies
    assert model.trained.m_estimation == :prior
    assert model.trained.em_iters == 0
    assert model.trained.lambda_train == []
    loaded = PatientMatching.load(PatientMatching.dump(model), config)
    assert loaded.trained.m_estimation == :prior
  end

  test "prior training accepts a deduplicated file without training candidates and requires lambda" do
    config = Presets.patient_mpi()

    records = [
      %{id: 1, given_name: "Alex", family_name: "Sample", dob: "1980-01-10"},
      %{id: 2, given_name: "Robin", family_name: "Example", dob: "1991-02-12"}
    ]

    assert PatientMatching.train(records, config, m_estimation: :prior, lambda: 0.001).trained.em_iters ==
             0

    assert_raise ArgumentError, fn ->
      PatientMatching.train(records, config, m_estimation: :prior)
    end

    assert_raise ArgumentError, fn ->
      PatientMatching.train(records, config, m_estimation: :invalid, lambda: 0.001)
    end
  end

  test "put_lambda clamps, survives serialization and changes the explained prior" do
    config = Presets.patient_mpi()
    records = Synthetic.patients(30, 0.2) |> Synthetic.unlabeled()
    model = PatientMatching.train(records, config)
    updated = PatientMatching.put_lambda(model, 0.002)
    loaded = PatientMatching.load(PatientMatching.dump(updated), config)
    assert loaded.lambda == 0.002
    assert loaded.trained.lambda_source == :fixed
    [a, b | _] = records
    assert PatientMatching.explain(a, b, loaded) != PatientMatching.explain(a, b, model)
    assert PatientMatching.put_lambda(model, 2).lambda == 0.5
    assert PatientMatching.put_lambda(model, 0).lambda == 1.0e-9
    assert_raise ArgumentError, fn -> PatientMatching.put_lambda(model, "bad") end
  end
end
