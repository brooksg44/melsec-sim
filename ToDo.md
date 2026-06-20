# ToDo

## SVG Renderer — DONE

Shipped in v0.5.0.

### Task

- **SVG renderer** ✓ (`svg.lisp`, `melsec-sim/svg`)
  - Dependency-free: only `melsec-sim`, `melsec-sim/ir`, `melsec-sim/layout`.
  - Contacts with NO/NC styling; coil arcs forming `( )` / `(S)` / `(R)`;
    two-cell-wide timer/counter boxes showing `CV/PT`; shaded FB boxes for
    MOV/ADD/SUB/CMP.
  - Pass `:plc` to colour energised elements green.
  - Entry points: `render-to-file`, `render-to-string`, `render-to-stream`.

### Entry point

```lisp
(ql:quickload "melsec-sim/svg")
(melsec-sim.svg:render-to-file melsec-sim:*example-program* #p"ladder.svg")
(melsec-sim.svg:render-to-file melsec-sim:*example-program* #p"ladder.svg" :plc *plc*)
```

---

## McCLIM Ladder Diagram Display — DONE

All five tasks completed and shipped in v0.4.0.

### Tasks

1. **Stack-to-tree IL parser** ✓ (`il-to-ir.lisp`, `melsec-sim/ir`)
   - Groups flat IL into rungs; reconstructs the boolean tree from stack ops.
   - Handles LD/LDI, AND/ANI, OR/ORI, ANB/ORB, MPS/MRD/MPP, all output kinds.

2. **Layout engine** ✓ (`layout.lisp`, `melsec-sim/layout`)
   - Two-pass grid layout; emits `:contact`, `:coil`, `:wire`, `:fb` primitives.
   - Backend-agnostic: same output feeds McCLIM and any future SVG renderer.

3. **McCLIM drawing/UI** ✓ (`clim-ui.lisp`, `melsec-sim/clim`)
   - Ladder pane (4/5) + I/O pane (1/5) + Commands interactor.
   - Live green/grey energised colouring.
   - Clickable operand labels (`with-output-as-presentation` → Toggle command).
   - Timer/counter boxes show CV/PT (e.g. `300ms/1000ms`, `2/3`).
   - Step / Scan / Run / Stop commands; Run uses tick-event pattern so the
     interactor stays usable while free-running.

4. **Wire into scan loop** ✓
   - Free-run ticker thread queues `tick-event`s; `handle-event` calls
     `plc-step` and `redisplay-frame-panes` in the frame's own process.

5. **Dependency** ✓
   - `melsec-sim/clim` system in `melsec-sim.asd`; `:depends-on ("mcclim")`.
   - Core stays lightweight — GUI is opt-in.

### Entry point

```lisp
(ql:quickload "melsec-sim/clim")
(melsec-sim.clim:run)
(melsec-sim.clim:run :program my-program :scan-time-ms 50)
```

### Known environment issues

See README Troubleshooting section for the `cl-ppcre`/`cl-unicode` symbol
error that can occur with Quicklisp dist 2026-01-01 on macOS.
