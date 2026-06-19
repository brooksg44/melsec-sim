# ToDo

## McCLIM Ladder Diagram Display

Add an interactive ladder diagram viewer to melsec-sim using McCLIM, similar to
`brooksg44/cl-plc-sim` (`plc-sim/src/clim-ui.lisp`).

### Background

cl-plc-sim uses four layers:

| Layer | File | What it does |
|---|---|---|
| IR | `ir.lisp` | Expression tree (`(:and (:contact :no x0) (:contact :nc x1))`) |
| Layout | `layout.lisp` | Two-pass grid layout → flat backend-agnostic primitive list |
| SVG renderer | `svg.lisp` | Primitives → SVG file |
| McCLIM UI | `clim-ui.lisp` | Primitives → live interactive window |

The key design: `layout.lisp` emits primitives like `(:contact 0 0 :no x0)` and
`(:wire 0 0 2 0)` in grid coordinates; both SVG and McCLIM just map those to
drawing calls. Layout logic never leaks into the graphics toolkit.

### Tasks

1. **Stack-to-tree IL parser** _(hardest, ~2–4 hours)_
   - melsec-sim's program is a flat instruction list; McCLIM wants rung-structured
     expression trees.
   - Group flat IL into rungs: each `out`/`set`/`rst`/`tim`/`cnt` terminates a rung.
   - Reconstruct the boolean tree from stack operations: `ld`+`and` → `:and`,
     `ld`+`or` → `:or`, `anb`/`orb` branches → `:or`/`:and` of sub-expressions.

2. **Layout engine** _(~1–2 hours)_
   - Adapt `layout.lisp` from cl-plc-sim (backend-agnostic, ~200 lines).
   - Primitive format maps cleanly onto melsec-sim instruction types.

3. **McCLIM drawing/UI** _(~1–2 hours)_
   - Adapt `clim-ui.lisp` from cl-plc-sim (~350 lines).
   - Already handles: grid→pixel scaling, green/grey energized coloring, clickable
     operand labels (`with-output-as-presentation`) to toggle inputs, incremental
     redisplay, Step/Scan/Run/Stop interactor commands.
   - Needs: minor adaptation to melsec-sim's memory API (`get-bit`, `get-word`,
     `set-input`).

4. **Wire into scan loop** _(~1 hour)_
   - Trigger `redisplay-frame-panes` after each `plc-step` / scan tick.

5. **Dependency**
   - Add `mcclim` to `melsec-sim.asd` `:depends-on`.
   - New system `melsec-sim/clim` so the GUI is opt-in (core stays lightweight).

### Reference

- cl-plc-sim layout primitives: `(:contact x y mode op)`, `(:coil x y kind op [preset])`,
  `(:wire x1 y1 x2 y2)`, `(:cmp x y op a b)`, `(:assign x y w dst v)`, `(:fb x y w h name)`
- cl-plc-sim entry point: `(plc-sim-clim:run :il #p"examples/motor-seal-in.il")`
- McCLIM docs: https://mcclim.common-lisp.dev/
