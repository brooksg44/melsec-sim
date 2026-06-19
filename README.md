# melsec-sim

[![CI](https://github.com/brooksg44/melsec-sim/actions/workflows/ci.yml/badge.svg)](https://github.com/brooksg44/melsec-sim/actions/workflows/ci.yml)

A Mitsubishi PLC (MELSEC) Instruction List (IL) simulator written in Common Lisp.

## Overview

`melsec-sim` emulates a subset of the Mitsubishi MELSEC instruction set across a
standard PLC scan cycle: inputs are read, the program is executed instruction-by-instruction
against an internal memory map, and outputs are written.

## Instruction Set

### Contact instructions
| Instruction | Description |
|---|---|
| `LD addr` | Load bit (normally open) |
| `LDI addr` | Load inverted bit (normally closed) |
| `AND addr` | Series AND |
| `ANI addr` | Series AND inverted |
| `OR addr` | Parallel OR |
| `ORI addr` | Parallel OR inverted |
| `ANB` | AND two complete branch results on the stack |
| `ORB` | OR two complete branch results on the stack |

### Master control stack
| Instruction | Description |
|---|---|
| `MPS` | Push current accumulator onto the master stack (without consuming it) |
| `MRD` | Copy master stack top onto the accumulator stack |
| `MPP` | Pop master stack top onto the accumulator stack |

### Output instructions
| Instruction | Description |
|---|---|
| `OUT addr` | Write accumulator to coil |
| `SET addr` | Latch coil ON |
| `RST addr` | Reset coil, timer accumulator, or counter (CTD restores count to preset) |

### Timers
| Instruction | Description |
|---|---|
| `TIM addr preset` | TON — on-delay; preset in ms; fires when accumulated ON-time ≥ preset |
| `TOF addr preset` | TOF — off-delay; output ON immediately; stays ON for preset ms after enable drops |

### Counters
| Instruction | Description |
|---|---|
| `CNT addr preset` | CTU — count-up; fires on rising edge when count reaches preset |
| `CTD addr preset` | CTD — count-down; initialises at preset; fires when count reaches 0 |

### Data registers / arithmetic
All instructions below are conditional on the current accumulator (top-of-stack).
Operands may be integer literals or D register symbols.

| Instruction | Description |
|---|---|
| `MOV src dst` | `dst := src` |
| `ADD s1 s2 dst` | `dst := s1 + s2` |
| `SUB s1 s2 dst` | `dst := s1 - s2` |
| `CMP s1 s2` | Sets `M8020` (s1=s2), `M8021` (s1<s2), `M8022` (s1>s2) |

### Misc
| Instruction | Description |
|---|---|
| `END` | End-of-scan marker (optional) |

## Memory Map

| Prefix | Type | Storage |
|---|---|---|
| `X` | Digital input | bit (memory hash) |
| `Y` | Digital output | bit (memory hash) |
| `M` | Internal relay | bit (memory hash) |
| `T` | Timer output bit | bit (memory hash) + accumulator plist |
| `C` / `CD` | Counter output bit | bit (memory hash) + counter plist |
| `D` | Data register | integer (data-regs hash) |
| `M8020–M8022` | CMP flag relays | bit (memory hash) |

Addresses are plain Lisp symbols (`'x0`, `'y1`, `'d0`, etc.).

## Files

| File | Description |
|---|---|
| `melsec-sim.asd` | ASDF system definition |
| `melsec-sim.lisp` | Core simulator: PLC class, instruction evaluator, scan loop, helpers |
| `test-sim.lisp` | 37 verification checks covering all instruction groups |
| `single-step.lisp` | Manual single-scan demo |
| `continuous.lisp` | Continuous background-thread scan demo |

## Dependencies

- [bordeaux-threads](https://github.com/sionescu/bordeaux-threads) — for the PLC lock and background scan thread
- [Quicklisp](https://www.quicklisp.org/) — for loading dependencies

## Installation

**Via Quicklisp** (recommended):

```bash
# Symlink or clone into Quicklisp's local-projects directory
ln -s /path/to/melsec-sim ~/quicklisp/local-projects/melsec-sim
```

```lisp
(ql:quickload "melsec-sim")
```

**Via ASDF directly:**

```lisp
(asdf:load-asd "/path/to/melsec-sim/melsec-sim.asd")
(asdf:load-system "melsec-sim")
```

**Plain `load`** (no ASDF required):

```lisp
(ql:quickload :bordeaux-threads)
(load "/path/to/melsec-sim/melsec-sim.lisp")
```

## Usage

```lisp
(in-package :melsec-sim)

;; Create a PLC with the built-in example program
(defvar *plc* (make-plc *example-program* :scan-time-ms 100))

;; Single-step mode
(set-input *plc* 'x0 t)   ; press Start
(plc-step *plc*)
(get-output *plc* 'y0)    ; => T  (motor on)

;; Continuous mode (background thread)
(plc-run *plc*)
;; ... interact with inputs/outputs from the REPL ...
(plc-stop *plc*)
```

`set-input` and `get-output` are thread-safe; they hold the PLC lock so they
never race the background scan thread.

## Example Program

The built-in `*example-program*` demonstrates three ladder networks:

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
`TIM` accumulates `scan-time-ms` each scan while its enable is ON; fires when
the accumulated total reaches the preset (in ms).

**Network 3 — Count-up counter (preset 3)**
```
X2 (Pulse) --|  |--------------------------( C0 K3 )
```

## Running the Tests

**Via ASDF:**

```lisp
(asdf:load-system "melsec-sim/tests")
```

**From the shell:**

```bash
sbcl --noinform --load test-sim.lisp --eval '(quit)'
```

All 37 checks should report `[PASS]`.

## Changelog

### v0.2.2

- **Nil preset crash** — `TIM`/`TOF`/`CNT`/`CTD` instructions with a missing
  preset argument (`(third instr)` returning `nil`) previously called `>=` with
  `nil`, signalling a type error that killed the background scan thread silently.
  The evaluator now validates the preset and logs a warning instead of crashing.
- **`get-word`/`set-word` data race** — both functions are part of the public API
  but accessed `data-regs` without holding the lock, allowing concurrent
  corruption with the scan thread's `MOV`/`ADD`/`SUB` instructions. Both now use
  `bt:with-recursive-lock-held`.
- **`print-state` torn reads** — `print-state` read individual bits without the
  lock, producing impossible mid-scan snapshots (e.g., coil ON, timer not yet
  updated). It now holds the lock for the entire printout.
- **`plc-run` duplicate thread race** — concurrent calls to `plc-run` could both
  observe `running = nil` and each spawn a scan thread. The running flag is now
  checked and set atomically under the lock; `plc-stop` similarly clears it under
  the lock and joins after releasing to avoid deadlock.
- Switched from `bt:make-lock` to `bt:make-recursive-lock` (and
  `bt:with-recursive-lock-held` throughout) so that `get-word`/`set-word` can be
  called from within `eval-instr` (already inside the scan lock) without
  deadlocking.

### v0.2.1

- Added `melsec-sim.asd` ASDF system definition (`melsec-sim` and `melsec-sim/tests`).

### v0.2.0

- **Thread safety** — `make-plc` creates a lock; the scan cycle (`run-scan`) and
  the public I/O helpers (`set-input`, `get-output`) hold it, preventing data
  races when using `plc-run`.
- **New instructions** — `ANB`, `ORB`, `MPS`, `MRD`, `MPP`, `TOF`, `CTD`,
  `MOV`, `ADD`, `SUB`, `CMP`.
- **D register support** — new `data-regs` hash table; `get-word` / `set-word`
  exported for REPL access.
- **CTD RST** — `RST` on a count-down counter restores count to preset (not 0),
  matching hardware behaviour.
- **`continuous.lisp`** — made standalone (no longer requires `single-step.lisp`
  to be loaded first).
- **`single-step.lisp`** — fixed split-line `(set-input ...)` form; added
  `ql:quickload` and `merge-pathnames` loader.

### v0.1.1

- Fixed `///` comment lines (parsed as the `///` variable) to `;;;`.
- Added `declaim ftype` forward declarations for `handle-timer` /
  `handle-counter` to suppress SBCL style warnings.
- Fixed `RST` not calling `set-bit` for counters and timers, leaving the
  memory bit stale until the next scan.

## License

MIT
