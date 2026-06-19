# melsec-sim

A simple Mitsubishi PLC (MELSEC) Instruction List (IL) simulator written in Common Lisp.

## Overview

`melsec-sim` emulates a subset of the Mitsubishi MELSEC instruction set, including:

- **Contact instructions** — `LD`, `LDI`, `AND`, `ANI`, `OR`, `ORI`
- **Output instructions** — `OUT`, `SET`, `RST`
- **Timer** — `TIM` (TON, on-delay)
- **Counter** — `CNT` (CTU, count-up)

The simulator models a PLC scan cycle: inputs are read, the program is executed
instruction-by-instruction against an internal memory map, and outputs are written.

## Files

| File | Description |
|---|---|
| `melsec-sim.lisp` | Core simulator: PLC class, instruction evaluator, scan loop, helpers |
| `test-sim.lisp` | Verification tests for all three example networks |
| `single-step.lisp` | Single-step / manual scan utilities |
| `continuous.lisp` | Continuous background-thread scan loop utilities |

## Dependencies

- [bordeaux-threads](https://github.com/sionescu/bordeaux-threads) — for background scan thread support (`plc-run` / `plc-stop`)
- [Quicklisp](https://www.quicklisp.org/) — for loading dependencies

## Usage

```lisp
;; Load via SLIME or SBCL
(ql:quickload :bordeaux-threads)
(load "melsec-sim.lisp")
(in-package :melsec-sim)

;; Create a PLC with the built-in example program
(defvar *plc* (make-plc *example-program* :scan-time-ms 100))

;; Set an input and run one scan cycle
(set-input *plc* 'x0 t)   ; press Start
(plc-step *plc*)
(get-output *plc* 'y0)    ; => T  (motor on)

;; Run continuously in a background thread
(plc-run *plc*)
;; ... interact with inputs/outputs ...
(plc-stop *plc*)
```

## Example Program

The built-in `*example-program*` demonstrates three ladder logic networks:

**Network 1 — Motor Start/Stop seal-in**
```
X0 (Start) --|  |--+--[/X1 (Stop)]--( Y0 Motor )
             |     |
Y0 (Motor) --|  |--+
```

**Network 2 — On-delay timer (1000 ms)**
```
Y0 (Motor) --|  |--------------------------( T0 K1000 )
```

**Network 3 — Count-up counter (preset 3)**
```
X2 (Pulse) --|  |--------------------------( C0 K3 )
```

## Running the Tests

```bash
sbcl --noinform --load test-sim.lisp --eval '(quit)'
```

All 11 checks should report `[PASS]`.

## Bug Fixes

### v0.1.1 — Loader errors fixed

**Problem 1: `Y0 is unbound` on file load**

Lines in the ladder diagram comment block used `///` (three forward slashes)
instead of `;;;` (three semicolons). In Common Lisp, `;` is the only line-comment
character. `///` is a special variable (holding the last three REPL results), so
`/// Y0 |` was parsed as three separate top-level forms and `Y0` was evaluated as
an unbound variable.

_Fix:_ All `///` comment lines converted to `;;;`.

**Problem 2: Style warnings for `handle-timer` / `handle-counter`**

`eval-instr` called `handle-timer` and `handle-counter` before they were defined
later in the file, causing SBCL to emit `undefined function` style warnings at
compile time.

_Fix:_ Added `(declaim (ftype function handle-timer handle-counter))` forward
declarations before `eval-instr`.

## License

MIT
