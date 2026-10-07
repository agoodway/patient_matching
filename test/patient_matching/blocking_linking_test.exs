defmodule PatientMatching.BlockingLinkingTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias PatientMatching.{Blocking, Linker, Normalize, Scorer, TestModels}

  test "OR of ANDs, nil isolation, deduplication and arbitrary-id ordering" do
    records = [
      %{id: 10, family_name: "Smith", dob: "2000-01-01", phone: "5551212"},
      %{id: 2, family_name: "Smyth", dob: "2000-02-01", phone: "5551212"},
      %{id: {:x, 3}, family_name: "Else", dob: "2001-01-01", phone: "5551212"},
      %{id: "nil1"},
      %{id: "nil2"}
    ]

    rules = [[:family_soundex, :dob_year], [:phone]]
    assert Blocking.pairs(records, rules, :dedupe_only) == [{2, 10}, {2, {:x, 3}}, {10, {:x, 3}}]
    assert Blocking.pairs(records, [[:family_soundex, :dob_year]], :dedupe_only) == [{2, 10}]

    assert Blocking.pairs(records, [[fn r -> r.normalized.phone end]], :dedupe_only) == [
             {2, 10},
             {2, {:x, 3}},
             {10, {:x, 3}}
           ]
  end

  test "linking preserves file orientation, allows overlapping ids, excludes self pairs" do
    left = [%{id: 9, family_name: "Smith"}, %{id: 1, family_name: "Smith"}]
    right = [%{id: 1, family_name: "Smith"}, %{id: 2, family_name: "Smith"}]
    assert Blocking.pairs({left, right}, [[:family_name]], :link_only) == [{1, 2}, {9, 1}, {9, 2}]

    assert_raise ArgumentError, fn ->
      Blocking.pairs([%{id: 1}, %{id: 1}], [[:family_name]], :dedupe_only)
    end

    assert_raise ArgumentError, fn -> Blocking.pairs([%{}], [[:family_name]], :dedupe_only) end
  end

  test "oversized blocks are counted once per rule, dropped and logged without raw keys" do
    records = for i <- 1..600, do: %{id: i, family_name: "SSN-SECRET", dob: "2000-01-01"}

    log =
      capture_log(fn ->
        assert %{pairs: [], dropped_blocks: 1} =
                 Blocking.candidates(records, [[:family_soundex, :dob_year]], :dedupe_only)
      end)

    refute log =~ "SSN-SECRET"
    assert log =~ "600"
  end

  test "same source/MRN bypasses blocking and thresholds; explain still has levels" do
    model = TestModels.fixed()
    left = [%{id: 1, source: "clinic", mrn: "007", family_name: "Alpha"}]

    right = [
      %{id: 2, source: "clinic", mrn: "007", family_name: "Omega"},
      %{id: 3, source: "other", mrn: "007", family_name: "Omega"}
    ]

    result = Linker.link(left, right, model)

    assert [%{left_id: 1, right_id: 2, probability: 1.0, weight: 50.0, reason: :mrn}] =
             result.matches

    assert result.review == []
    assert result.non_match_count == 0

    explained =
      Scorer.score(Normalize.record(hd(left)), Normalize.record(hd(right)), model, explain: true)

    assert explained.reason == :mrn
    assert hd(explained.levels).level == :else
    ordinary = Scorer.score(Normalize.record(hd(left)), Normalize.record(List.last(right)), model)
    assert ordinary.reason == :scored
  end

  test "classification is inclusive at both boundaries and only candidates are counted" do
    model = TestModels.fixed()
    left = [%{id: 1, family_name: "Smith"}]

    right = [
      %{id: 2, family_name: "Smith"},
      %{id: 3, family_name: "Smyth"},
      %{id: 4, family_name: "Other"}
    ]

    model = put_in(model.config.blocking, [[fn _ -> :all end]])
    match = Linker.link(left, right, model, match_threshold: 8 / 17, review_threshold: 0.2)
    assert Enum.map(match.matches, & &1.right_id) == [2]
    assert match.non_match_count == 2
    review = Linker.link(left, right, model, review_threshold: 0.01)
    assert Enum.map(review.review, & &1.right_id) == [2, 3]
    assert review.non_match_count == 1
    assert Linker.classify(0.2, 0.95, 0.2) == :non_match
    assert Linker.classify(0.95, 0.95, 0.2) == :match
    assert_raise ArgumentError, fn -> Linker.link(left, right, model, review_threshold: 1.0) end
  end

  test "link logging never includes raw patient strings" do
    model = TestModels.fixed()
    model = put_in(model.config.max_block_size, 1)

    log =
      capture_log(fn ->
        result =
          Linker.link(
            [%{id: 1, family_name: "SSN-SECRET", ssn: "SSN-SECRET"}],
            [%{id: 2, family_name: "SSN-SECRET", ssn: "SSN-SECRET"}],
            model
          )

        assert result.dropped_blocks == 1
      end)

    refute log =~ "SSN-SECRET"
    refute log =~ "SSNSECRET"
  end

  test "chunked parallel scoring returns the same pairs, in order, as scoring each pair" do
    model = TestModels.fixed()
    model = put_in(model.config.blocking, [[fn _ -> :all end]])
    model = put_in(model.config.max_block_size, :infinity)
    names = ["Smith", "Smyth", "Rare", "Other"]
    records = for i <- 1..80, do: %{id: i, family_name: Enum.at(names, rem(i, 4))}

    result = PatientMatching.dedupe(records, model, review_threshold: 0.0)
    prepared = Map.new(Blocking.prepare(records), &{&1.id, &1})

    expected =
      for a <- 1..80, b <- (a + 1)..80//1 do
        {a, b, Scorer.score(prepared[a], prepared[b], model).probability}
      end

    actual = Enum.map(result.matches ++ result.review, &{&1.left_id, &1.right_id, &1.probability})
    assert length(expected) > 2_000
    assert Enum.sort(actual) == Enum.sort(Enum.reject(expected, &(elem(&1, 2) == 0.0)))
    assert Enum.map(result.review, &{&1.left_id, &1.right_id}) |> then(&(&1 == Enum.sort(&1)))
  end
end
