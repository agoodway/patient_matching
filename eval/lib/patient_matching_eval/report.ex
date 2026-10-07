defmodule PatientMatchingEval.Report do
  @moduledoc "Renders run metrics, golden results and baseline deltas as plain text."

  @min_tag_pairs 15

  @doc "Full text report."
  def render(runs, golden, baseline) do
    [
      Enum.map(runs, &run/1),
      golden_section(golden),
      baseline_section(runs, golden, baseline)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp run(m) do
    [
      "",
      rule("#{m.name}#{if m.diagnostic, do: " (diagnostic)", else: ""} — #{m.kind}"),
      m.description,
      "records #{int(m.records)} · true pairs #{int(m.true_pairs)} · train #{secs(m.timings.train_ms)} · score #{secs(m.timings.score_ms)}",
      "model   λ=#{sig(m.model.lambda)} (#{m.model.trained.lambda_source}) · EM iters #{m.model.trained.em_iters} · unstable=#{m.model.trained.unstable}",
      "block   #{int(m.candidates)} candidates · blocking recall #{pct(m.blocking_recall)} · dropped blocks #{m.dropped_blocks}",
      "decide  auto-match #{int(m.matches)} (precision #{pct(m.precision)}, recall #{pct(m.recall)}, F1 #{pct(m.f1)})",
      "        review #{int(m.review)} (#{int(m.review_true)} true) · recall incl. review #{pct(m.recall_with_review)}",
      "missed  unblocked #{int(m.missed_by_stage.unblocked)} · scored non-match #{int(m.missed_by_stage.scored_non_match)} · in review #{int(m.missed_by_stage.review)}",
      "false   #{int(m.false_matches)} auto-matched pairs of different people: #{counts(m.false_match_causes)}",
      cluster_line(m.clusters),
      assignment_line(m.assignment),
      "",
      "  Hardest data-quality conditions (true pairs touching a tag, n ≥ #{@min_tag_pairs}):",
      tag_table(m.tags),
      "",
      "  By population slice (recall over true pairs; false auto-matched pairs per 1k records):",
      slice_table(m.slices["group"]),
      slice_table(m.slices["age_band"]),
      slice_table(m.slices["foreign_born"], "foreign born"),
      "",
      "  Threshold sweep:",
      Enum.map(m.sweep, fn s ->
        "    p ≥ #{pad(to_string(s.threshold), 6)} matches #{pad(int(s.matches), 8)} precision #{pad(pct(s.precision), 7)} recall #{pct(s.recall)}"
      end),
      "",
      "  Field weights log2(m/u):",
      weights(m.model.weights),
      examples("False auto-match examples", m.false_match_examples),
      examples("Missed true-pair examples", m.missed_examples)
    ]
  end

  defp cluster_line(nil), do: []

  defp cluster_line(c),
    do:
      "cluster #{int(c.clusters)} clusters · largest #{c.largest} · overlay clusters #{c.overlay_clusters} (#{c.people_merged_into_overlays} people merged) · B³ precision #{pct(c.bcubed_precision)} recall #{pct(c.bcubed_recall)}"

  defp assignment_line(nil), do: []

  defp assignment_line(a),
    do:
      "assign  one-to-one #{int(a.pairs)} pairs · precision #{pct(a.precision)} · recall #{pct(a.recall)}"

  defp tag_table(tags) do
    rows =
      tags
      |> Enum.filter(fn {_, r} -> r.pairs >= @min_tag_pairs end)
      |> Enum.sort_by(fn {_, r} -> r.recall_with_review || 1 end)
      |> Enum.take(18)

    header =
      "    #{pad("tag", 28)} #{pad("pairs", 7)} #{pad("blocked", 8)} #{pad("auto", 7)} +review"

    [
      header
      | Enum.map(rows, fn {tag, r} ->
          "    #{pad(tag, 28)} #{pad(int(r.pairs), 7)} #{pad(pct(r.blocked), 8)} #{pad(pct(r.recall), 7)} #{pct(r.recall_with_review)}"
        end)
    ]
  end

  defp slice_table(rows, label \\ nil) do
    rows
    |> Enum.sort_by(fn {_, r} -> -r.records end)
    |> Enum.map(fn {v, r} ->
      "    #{pad(if(label, do: "#{label}=#{v}", else: v), 22)} records #{pad(int(r.records), 7)} recall #{pad(pct(r.recall), 7)} +review #{pad(pct(r.recall_with_review), 7)} false/1k #{r.false_matches_per_1k_records}"
    end)
  end

  defp weights(weights) do
    for {field, levels} <- Enum.sort(weights) do
      cells =
        levels
        |> Enum.sort_by(fn {_, %{weight: w}} -> -w end)
        |> Enum.map_join("  ", fn {level, %{weight: w}} -> "#{level} #{Float.round(w, 1)}" end)

      "    #{pad(to_string(field), 12)} #{cells}"
    end
  end

  defp examples(_title, []), do: []

  defp examples(title, rows) do
    ["", "  #{title}:"] ++
      Enum.flat_map(rows, fn r ->
        [
          "    #{r.stage} p=#{sig(r.probability)}#{if r.cause, do: " cause=#{r.cause}", else: ""} tags=#{Enum.join(r.tags, ",")}",
          "      #{brief(r.left)}",
          "      #{brief(r.right)}"
        ]
      end)
  end

  defp brief(nil), do: "-"

  defp brief(r) do
    [
      r[:source],
      "#{r[:given_name]} #{r[:family_name]}",
      r[:dob],
      r[:sex],
      r[:zip],
      r[:phone],
      r[:ssn]
    ]
    |> Enum.map_join(" | ", &(&1 || "·"))
  end

  # ---------------------------------------------------------------- golden

  defp golden_section(nil), do: []

  defp golden_section(results) do
    passed = Enum.count(results, & &1.pass)
    failures = Enum.reject(results, & &1.pass)
    overlay_failures = Enum.count(failures, &(&1.risk == "overlay"))

    by_category =
      results
      |> Enum.group_by(& &1.category)
      |> Enum.sort()
      |> Enum.map(fn {cat, rs} ->
        "    #{pad(cat, 34)} #{Enum.count(rs, & &1.pass)}/#{length(rs)}"
      end)

    [
      "",
      rule("golden scenarios"),
      "passed #{passed}/#{length(results)} · failures that would wrongly merge two people: #{overlay_failures}",
      by_category,
      "",
      "  Failures:"
      | Enum.flat_map(failures, fn f ->
          [
            "    [#{f.risk}] #{f.id} — #{f.title}",
            "      expected #{f.expect}, got #{f.outcome}#{if f.probability, do: " (p=#{sig(f.probability)})", else: ""}",
            if(f.levels == [],
              do: [],
              else:
                "      " <>
                  Enum.map_join(f.levels, "  ", fn {field, level, w} ->
                    "#{field}:#{level}(#{w})"
                  end)
            )
          ]
        end)
    ]
  end

  # -------------------------------------------------------------- baseline

  @tracked [:blocking_recall, :precision, :recall, :recall_with_review, :false_matches, :review]

  defp baseline_section(_runs, _golden, nil),
    do: ["", "(no baseline; save one with --save-baseline)"]

  defp baseline_section(runs, golden, baseline) do
    run_lines =
      for m <- runs, old = baseline["runs"][m.name], old != nil do
        deltas =
          for key <- @tracked, is_number(Map.get(m, key)), is_number(old[to_string(key)]) do
            delta(key, old[to_string(key)], Map.get(m, key))
          end

        "    #{pad(m.name, 34)} #{Enum.join(deltas, "  ")}"
      end

    flips =
      for g <- golden || [], old = baseline["golden"][g.id], old != nil, old != g.pass do
        "    #{if g.pass, do: "fixed  ", else: "BROKEN "} #{g.id} (now #{g.outcome})"
      end

    ["", rule("vs baseline (#{baseline["saved_at"]})") | run_lines] ++
      if(flips == [], do: ["    golden: no changes"], else: flips)
  end

  defp delta(key, old, new) when key in [:false_matches, :review],
    do: "#{key} #{int(new)} (#{signed(new - old, 0)})"

  defp delta(key, old, new), do: "#{key} #{pct(new)} (#{signed((new - old) * 100, 1)}pp)"

  defp signed(x, 0), do: if(x >= 0, do: "+#{round(x)}", else: "#{round(x)}")

  defp signed(x, d),
    do: if(x >= 0, do: "+#{Float.round(x * 1.0, d)}", else: "#{Float.round(x * 1.0, d)}")

  # ----------------------------------------------------------------- format

  defp counts(map) when map_size(map) == 0, do: "none"

  defp counts(map),
    do: map |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)

  defp rule(title), do: "== #{title} " <> String.duplicate("=", max(0, 76 - String.length(title)))
  defp pct(nil), do: "n/a"
  defp pct(x), do: "#{:erlang.float_to_binary(x * 100.0, decimals: 1)}%"
  defp sig(nil), do: "n/a"
  defp sig(x) when x < 0.001 and x > 0, do: :erlang.float_to_binary(x * 1.0, [{:scientific, 2}])
  defp sig(x), do: :erlang.float_to_binary(x * 1.0, decimals: 4)
  defp secs(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)}s"
  defp pad(s, n), do: String.pad_trailing(to_string(s), n)

  defp int(n) when is_integer(n),
    do:
      n
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()
end
