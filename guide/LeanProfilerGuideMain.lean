/-
Copyright (c) 2026 LeanProfiler contributors
Released under MIT license.
Authors: LeanProfiler Team
-/

import VersoManual
import LeanProfilerGuide.Manual

open Verso Doc
open Verso.Genre Manual

open Verso Output Html in
private def guideStyles : Html :=
  {{ <link rel="stylesheet" href="Assets/guide.css"/> }}

private def guideConfig : RenderConfig where
  -- Verso copies the checked-in captures and Lean-generated figures beside the rendered pages.
  extraFiles := [("LeanProfilerGuide/Assets", "Assets")]
  extraHead := #[guideStyles]

-- Standalone page titles lack the anchors used by Verso's TOC and permalinks.
-- Use the traversal's page locations, not guessed targets from incoming links.
private partial def addPageAnchors (directory : System.FilePath) (state : TraverseState)
    (depth : Nat) (part : Part Manual) : IO Unit := do
  if let some id := part.metadata.bind (·.id) then
    if let some link := state.externalTags[id]? then
      let path := link.path.foldl (fun path segment => path / segment) directory / "index.html"
      let content ← IO.FS.readFile path
      let identifier := link.htmlId.toString
      if (content.splitOn s!"id=\"{identifier}\"").length == 1 then
        let anchor := Output.Html.tag "span" #[("id", identifier)] .empty
        let updated := content.replace "<main>" ("<main>" ++ anchor.asString)
        if updated == content then
          throw <| IO.userError s!"{path}: missing main element for page anchor {identifier}"
        IO.FS.writeFile path updated
  if depth > 0 && part.htmlSplit != .never then
    for child in part.subParts do
      addPageAnchors directory state (depth - 1) child

/-- Render the LeanProfiler manual with its checked-in artifacts. -/
def main (args : List String) : IO UInt32 :=
  manualMain
    (%doc LeanProfilerGuide.Manual)
    args
    (config := guideConfig)
    (extensionImpls := by exact extension_impls%)
    (extraSteps := [fun mode config state part => do
      match mode with
      | .single => addPageAnchors (config.destination / "html-single") state 0 part
      | .multi => addPageAnchors (config.destination / "html-multi") state config.htmlDepth part])
