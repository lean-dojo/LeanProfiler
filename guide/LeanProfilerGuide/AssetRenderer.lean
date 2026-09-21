/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import LeanProfiler

/-!
# Guide asset renderer

Renders the guide's timelines, summaries, comparisons, and explanatory diagrams. Data figures read
checked-in LeanProfiler artifacts. Every figure uses stable sorting and integer coordinates so the
SVG output is reproducible.
-/

namespace LeanProfilerGuide.AssetRenderer

open Lean
open LeanProfiler

/-- Trace fields needed by the static timeline. -/
private structure TraceSpan where
  name : String
  startNs : Nat
  durationNs : Nat
  depth : Nat
  threadId : Nat
  phase : Option String
  step : Option Nat
  deriving Inhabited

private def readJson (path : System.FilePath) : IO Json := do
  let contents ← IO.FS.readFile path
  match Json.parse contents with
  | .ok json => pure json
  | .error message =>
      throw <| IO.userError s!"{path}: invalid JSON: {message}"

private def field (path key : String) (json : Json) : Except String Json :=
  match json.getObjVal? key with
  | .ok value => .ok value
  | .error message => .error s!"{path}.{key}: {message}"

private def stringField (path key : String) (json : Json) : Except String String := do
  let value ← field path key json
  match value.getStr? with
  | .ok text => pure text
  | .error message => throw s!"{path}.{key}: {message}"

private def natField (path key : String) (json : Json) : Except String Nat := do
  let value ← field path key json
  match value.getNat? with
  | .ok number => pure number
  | .error message => throw s!"{path}.{key}: {message}"

private def optionalStringField (path key : String) (json : Json) :
    Except String (Option String) := do
  let value ← field path key json
  match value with
  | .null => pure none
  | value =>
      match value.getStr? with
      | .ok text => pure (some text)
      | .error message => throw s!"{path}.{key}: {message}"

private def optionalNatField (path key : String) (json : Json) :
    Except String (Option Nat) := do
  let value ← field path key json
  match value with
  | .null => pure none
  | value =>
      match value.getNat? with
      | .ok number => pure (some number)
      | .error message => throw s!"{path}.{key}: {message}"

private def parseTraceSpan (path : String) (json : Json) : Except String TraceSpan := do
  let arguments ← field path "args" json
  let metadata ← field s!"{path}.args" "metadata" arguments
  pure {
    name := ← stringField path "name" json
    startNs := ← natField s!"{path}.args" "start_ns" arguments
    durationNs := ← natField s!"{path}.args" "duration_ns" arguments
    depth := ← natField s!"{path}.args" "depth" arguments
    threadId := ← natField path "tid" json
    phase := ← optionalStringField s!"{path}.args.metadata" "phase" metadata
    step := ← optionalNatField s!"{path}.args.metadata" "step" metadata
  }

private def parseTraceSpans (json : Json) : Except String (Array TraceSpan) := do
  let traceEvents ← field "$" "traceEvents" json
  let items ←
    match traceEvents.getArr? with
    | .ok items => pure items
    | .error message => throw s!"$.traceEvents: {message}"
  let mut spans := #[]
  for index in [:items.size] do
    let item := items[index]!
    match stringField s!"$.traceEvents[{index}]" "ph" item with
    | .ok "X" =>
        spans := spans.push (← parseTraceSpan s!"$.traceEvents[{index}]" item)
    | .ok _ => pure ()
    | .error message => throw message
  if spans.isEmpty then
    throw "$.traceEvents: expected at least one complete span"
  pure spans

private def xmlEscape (value : String) : String :=
  value
    |>.replace "&" "&amp;"
    |>.replace "<" "&lt;"
    |>.replace ">" "&gt;"
    |>.replace "\"" "&quot;"
    |>.replace "'" "&apos;"

private def phaseColor : Option String → String
  | some "forward" => "#168c80"
  | some "input" => "#d97706"
  | some "analysis" => "#168c80"
  | some "read" => "#d97706"
  | some "backward" => "#8b5cf6"
  | some "training" => "#6d5cae"
  | some "inference" => "#168c80"
  | _ => "#425466"

private def traceLabel (span : TraceSpan) : String :=
  match span.step with
  | none => span.name
  | some step => s!"{span.name} · step {step}"

private def indexOfNat (values : Array Nat) (needle : Nat) : Nat :=
  (List.range values.size).find? (fun index => values[index]! == needle) |>.getD 0

private def uniqueThreads (spans : Array TraceSpan) : Array Nat :=
  (spans.foldl (init := #[]) fun threads span =>
    if threads.contains span.threadId then threads else threads.push span.threadId)
    |>.qsort (· < ·)

/--
Render the investigation that connects an application question to the two LeanProfiler artifacts.
-/
private def workflowSvg : String :=
  r##"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="286" viewBox="0 0 1120 286" role="img" aria-labelledby="workflow-title workflow-desc">
  <title id="workflow-title">A LeanProfiler investigation from question to regression gate</title>
  <desc id="workflow-desc">Five connected stages show a performance question, application instrumentation, a measured run, the timeline and summary artifacts, and the resulting diagnosis or regression gate.</desc>
  <defs>
    <marker id="workflow-arrow" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#7b8794"/>
    </marker>
  </defs>
  <rect width="100%" height="100%" fill="#fbfcfe" rx="8"/>
  <text x="24" y="34" font-family="system-ui, sans-serif" font-size="21" font-weight="700" fill="#152536">From a slowdown to evidence</text>
  <text x="24" y="58" font-family="system-ui, sans-serif" font-size="13" fill="#58677a">One trace explains the run; one summary supports repeatable comparisons.</text>

  <rect x="24" y="92" width="184" height="112" rx="7" fill="#ffffff" stroke="#cfd8e3" stroke-width="2"/>
  <text x="44" y="121" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#152536">1  Ask</text>
  <text x="44" y="150" font-family="system-ui, sans-serif" font-size="13" fill="#425466">Why did this command</text>
  <text x="44" y="171" font-family="system-ui, sans-serif" font-size="13" fill="#425466">become slower?</text>

  <line x1="216" y1="148" x2="238" y2="148" stroke="#7b8794" stroke-width="2" marker-end="url(#workflow-arrow)"/>
  <rect x="248" y="92" width="184" height="112" rx="7" fill="#ffffff" stroke="#cfd8e3" stroke-width="2"/>
  <text x="268" y="121" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#152536">2  Name boundaries</text>
  <text x="268" y="150" font-family="ui-monospace, monospace" font-size="12" fill="#187d75">source.parse</text>
  <text x="268" y="171" font-family="ui-monospace, monospace" font-size="12" fill="#187d75">index.write</text>

  <line x1="440" y1="148" x2="462" y2="148" stroke="#7b8794" stroke-width="2" marker-end="url(#workflow-arrow)"/>
  <rect x="472" y="92" width="184" height="112" rx="7" fill="#ffffff" stroke="#cfd8e3" stroke-width="2"/>
  <text x="492" y="121" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#152536">3  Measure a run</text>
  <text x="492" y="150" font-family="system-ui, sans-serif" font-size="13" fill="#425466">Monotonic time</text>
  <text x="492" y="171" font-family="system-ui, sans-serif" font-size="13" fill="#425466">and Lean heartbeats</text>

  <line x1="664" y1="148" x2="686" y2="148" stroke="#7b8794" stroke-width="2" marker-end="url(#workflow-arrow)"/>
  <rect x="696" y="78" width="184" height="66" rx="7" fill="#e9f5f3" stroke="#8cc9c3" stroke-width="2"/>
  <text x="716" y="107" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#145f59">Timeline</text>
  <text x="716" y="128" font-family="system-ui, sans-serif" font-size="12" fill="#425466">Order, nesting, metadata</text>
  <rect x="696" y="156" width="184" height="66" rx="7" fill="#eef3f8" stroke="#aebed0" stroke-width="2"/>
  <text x="716" y="185" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#294d73">Summary</text>
  <text x="716" y="206" font-family="system-ui, sans-serif" font-size="12" fill="#425466">Rows, percentiles, counters</text>

  <line x1="888" y1="148" x2="910" y2="148" stroke="#7b8794" stroke-width="2" marker-end="url(#workflow-arrow)"/>
  <rect x="920" y="92" width="176" height="112" rx="7" fill="#ffffff" stroke="#cfd8e3" stroke-width="2"/>
  <text x="940" y="121" font-family="system-ui, sans-serif" font-size="14" font-weight="700" fill="#152536">5  Act</text>
  <text x="940" y="150" font-family="system-ui, sans-serif" font-size="13" fill="#425466">Diagnose the trace</text>
  <text x="940" y="171" font-family="system-ui, sans-serif" font-size="13" fill="#425466">or gate a regression</text>

  <text x="24" y="255" font-family="system-ui, sans-serif" font-size="12" fill="#58677a">Trace Event JSON opens in Perfetto. Versioned summary JSON feeds repeatable comparisons.</text>
</svg>
"##

/-- Render a nested, per-thread timeline from complete Trace Event spans. -/
private def timelineSvg (spans : Array TraceSpan) : String := Id.run do
  let spans := spans.qsort fun left right =>
    left.threadId < right.threadId ||
      (left.threadId == right.threadId &&
        (left.startNs < right.startNs ||
          (left.startNs == right.startNs && left.depth < right.depth)))
  let first := spans[0]!
  let origin := spans.foldl (init := first.startNs) fun current span =>
    min current span.startNs
  let finish := spans.foldl (init := first.startNs + first.durationNs) fun current span =>
    max current (span.startNs + span.durationNs)
  let window := max 1 (finish - origin)
  let maxDepth := spans.foldl (init := 0) fun current span => max current span.depth
  let threads := uniqueThreads spans
  let width := 1120
  let left := 190
  let plotWidth := 880
  let rowHeight := 38
  let laneHeight := 40 + (maxDepth + 1) * rowHeight
  let height := 120 + threads.size * laneHeight
  let axisY := height - 34
  let mut lines : Array String := #[
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\" role=\"img\" aria-labelledby=\"timeline-title timeline-desc\">",
    "  <title id=\"timeline-title\">Nested spans from the LeanProfiler example</title>",
    "  <desc id=\"timeline-desc\">One root span contains three alternating source-read and source-analysis spans on one Lean thread. Horizontal position and width show elapsed time.</desc>",
    "  <rect width=\"100%\" height=\"100%\" fill=\"#fbfcfe\" rx=\"12\"/>",
    "  <text x=\"24\" y=\"31\" font-family=\"system-ui, sans-serif\" font-size=\"20\" font-weight=\"700\" fill=\"#152536\">Nested span timeline</text>",
    s!"  <text x=\"24\" y=\"53\" font-family=\"system-ui, sans-serif\" font-size=\"13\" fill=\"#58677a\">{spans.size} spans · {threads.size} Lean thread · {xmlEscape (formatDuration window)} window</text>"
  ]
  for lane in [:threads.size] do
    let laneTop := 70 + lane * laneHeight
    lines := lines.push <|
      s!"  <text x=\"24\" y=\"{laneTop + 18}\" font-family=\"ui-monospace, monospace\" font-size=\"12\" fill=\"#58677a\">thread {threads[lane]!}</text>"
    lines := lines.push <|
      s!"  <line x1=\"{left}\" y1=\"{laneTop + laneHeight - 8}\" x2=\"{left + plotWidth}\" y2=\"{laneTop + laneHeight - 8}\" stroke=\"#d9e1ea\" stroke-width=\"1\"/>"
  for span in spans do
    let lane := indexOfNat threads span.threadId
    let x := left + ((span.startNs - origin) * plotWidth) / window
    let barWidth := max 2 ((span.durationNs * plotWidth) / window)
    let y := 74 + lane * laneHeight + span.depth * rowHeight
    let label := traceLabel span
    -- Keep narrow bars readable; the full step label remains in the tooltip and ARIA text.
    let visibleLabel := if barWidth ≥ 150 then label else span.name
    let description :=
      s!"{label}; total {formatDuration span.durationNs}; thread {span.threadId}; depth {span.depth}"
    lines := lines.push <|
      s!"  <g aria-label=\"{xmlEscape description}\"><rect x=\"{x}\" y=\"{y}\" width=\"{barWidth}\" height=\"27\" rx=\"5\" fill=\"{phaseColor span.phase}\" opacity=\"0.94\"><title>{xmlEscape description}</title></rect></g>"
    if barWidth ≥ 88 then
      lines := lines.push <|
        s!"  <text x=\"{x + 8}\" y=\"{y + 18}\" font-family=\"system-ui, sans-serif\" font-size=\"12\" font-weight=\"650\" fill=\"#ffffff\" pointer-events=\"none\">{xmlEscape visibleLabel}</text>"
  for tick in [0, 1, 2, 3, 4] do
    let x := left + (tick * plotWidth) / 4
    let value := (tick * window) / 4
    lines := lines.push <|
      s!"  <line x1=\"{x}\" y1=\"62\" x2=\"{x}\" y2=\"{axisY}\" stroke=\"#d9e1ea\" stroke-width=\"1\" stroke-dasharray=\"3 5\"/>"
    lines := lines.push <|
      s!"  <text x=\"{x}\" y=\"{axisY + 20}\" text-anchor=\"middle\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#58677a\">{xmlEscape (formatDuration value)}</text>"
  lines := lines.push "</svg>"
  return String.intercalate "\n" lines.toList ++ "\n"

/-- Render inclusive and self time for every grouped row in a summary artifact. -/
private def breakdownSvg (summary : SummaryArtifact) : String := Id.run do
  let rows := summary.rows.qsort fun left right => left.totalNs > right.totalNs
  let width := 1120
  let left := 270
  let plotWidth := 650
  let rowHeight := 78
  let height := 132 + rows.size * rowHeight
  let maxValue := max 1 <| rows.foldl (init := 0) fun current row =>
    max current row.totalNs
  let mut lines : Array String := #[
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\" role=\"img\" aria-labelledby=\"breakdown-title breakdown-desc\">",
    "  <title id=\"breakdown-title\">Inclusive and self time in the nested example</title>",
    "  <desc id=\"breakdown-desc\">Horizontal bars compare inclusive duration with self duration for the root, source-analysis, and source-read summary rows.</desc>",
    "  <rect width=\"100%\" height=\"100%\" fill=\"#fbfcfe\" rx=\"8\"/>",
    "  <text x=\"24\" y=\"32\" font-family=\"system-ui, sans-serif\" font-size=\"20\" font-weight=\"700\" fill=\"#152536\">Where the recorded time went</text>",
    "  <text x=\"24\" y=\"54\" font-family=\"system-ui, sans-serif\" font-size=\"13\" fill=\"#58677a\">Outlined bars show inclusive time; solid bars show self time after same-thread children are removed.</text>",
    "  <rect x=\"24\" y=\"72\" width=\"18\" height=\"10\" rx=\"2\" fill=\"#dce5ee\" stroke=\"#aebed0\"/>",
    "  <text x=\"50\" y=\"82\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">inclusive</text>",
    "  <rect x=\"126\" y=\"72\" width=\"18\" height=\"10\" rx=\"2\" fill=\"#425466\"/>",
    "  <text x=\"152\" y=\"82\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">self</text>"
  ]
  for index in [:rows.size] do
    let row := rows[index]!
    let y := 112 + index * rowHeight
    let inclusiveWidth := max 2 ((row.totalNs * plotWidth) / maxValue)
    let selfWidth := max 2 ((row.selfNs * plotWidth) / maxValue)
    let color := phaseColor row.key.phase
    let description :=
      s!"{row.key.name}; inclusive {formatDuration row.totalNs}; self {formatDuration row.selfNs}; {row.calls} calls"
    lines := lines.push <|
      s!"  <text x=\"24\" y=\"{y + 5}\" font-family=\"system-ui, sans-serif\" font-size=\"14\" font-weight=\"650\" fill=\"#152536\">{xmlEscape row.key.name}</text>"
    lines := lines.push <|
      s!"  <text x=\"24\" y=\"{y + 27}\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">{row.calls} call{if row.calls == 1 then "" else "s"}</text>"
    lines := lines.push <|
      s!"  <g aria-label=\"{xmlEscape description}\"><rect x=\"{left}\" y=\"{y - 12}\" width=\"{inclusiveWidth}\" height=\"32\" rx=\"5\" fill=\"#dce5ee\" stroke=\"#aebed0\" stroke-width=\"1\"><title>{xmlEscape description}</title></rect><rect x=\"{left}\" y=\"{y - 3}\" width=\"{selfWidth}\" height=\"14\" rx=\"4\" fill=\"{color}\"><title>{xmlEscape description}</title></rect></g>"
    lines := lines.push <|
      s!"  <text x=\"{left + plotWidth + 18}\" y=\"{y - 1}\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#58677a\">total {xmlEscape (formatDuration row.totalNs)}</text>"
    lines := lines.push <|
      s!"  <text x=\"{left + plotWidth + 18}\" y=\"{y + 17}\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"{color}\">self  {xmlEscape (formatDuration row.selfNs)}</text>"
  lines := lines.push "</svg>"
  return String.intercalate "\n" lines.toList ++ "\n"

private def statusColor : MatchedStatus → String
  | .regression => "#c73e3e"
  | .improvement => "#168c80"
  | .withinTolerance => "#3b6fb6"

private def statusLabel : MatchedStatus → String
  | .regression => "regression"
  | .improvement => "improvement"
  | .withinTolerance => "within tolerance"

/-- Render paired baseline and candidate values from LeanProfiler's own comparison result. -/
private def comparisonSvg (comparison : PerformanceComparison) : String := Id.run do
  let rows := comparison.matched
  let width := 1120
  let left := 300
  let plotWidth := 650
  let rowHeight := 76
  let height := 128 + rows.size * rowHeight
  let maxValue := max 1 <| rows.foldl (init := 0) fun current row =>
    max current (max row.baselineValue row.candidateValue)
  let mut lines : Array String := #[
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\" role=\"img\" aria-labelledby=\"comparison-title comparison-desc\">",
    "  <title id=\"comparison-title\">Baseline and candidate p95 comparison</title>",
    "  <desc id=\"comparison-desc\">Paired dots compare p95 duration for three span groups. The candidate increases the analysis delay, causing source.analyze and the enclosing example span to regress.</desc>",
    "  <rect width=\"100%\" height=\"100%\" fill=\"#fbfcfe\" rx=\"12\"/>",
    "  <text x=\"24\" y=\"31\" font-family=\"system-ui, sans-serif\" font-size=\"20\" font-weight=\"700\" fill=\"#152536\">p95 comparison</text>",
    "  <text x=\"24\" y=\"53\" font-family=\"system-ui, sans-serif\" font-size=\"13\" fill=\"#58677a\">Policy: 0.5 ms absolute and 10% relative allowance; an increase must cross both.</text>",
    "  <circle cx=\"24\" cy=\"79\" r=\"6\" fill=\"#263849\"/>",
    "  <text x=\"37\" y=\"83\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">baseline</text>",
    "  <circle cx=\"112\" cy=\"79\" r=\"6\" fill=\"#c73e3e\"/>",
    "  <text x=\"125\" y=\"83\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">candidate</text>"
  ]
  for index in [:rows.size] do
    let row := rows[index]!
    let y := 118 + index * rowHeight
    let baselineX := left + (row.baselineValue * plotWidth) / maxValue
    let candidateX := left + (row.candidateValue * plotWidth) / maxValue
    let color := statusColor row.status
    let description :=
      s!"{row.key.label}; baseline {formatDuration row.baselineValue}; candidate {formatDuration row.candidateValue}; {statusLabel row.status}"
    lines := lines.push <|
      s!"  <text x=\"24\" y=\"{y + 4}\" font-family=\"system-ui, sans-serif\" font-size=\"14\" font-weight=\"650\" fill=\"#152536\">{xmlEscape row.key.name}</text>"
    lines := lines.push <|
      s!"  <text x=\"24\" y=\"{y + 24}\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"{color}\">{xmlEscape (statusLabel row.status)}</text>"
    lines := lines.push <|
      s!"  <line x1=\"{left}\" y1=\"{y}\" x2=\"{left + plotWidth}\" y2=\"{y}\" stroke=\"#d9e1ea\" stroke-width=\"2\"/>"
    lines := lines.push <|
      s!"  <line x1=\"{min baselineX candidateX}\" y1=\"{y}\" x2=\"{max baselineX candidateX}\" y2=\"{y}\" stroke=\"{color}\" stroke-width=\"4\" opacity=\"0.55\"/>"
    lines := lines.push <|
      s!"  <g aria-label=\"{xmlEscape description}\"><circle cx=\"{baselineX}\" cy=\"{y}\" r=\"7\" fill=\"#263849\"><title>{xmlEscape description}</title></circle><circle cx=\"{candidateX}\" cy=\"{y}\" r=\"8\" fill=\"{color}\"><title>{xmlEscape description}</title></circle></g>"
    lines := lines.push <|
      s!"  <text x=\"{left + plotWidth + 18}\" y=\"{y - 3}\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#263849\">B {xmlEscape (formatDuration row.baselineValue)}</text>"
    lines := lines.push <|
      s!"  <text x=\"{left + plotWidth + 18}\" y=\"{y + 15}\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"{color}\">C {xmlEscape (formatDuration row.candidateValue)}</text>"
  lines := lines.push "</svg>"
  return String.intercalate "\n" lines.toList ++ "\n"

/-- Render the schedule used in the guide's repeated-capture example. -/
private def scheduleSvg : String :=
  r##"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="260" viewBox="0 0 1120 260" role="img" aria-labelledby="schedule-title schedule-desc">
  <title id="schedule-title">Two cycles of a LeanProfiler capture schedule</title>
  <desc id="schedule-desc">Fourteen numbered steps show two initial skipped steps followed by two cycles containing one wait, two warmup, two record, and one record-and-save step.</desc>
  <rect width="100%" height="100%" fill="#fbfcfe" rx="8"/>
  <text x="24" y="34" font-family="system-ui, sans-serif" font-size="20" font-weight="700" fill="#152536">One long run, two short captures</text>
  <text x="24" y="57" font-family="system-ui, sans-serif" font-size="13" fill="#58677a">skipFirst = 2 · wait = 1 · warmup = 2 · active = 3 · repeatCount = 2</text>
  <rect x="24" y="88" width="70" height="62" rx="6" fill="#e7ebef"/><text x="59" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#425466">skip</text><text x="59" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#6b7785">0</text>
  <rect x="100" y="88" width="70" height="62" rx="6" fill="#e7ebef"/><text x="135" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#425466">skip</text><text x="135" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#6b7785">1</text>
  <rect x="186" y="76" width="444" height="92" rx="8" fill="none" stroke="#aebed0" stroke-width="2"/><text x="198" y="69" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#425466">cycle 1</text>
  <rect x="196" y="88" width="66" height="62" rx="6" fill="#e7ebef"/><text x="229" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#425466">wait</text><text x="229" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#6b7785">2</text>
  <rect x="268" y="88" width="66" height="62" rx="6" fill="#fff0d9"/><text x="301" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#9a560f">warm</text><text x="301" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#9a560f">3</text>
  <rect x="340" y="88" width="66" height="62" rx="6" fill="#fff0d9"/><text x="373" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#9a560f">warm</text><text x="373" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#9a560f">4</text>
  <rect x="412" y="88" width="66" height="62" rx="6" fill="#e9f5f3"/><text x="445" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">record</text><text x="445" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#145f59">5</text>
  <rect x="484" y="88" width="66" height="62" rx="6" fill="#e9f5f3"/><text x="517" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">record</text><text x="517" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#145f59">6</text>
  <rect x="556" y="88" width="64" height="62" rx="6" fill="#187d75"/><text x="588" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#ffffff">save</text><text x="588" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#ffffff">7</text>
  <rect x="646" y="76" width="450" height="92" rx="8" fill="none" stroke="#aebed0" stroke-width="2"/><text x="658" y="69" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#425466">cycle 2</text>
  <rect x="656" y="88" width="66" height="62" rx="6" fill="#e7ebef"/><text x="689" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#425466">wait</text><text x="689" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#6b7785">8</text>
  <rect x="728" y="88" width="66" height="62" rx="6" fill="#fff0d9"/><text x="761" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#9a560f">warm</text><text x="761" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#9a560f">9</text>
  <rect x="800" y="88" width="66" height="62" rx="6" fill="#fff0d9"/><text x="833" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#9a560f">warm</text><text x="833" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#9a560f">10</text>
  <rect x="872" y="88" width="66" height="62" rx="6" fill="#e9f5f3"/><text x="905" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">record</text><text x="905" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#145f59">11</text>
  <rect x="944" y="88" width="66" height="62" rx="6" fill="#e9f5f3"/><text x="977" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">record</text><text x="977" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#145f59">12</text>
  <rect x="1016" y="88" width="70" height="62" rx="6" fill="#187d75"/><text x="1051" y="115" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#ffffff">save</text><text x="1051" y="137" text-anchor="middle" font-family="ui-monospace, monospace" font-size="11" fill="#ffffff">13</text>
  <text x="24" y="205" font-family="system-ui, sans-serif" font-size="13" fill="#425466">Warmup executes the workload without retaining measurements. Each save step closes one active capture.</text>
  <text x="24" y="228" font-family="system-ui, sans-serif" font-size="12" fill="#58677a">The schedule decides when to measure; the surrounding loop still owns the application state and workload.</text>
</svg>
"##

/-- Render the observation boundaries of Lean, application, and foreign-runtime profiling tools. -/
private def profilerScopeSvg : String :=
  r##"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="430" viewBox="0 0 1120 430" role="img" aria-labelledby="scope-title scope-desc">
  <title id="scope-title">Observation boundaries of Lean, application, and foreign-runtime profilers</title>
  <desc id="scope-desc">Three columns show that Lean profilers observe elaboration and compilation, LeanProfiler observes named application regions and Lean heartbeats, and foreign-runtime profilers observe native library or device activity.</desc>
  <rect width="100%" height="100%" fill="#fbfcfe" rx="8"/>
  <text x="24" y="34" font-family="system-ui, sans-serif" font-size="20" font-weight="700" fill="#152536">Three views of one program</text>
  <text x="24" y="57" font-family="system-ui, sans-serif" font-size="13" fill="#58677a">Each profiler begins and ends at a different boundary.</text>

  <rect x="24" y="88" width="332" height="272" rx="8" fill="#ffffff" stroke="#cfd8e3" stroke-width="2"/>
  <text x="48" y="122" font-family="system-ui, sans-serif" font-size="17" font-weight="700" fill="#294d73">Lean profiling tools</text>
  <text x="48" y="149" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#6b7785">BUILD AND ELABORATION</text>
  <rect x="48" y="172" width="284" height="42" rx="5" fill="#eef3f8"/><text x="64" y="198" font-family="system-ui, sans-serif" font-size="13" fill="#294d73">declaration elaboration</text>
  <rect x="48" y="224" width="284" height="42" rx="5" fill="#eef3f8"/><text x="64" y="250" font-family="system-ui, sans-serif" font-size="13" fill="#294d73">type checking and compiler components</text>
  <rect x="48" y="276" width="284" height="42" rx="5" fill="#eef3f8"/><text x="64" y="302" font-family="system-ui, sans-serif" font-size="13" fill="#294d73">nested elaborator trace</text>
  <text x="48" y="342" font-family="ui-monospace, monospace" font-size="12" fill="#58677a">lean --profile · trace.profiler</text>

  <rect x="394" y="88" width="332" height="272" rx="8" fill="#ffffff" stroke="#8cc9c3" stroke-width="2"/>
  <text x="418" y="122" font-family="system-ui, sans-serif" font-size="17" font-weight="700" fill="#145f59">LeanProfiler</text>
  <text x="418" y="149" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#6b7785">RUNNING LEAN APPLICATION</text>
  <rect x="418" y="172" width="284" height="42" rx="5" fill="#e9f5f3"/><text x="434" y="198" font-family="system-ui, sans-serif" font-size="13" fill="#145f59">named phases, modules, and steps</text>
  <rect x="418" y="224" width="284" height="42" rx="5" fill="#e9f5f3"/><text x="434" y="250" font-family="system-ui, sans-serif" font-size="13" fill="#145f59">host elapsed time and heartbeats</text>
  <rect x="418" y="276" width="284" height="42" rx="5" fill="#e9f5f3"/><text x="434" y="302" font-family="system-ui, sans-serif" font-size="13" fill="#145f59">strict summaries and comparisons</text>
  <text x="418" y="342" font-family="ui-monospace, monospace" font-size="12" fill="#58677a">span · profile · compare</text>

  <rect x="764" y="88" width="332" height="272" rx="8" fill="#ffffff" stroke="#dfbd8b" stroke-width="2"/>
  <text x="788" y="122" font-family="system-ui, sans-serif" font-size="17" font-weight="700" fill="#9a560f">Foreign runtime profiler</text>
  <text x="788" y="149" font-family="system-ui, sans-serif" font-size="12" font-weight="650" fill="#6b7785">LIBRARY AND DEVICE RUNTIME</text>
  <rect x="788" y="172" width="284" height="42" rx="5" fill="#fff0d9"/><text x="804" y="198" font-family="system-ui, sans-serif" font-size="13" fill="#9a560f">native functions and user ranges</text>
  <rect x="788" y="224" width="284" height="42" rx="5" fill="#fff0d9"/><text x="804" y="250" font-family="system-ui, sans-serif" font-size="13" fill="#9a560f">supported kernels and runtime activity</text>
  <rect x="788" y="276" width="284" height="42" rx="5" fill="#fff0d9"/><text x="804" y="302" font-family="system-ui, sans-serif" font-size="13" fill="#9a560f">stacks, allocations, operators, or FLOPs</text>
  <text x="788" y="342" font-family="ui-monospace, monospace" font-size="12" fill="#58677a">perf · PyTorch Profiler · Nsight</text>

  <line x1="190" y1="386" x2="930" y2="386" stroke="#aeb8c4" stroke-width="2"/>
  <circle cx="190" cy="386" r="6" fill="#294d73"/><circle cx="560" cy="386" r="6" fill="#187d75"/><circle cx="930" cy="386" r="6" fill="#ba6b18"/>
  <text x="560" y="414" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" fill="#425466">Use the views together when work crosses all three boundaries.</text>
</svg>
"##

/-- Render prediction latencies from the checked-in TorchLean trace. -/
private def predictionLatencySvg (spans : Array TraceSpan) (summary : SummaryArtifact) : String :=
    Id.run do
  let predictions :=
    (spans.filter fun span => span.name == "model.predict")
      |>.qsort fun left right => left.startNs < right.startNs
  let first := predictions[0]!
  let minValue := predictions.foldl (init := first.durationNs) fun current span =>
    min current span.durationNs
  let maxValue := predictions.foldl (init := first.durationNs) fun current span =>
    max current span.durationNs
  let range := max 1 (maxValue - minValue)
  let row := (summary.rows.find? fun row => row.key.name == "model.predict").get!
  let p95 := row.p95Ns
  let median := row.medianNs
  let metadata := String.intercalate " · "
    ([row.key.device, row.key.backend, row.key.dtype].filterMap id)
  let width := 1120
  let left := 120
  let plotWidth := 850
  let plotTop := 96
  let plotHeight := 180
  let denominator := max 1 (predictions.size - 1)
  let yOf := fun value =>
    plotTop + plotHeight - (((value - minValue) * plotHeight) / range)
  let mut points : Array String := #[]
  let mut lines : Array String := #[
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    s!"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"354\" viewBox=\"0 0 {width} 354\" role=\"img\" aria-labelledby=\"latency-title latency-desc\">",
    "  <title id=\"latency-title\">TorchLean MLP prediction latency</title>",
    s!"  <desc id=\"latency-desc\">{predictions.size} measured predictions range from {xmlEscape (formatDuration minValue)} to {xmlEscape (formatDuration maxValue)}, with a p95 of {xmlEscape (formatDuration p95)}.</desc>",
    "  <rect width=\"100%\" height=\"100%\" fill=\"#fbfcfe\" rx=\"8\"/>",
    "  <text x=\"24\" y=\"32\" font-family=\"system-ui, sans-serif\" font-size=\"20\" font-weight=\"700\" fill=\"#152536\">TorchLean MLP prediction latency</text>",
    s!"  <text x=\"24\" y=\"54\" font-family=\"system-ui, sans-serif\" font-size=\"13\" fill=\"#58677a\">{predictions.size} measured predictions after warmup · {xmlEscape metadata} · median {xmlEscape (formatDuration median)} · p95 {xmlEscape (formatDuration p95)}</text>",
    s!"  <line x1=\"{left}\" y1=\"{plotTop}\" x2=\"{left + plotWidth}\" y2=\"{plotTop}\" stroke=\"#d9e1ea\" stroke-width=\"1\"/>",
    s!"  <line x1=\"{left}\" y1=\"{plotTop + plotHeight}\" x2=\"{left + plotWidth}\" y2=\"{plotTop + plotHeight}\" stroke=\"#d9e1ea\" stroke-width=\"1\"/>",
    s!"  <line x1=\"{left}\" y1=\"{yOf p95}\" x2=\"{left + plotWidth}\" y2=\"{yOf p95}\" stroke=\"#ba6b18\" stroke-width=\"2\" stroke-dasharray=\"6 5\"/>",
    s!"  <text x=\"{left + plotWidth + 14}\" y=\"{yOf p95 + 4}\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#9a560f\">p95 {xmlEscape (formatDuration p95)}</text>",
    s!"  <text x=\"{left - 14}\" y=\"{plotTop + 4}\" text-anchor=\"end\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#58677a\">{xmlEscape (formatDuration maxValue)}</text>",
    s!"  <text x=\"{left - 14}\" y=\"{plotTop + plotHeight + 4}\" text-anchor=\"end\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#58677a\">{xmlEscape (formatDuration minValue)}</text>"
  ]
  for index in [:predictions.size] do
    let span := predictions[index]!
    let x := left + (index * plotWidth) / denominator
    let y := yOf span.durationNs
    points := points.push s!"{x},{y}"
  lines := lines.push <|
    s!"  <polyline points=\"{String.intercalate " " points.toList}\" fill=\"none\" stroke=\"#187d75\" stroke-width=\"3\"/>"
  for index in [:predictions.size] do
    let span := predictions[index]!
    let x := left + (index * plotWidth) / denominator
    let y := yOf span.durationNs
    let step := span.step.getD index
    let description := s!"prediction {step}; {formatDuration span.durationNs}"
    lines := lines.push <|
      s!"  <line x1=\"{x}\" y1=\"{plotTop}\" x2=\"{x}\" y2=\"{plotTop + plotHeight}\" stroke=\"#edf1f5\" stroke-width=\"1\"/>"
    lines := lines.push <|
      s!"  <text x=\"{x}\" y=\"{plotTop + plotHeight + 24}\" text-anchor=\"middle\" font-family=\"ui-monospace, monospace\" font-size=\"11\" fill=\"#58677a\">{step}</text>"
    lines := lines.push <|
      s!"  <g aria-label=\"{xmlEscape description}\"><circle cx=\"{x}\" cy=\"{y}\" r=\"6\" fill=\"#187d75\" stroke=\"#ffffff\" stroke-width=\"2\"><title>{xmlEscape description}</title></circle></g>"
  lines := lines.push <|
    s!"  <text x=\"{left + plotWidth / 2}\" y=\"{plotTop + plotHeight + 50}\" text-anchor=\"middle\" font-family=\"system-ui, sans-serif\" font-size=\"12\" fill=\"#58677a\">prediction index</text>"
  lines := lines.push "</svg>"
  return String.intercalate "\n" lines.toList ++ "\n"

/-- Show what a synchronized LeanProfiler CUDA span measures and what it leaves to CUPTI. -/
private def cudaBoundarySvg : String :=
  r##"<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="344" viewBox="0 0 1120 344" role="img" aria-labelledby="cuda-title cuda-desc">
  <title id="cuda-title">What a synchronized CUDA span measures</title>
  <desc id="cuda-desc">A LeanProfiler span covers host setup, launches, queue delay, device execution, and final synchronization as one elapsed interval. PyTorch Profiler with CUPTI can expose the individual runtime calls, memory copies, and kernels.</desc>
  <defs>
    <marker id="cuda-arrow" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#7b8794"/>
    </marker>
  </defs>
  <rect width="100%" height="100%" fill="#fbfcfe" rx="8"/>
  <text x="24" y="34" font-family="system-ui, sans-serif" font-size="20" font-weight="700" fill="#152536">What a synchronized CUDA span measures</text>
  <text x="24" y="57" font-family="system-ui, sans-serif" font-size="13" fill="#58677a">LeanProfiler reports one application boundary; PyTorch and CUPTI can resolve activity inside it.</text>

  <text x="24" y="112" font-family="system-ui, sans-serif" font-size="13" font-weight="700" fill="#152536">Lean host</text>
  <line x1="132" y1="108" x2="1060" y2="108" stroke="#aeb8c4" stroke-width="2" marker-end="url(#cuda-arrow)"/>
  <rect x="164" y="86" width="170" height="44" rx="6" fill="#eef3f8" stroke="#aebed0"/><text x="249" y="113" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#294d73">prepare and launch</text>
  <rect x="342" y="86" width="430" height="44" rx="6" fill="#f3f5f7" stroke="#d0d7df"/><text x="557" y="113" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#58677a">host continues / waits</text>
  <rect x="780" y="86" width="238" height="44" rx="6" fill="#fff0d9" stroke="#dfbd8b"/><text x="899" y="113" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#9a560f">cudaDeviceSynchronize</text>

  <text x="24" y="202" font-family="system-ui, sans-serif" font-size="13" font-weight="700" fill="#152536">CUDA device</text>
  <line x1="132" y1="198" x2="1060" y2="198" stroke="#aeb8c4" stroke-width="2" marker-end="url(#cuda-arrow)"/>
  <rect x="376" y="176" width="112" height="44" rx="6" fill="#e9f5f3" stroke="#8cc9c3"/><text x="432" y="203" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">H2D copy</text>
  <rect x="502" y="176" width="132" height="44" rx="6" fill="#dcefeb" stroke="#72b8af"/><text x="568" y="203" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">kernel A</text>
  <rect x="648" y="176" width="96" height="44" rx="6" fill="#dcefeb" stroke="#72b8af"/><text x="696" y="203" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">kernel B</text>
  <rect x="758" y="176" width="112" height="44" rx="6" fill="#e9f5f3" stroke="#8cc9c3"/><text x="814" y="203" text-anchor="middle" font-family="system-ui, sans-serif" font-size="12" fill="#145f59">D2H copy</text>

  <rect x="154" y="74" width="874" height="162" rx="8" fill="none" stroke="#187d75" stroke-width="3"/>
  <text x="164" y="255" font-family="system-ui, sans-serif" font-size="12" font-weight="700" fill="#145f59">LeanProfiler + TorchLean CUDA hook</text>
  <text x="450" y="255" font-family="system-ui, sans-serif" font-size="12" fill="#425466">one elapsed, device-synchronized application span</text>

  <line x1="376" y1="282" x2="870" y2="282" stroke="#ba6b18" stroke-width="3"/>
  <line x1="376" y1="274" x2="376" y2="290" stroke="#ba6b18" stroke-width="3"/><line x1="870" y1="274" x2="870" y2="290" stroke="#ba6b18" stroke-width="3"/>
  <text x="24" y="307" font-family="system-ui, sans-serif" font-size="12" font-weight="700" fill="#9a560f">PyTorch Profiler + CUPTI</text>
  <text x="205" y="307" font-family="system-ui, sans-serif" font-size="12" fill="#425466">individual supported runtime, copy, and kernel activity inside the foreign runtime</text>
</svg>
"##

private def validateCompanionFiles (directory : System.FilePath) : IO Unit := do
  let comparison ← readJson (directory / "comparison.json")
  let metric ←
    match comparison.getObjVal? "metric" >>= Json.getStr? with
    | .ok metric => pure metric
    | .error message => throw <| IO.userError s!"comparison.json.metric: {message}"
  unless metric == "p95_ns" do
    throw <| IO.userError s!"comparison.json.metric: expected p95_ns, found {metric}"
  let _ ← readJson (directory / "capture-provenance.json")
  let _ ← readJson (directory / "torchlean-mlp-provenance.json")

/--
Regenerate the guide's code-native SVG figures from its checked-in JSON artifacts.
-/
def render (directory : System.FilePath) : IO Unit := do
  let trace ← readJson (directory / "nested-spans-trace.json")
  let spans ←
    match parseTraceSpans trace with
    | .ok spans => pure spans
    | .error message => throw <| IO.userError s!"nested-spans-trace.json: {message}"
  let baseline ← readSummaryArtifact (directory / "nested-spans-summary.json")
  let candidate ← readSummaryArtifact (directory / "comparison-candidate-summary.json")
  let torchLeanTrace ← readJson (directory / "torchlean-mlp-trace.json")
  let torchLeanSpans ←
    match parseTraceSpans torchLeanTrace with
    | .ok spans =>
        if spans.any (fun span => span.name == "model.predict") then
          pure spans
        else
          throw <| IO.userError "torchlean-mlp-trace.json: expected model.predict spans"
    | .error message => throw <| IO.userError s!"torchlean-mlp-trace.json: {message}"
  let torchLeanSummary ← readSummaryArtifact (directory / "torchlean-mlp-summary.json")
  unless torchLeanSummary.rows.any (fun row => row.key.name == "model.predict") do
    throw <| IO.userError "torchlean-mlp-summary.json: expected a model.predict row"
  let comparison := compareRows {
    metric := .p95Ns
    threshold := {
      absolute := 500_000
      relativeBps := 1000
    }
  } baseline.rows candidate.rows
  validateCompanionFiles directory
  IO.FS.writeFile (directory / "profiling-workflow.svg") workflowSvg
  IO.FS.writeFile (directory / "nested-spans-timeline.svg") (timelineSvg spans)
  IO.FS.writeFile (directory / "time-breakdown.svg") (breakdownSvg baseline)
  IO.FS.writeFile (directory / "p95-comparison.svg") (comparisonSvg comparison)
  IO.FS.writeFile (directory / "capture-schedule.svg") scheduleSvg
  IO.FS.writeFile (directory / "profiler-scope.svg") profilerScopeSvg
  IO.FS.writeFile (directory / "torchlean-prediction-latency.svg")
    (predictionLatencySvg torchLeanSpans torchLeanSummary)
  IO.FS.writeFile (directory / "cuda-timing-boundary.svg") cudaBoundarySvg

end LeanProfilerGuide.AssetRenderer
