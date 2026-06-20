;;;; test-sim.lisp  — Verification tests for melsec-sim

(ql:quickload :bordeaux-threads :silent t)
(load (merge-pathnames "melsec-sim.lisp" *load-pathname*))

(in-package :melsec-sim)

(defun check (label got expected)
  (if (eql got expected)
      (format t "  [PASS] ~a~%" label)
      (format t "  [FAIL] ~a  expected=~a  got=~a~%" label expected got)))

(defun check-equal (label got expected)
  "Like CHECK but uses EQUAL for deep list comparison (needed for IR nodes)."
  (if (equal got expected)
      (format t "  [PASS] ~a~%" label)
      (format t "  [FAIL] ~a  expected=~s  got=~s~%" label expected got)))

;;; -----------------------------------------------------------------------
;;; Network 1: Motor Start-Stop Seal-in
;;;   X0=Start, X1=Stop(NC), Y0=Motor coil
;;; -----------------------------------------------------------------------
(format t "~%=== Network 1: Start-Stop Seal-in ===~%")
(let ((plc (make-plc *example-program*)))

  ;; Initial state — motor should be OFF
  (plc-step plc)
  (check "Initial: Y0 off" (get-output plc 'y0) nil)

  ;; Press Start (X0=T), Stop not pressed (X1=NIL/NC is satisfied)
  (set-input plc 'x0 t)
  (plc-step plc)
  (check "X0 pressed: Y0 on" (get-output plc 'y0) t)

  ;; Release Start — seal-in should hold Y0
  (set-input plc 'x0 nil)
  (plc-step plc)
  (check "X0 released: Y0 still on (seal-in)" (get-output plc 'y0) t)

  ;; Press Stop (X1=T breaks the NC contact)
  (set-input plc 'x1 t)
  (plc-step plc)
  (check "X1 pressed: Y0 off" (get-output plc 'y0) nil)

  ;; Release Stop — motor should stay off (no start command)
  (set-input plc 'x1 nil)
  (plc-step plc)
  (check "X1 released: Y0 still off" (get-output plc 'y0) nil))

;;; -----------------------------------------------------------------------
;;; Network 2: Timer (TON 1000 ms)
;;; -----------------------------------------------------------------------
(format t "~%=== Network 2: Timer (1000 ms @ 100 ms scan) ===~%")
(let ((plc (make-plc *example-program* :scan-time-ms 100)))

  ;; Start motor so Y0 energises the timer coil
  (set-input plc 'x0 t)
  (plc-step plc)                   ; Y0 on, timer acc=100ms

  ;; Run 8 more scans (total 9 × 100 ms = 900 ms) — T0 should not be done yet
  (dotimes (_ 8) (plc-step plc))
  (check "After 900 ms: T0 not done" (get-bit plc 't0) nil)

  ;; One more scan → 1000 ms reached, T0 should fire
  (plc-step plc)
  (check "After 1000 ms: T0 done" (get-bit plc 't0) t)

  ;; Stop motor — timer should reset
  (set-input plc 'x0 nil)
  (set-input plc 'x1 t)
  (plc-step plc)
  (check "Motor stopped: T0 reset" (get-bit plc 't0) nil))

;;; -----------------------------------------------------------------------
;;; Network 3: Counter (CTU preset=3)
;;; -----------------------------------------------------------------------
(format t "~%=== Network 3: Counter (preset 3) ===~%")
(let ((plc (make-plc *example-program*)))

  ;; Pulse X2 twice — counter should not be done yet
  (dotimes (_ 2)
    (set-input plc 'x2 t)  (plc-step plc)   ; rising edge
    (set-input plc 'x2 nil) (plc-step plc))  ; falling edge
  (check "After 2 pulses: C0 not done" (get-bit plc 'c0) nil)

  ;; Third pulse — counter reaches preset
  (set-input plc 'x2 t)  (plc-step plc)
  (check "After 3 pulses: C0 done" (get-bit plc 'c0) t)

  ;; Reset C0 via RST instruction — add a one-shot RST network
  ;; (manual reset via set-bit since RST needs a program instruction)
  (set-bit plc 'c0 nil)
  (let ((cnt (gethash 'c0 (counters plc))))
    (when cnt
      (setf (getf cnt :count) 0
            (getf cnt :done)  nil)))
  (check "After reset: C0 off" (get-bit plc 'c0) nil))

;;; -----------------------------------------------------------------------
;;; RST counter: memory bit cleared immediately in same scan as RST
;;; Program: X2 -> CNT C1 K2, X3 -> RST C1
;;; -----------------------------------------------------------------------
(format t "~%=== RST counter: bit cleared immediately ===~%")
(let* ((prog '((ld x2) (cnt c1 2)
               (ld x3) (rst c1)))
       (plc (make-plc prog)))

  ;; Pulse X2 twice to reach preset
  (dotimes (_ 2)
    (set-input plc 'x2 t)  (plc-step plc)
    (set-input plc 'x2 nil) (plc-step plc))
  (check "RST test: C1 done after 2 pulses" (get-bit plc 'c1) t)

  ;; RST C1 while X2 is still HIGH — bit must go nil in this same scan
  (set-input plc 'x2 t)
  (set-input plc 'x3 t)
  (plc-step plc)
  (check "RST test: C1 cleared immediately" (get-bit plc 'c1) nil)

  ;; X2 stays high, RST released — prev-enable is T so no spurious edge
  (set-input plc 'x3 nil)
  (plc-step plc)
  (check "RST test: C1 stays 0 (no spurious rising edge)" (get-bit plc 'c1) nil)

  ;; Genuine low→high pulse → count=1, not done yet (preset=2)
  (set-input plc 'x2 nil) (plc-step plc)
  (set-input plc 'x2 t)   (plc-step plc)
  (check "RST test: C1 not done after 1 new pulse" (get-bit plc 'c1) nil))

;;; -----------------------------------------------------------------------
;;; ANB / ORB: block AND/OR for parallel branches
;;; (X0 AND X1) OR (X2 AND X3) -> Y1
;;; -----------------------------------------------------------------------
(format t "~%=== ANB / ORB ===~%")
(let* ((prog '((ld x0) (and x1)
               (ld x2) (and x3)
               (orb)
               (out y1)))
       (plc (make-plc prog)))

  (set-input plc 'x0 t) (set-input plc 'x1 t)
  (plc-step plc)
  (check "ORB: branch-1 true -> Y1 on" (get-output plc 'y1) t)

  (set-input plc 'x0 nil) (set-input plc 'x1 nil)
  (set-input plc 'x2 t)   (set-input plc 'x3 t)
  (plc-step plc)
  (check "ORB: branch-2 true -> Y1 on" (get-output plc 'y1) t)

  (set-input plc 'x2 nil)
  (plc-step plc)
  (check "ORB: both branches false -> Y1 off" (get-output plc 'y1) nil))

;;; -----------------------------------------------------------------------
;;; MPS / MRD / MPP: multi-output rung from a single condition
;;; X0 -> MPS; AND X1 -> OUT Y1; MRD; AND X2 -> OUT Y2; MPP -> OUT Y3
;;; -----------------------------------------------------------------------
(format t "~%=== MPS / MRD / MPP ===~%")
(let* ((prog '((ld x0)
               (mps)
               (and x1)
               (out y1)
               (mrd)
               (and x2)
               (out y2)
               (mpp)
               (out y3)))
       (plc (make-plc prog)))

  (set-input plc 'x0 t)
  (set-input plc 'x1 t)
  (set-input plc 'x2 nil)
  (plc-step plc)
  (check "MPS: X0+X1 -> Y1 on"  (get-output plc 'y1) t)
  (check "MPS: X0+X2 -> Y2 off" (get-output plc 'y2) nil)
  (check "MPP: X0 -> Y3 on"     (get-output plc 'y3) t)

  (set-input plc 'x0 nil)
  (plc-step plc)
  (check "MPS: X0=nil -> Y3 off" (get-output plc 'y3) nil))

;;; -----------------------------------------------------------------------
;;; CTD: count-down counter
;;; -----------------------------------------------------------------------
(format t "~%=== CTD: count-down counter ===~%")
(let* ((prog '((ld x0) (ctd cd0 3)))
       (plc (make-plc prog)))

  ;; Two pulses: count goes 3->2->1, not done yet
  (dotimes (_ 2)
    (set-input plc 'x0 t)  (plc-step plc)
    (set-input plc 'x0 nil) (plc-step plc))
  (check "CTD: after 2 pulses not done" (get-bit plc 'cd0) nil)

  ;; Third pulse: count reaches 0, done
  (set-input plc 'x0 t) (plc-step plc)
  (check "CTD: after 3 pulses done" (get-bit plc 'cd0) t)

  ;; RST CD0 restores count to preset (3), not to 0
  (let* ((prog2 '((ld x0) (ctd cd0 3) (ld x1) (rst cd0)))
         (plc2 (make-plc prog2)))
    (dotimes (_ 3)
      (set-input plc2 'x0 t)  (plc-step plc2)
      (set-input plc2 'x0 nil) (plc-step plc2))
    (check "CTD RST: done before reset" (get-bit plc2 'cd0) t)
    (set-input plc2 'x1 t) (plc-step plc2)
    (check "CTD RST: cleared" (get-bit plc2 'cd0) nil)
    ;; After RST count is back at preset=3; one pulse should NOT be done
    (set-input plc2 'x1 nil)
    (set-input plc2 'x0 nil) (plc-step plc2)
    (set-input plc2 'x0 t)   (plc-step plc2)
    (check "CTD RST: 1 pulse after reset not done" (get-bit plc2 'cd0) nil)))

;;; -----------------------------------------------------------------------
;;; TOF: off-delay timer
;;; -----------------------------------------------------------------------
(format t "~%=== TOF: off-delay timer (1000 ms @ 100 ms scan) ===~%")
(let* ((prog '((ld x0) (tof tf0 1000)))
       (plc (make-plc prog :scan-time-ms 100)))

  ;; Enable: output is ON immediately
  (set-input plc 'x0 t) (plc-step plc)
  (check "TOF: enabled -> output on immediately" (get-bit plc 'tf0) t)

  ;; Disable: output must remain ON for 1000 ms (10 scans)
  (set-input plc 'x0 nil)
  (dotimes (_ 9) (plc-step plc))
  (check "TOF: after 900 ms still on" (get-bit plc 'tf0) t)
  (plc-step plc)
  (check "TOF: after 1000 ms off" (get-bit plc 'tf0) nil))

;;; -----------------------------------------------------------------------
;;; Data registers: MOV / ADD / SUB / CMP
;;; -----------------------------------------------------------------------
(format t "~%=== Data registers: MOV / ADD / SUB / CMP ===~%")
(let* ((prog '((ld m0)
               (mov 42 d0)
               (ld m0)
               (add d0 8 d1)
               (ld m0)
               (sub d1 10 d2)
               (ld m0)
               (cmp d0 42)))
       (plc (make-plc prog)))

  ;; With M0=nil, nothing should execute
  (plc-step plc)
  (check "MOV: M0=nil, D0 unchanged" (get-word plc 'd0) 0)

  ;; With M0=T, instructions execute
  (set-bit plc 'm0 t)
  (plc-step plc)
  (check "MOV: D0 = 42"       (get-word plc 'd0) 42)
  (check "ADD: D1 = 50"       (get-word plc 'd1) 50)
  (check "SUB: D2 = 40"       (get-word plc 'd2) 40)
  (check "CMP: M8020 (=)"     (get-bit plc 'm8020) t)
  (check "CMP: M8021 (<) off" (get-bit plc 'm8021) nil)
  (check "CMP: M8022 (>) off" (get-bit plc 'm8022) nil))

;; -----------------------------------------------------------------------
;; Load IL→IR parser
;; -----------------------------------------------------------------------
(load (merge-pathnames "il-to-ir.lisp" *load-pathname*))

;;; -----------------------------------------------------------------------
;;; IL → IR parser: correctness tests
;;; -----------------------------------------------------------------------
(format t "~%=== IL->IR: example program structure ===~%")
(let* ((ir (melsec-sim.ir:il->ir *example-program*))
       (r0 (first ir))    ; Network 1 rung
       (r1 (second ir))   ; Network 2 rung
       (r2 (third ir)))   ; Network 3 rung

  (check "IR: 3 rungs produced"        (length ir) 3)

  ;; Network 1 — OUT coil
  (check "IR rung0 kind = :normal"     (second r0) :normal)
  (check "IR rung0 operand = y0"       (third  r0) 'y0)

  ;; The condition is (:and (:or (:contact :no x0) (:contact :no y0))
  ;;                        (:contact :nc x1))
  (let ((expr (fourth r0)))
    (check "IR rung0 expr op = :and"   (melsec-sim.ir:node-op expr) :and)
    (check "IR rung0 :and arity = 2"   (length (melsec-sim.ir:node-args expr)) 2)
    (let ((lhs (first  (melsec-sim.ir:node-args expr)))
          (rhs (second (melsec-sim.ir:node-args expr))))
      (check "IR rung0 lhs op = :or"   (melsec-sim.ir:node-op lhs) :or)
      (check-equal "IR rung0 rhs = x1/ (NC)" rhs '(:contact :nc x1))))

  ;; Network 2 — TON timer
  (check "IR rung1 kind = :ton"        (second r1) :ton)
  (check "IR rung1 operand = t0"       (third  r1) 't0)
  (check "IR rung1 preset = 1000"      (fifth  r1) 1000)
  (check-equal "IR rung1 expr = y0 contact"  (fourth r1) '(:contact :no y0))

  ;; Network 3 — CTU counter
  (check "IR rung2 kind = :ctu"        (second r2) :ctu)
  (check "IR rung2 operand = c0"       (third  r2) 'c0)
  (check "IR rung2 preset = 3"         (fifth  r2) 3)
  (check-equal "IR rung2 expr = x2 contact"  (fourth r2) '(:contact :no x2)))

(format t "~%=== IL->IR: ANB block AND ===~%")
(let* ((prog '((ld x0) (and x1) (ld x2) (and x3) (anb) (out y1)))
       (ir   (melsec-sim.ir:il->ir prog))
       (r    (first ir))
       (expr (fourth r)))
  (check "ANB: 1 rung"             (length ir) 1)
  (check "ANB: kind = :normal"     (second r)  :normal)
  ;; (X0 AND X1) AND (X2 AND X3) → flat (:and x0 x1 x2 x3)
  (check "ANB: expr op = :and"     (melsec-sim.ir:node-op expr) :and)
  (check "ANB: :and arity = 4"     (length (melsec-sim.ir:node-args expr)) 4))

(format t "~%=== IL->IR: ORB block OR ===~%")
(let* ((prog '((ld x0) (and x1) (ld x2) (and x3) (orb) (out y1)))
       (ir   (melsec-sim.ir:il->ir prog))
       (r    (first ir))
       (expr (fourth r)))
  (check "ORB: 1 rung"             (length ir) 1)
  ;; (:or (:and x0 x1) (:and x2 x3))
  (check "ORB: expr op = :or"      (melsec-sim.ir:node-op expr) :or)
  (check "ORB: :or arity = 2"      (length (melsec-sim.ir:node-args expr)) 2)
  (let ((a (first  (melsec-sim.ir:node-args expr)))
        (b (second (melsec-sim.ir:node-args expr))))
    (check "ORB: branch-a op = :and" (melsec-sim.ir:node-op a) :and)
    (check "ORB: branch-b op = :and" (melsec-sim.ir:node-op b) :and)))

(format t "~%=== IL->IR: MPS / MRD / MPP multi-output ===~%")
(let* ((prog '((ld x0) (mps) (and x1) (out y1)
               (mrd) (and x2) (out y2)
               (mpp) (out y3)))
       (ir (melsec-sim.ir:il->ir prog)))
  (check "MPS: 3 rungs"           (length ir) 3)
  ;; Rung y1: (x0 AND x1)
  (check "MPS: rung0 operand y1" (third  (first  ir)) 'y1)
  (let ((e0 (fourth (first ir))))
    (check "MPS: rung0 :and"     (melsec-sim.ir:node-op e0) :and)
    (check "MPS: rung0 arity 2" (length (melsec-sim.ir:node-args e0)) 2))
  ;; Rung y2: (x0 AND x2)
  (check "MPS: rung1 operand y2" (third  (second ir)) 'y2)
  (let ((e1 (fourth (second ir))))
    (check "MPS: rung1 :and"     (melsec-sim.ir:node-op e1) :and))
  ;; Rung y3: plain x0 contact (MPP restores the bare save)
  (check "MPS: rung2 operand y3" (third  (third  ir)) 'y3)
  (check-equal "MPS: rung2 bare x0 contact"
               (fourth (third ir)) '(:contact :no x0)))

(format t "~%=== IL->IR: data register MOV / ADD ===~%")
(let* ((prog '((ld m0) (mov 42 d0)
               (ld m0) (add d0 8 d1)))
       (ir (melsec-sim.ir:il->ir prog))
       (mov-r (first  ir))
       (add-r (second ir)))
  (check "DATA: 2 rungs"            (length ir) 2)
  ;; MOV rung: (:coil :mov d0 (:contact :no m0) 42)
  (check "MOV: kind = :mov"         (second mov-r) :mov)
  (check "MOV: operand = d0"        (third  mov-r) 'd0)
  (check "MOV: src = 42"            (fifth  mov-r) 42)
  (check-equal "MOV: cond = m0 contact"   (fourth mov-r) '(:contact :no m0))
  ;; ADD rung: (:coil :add d1 (:contact :no m0) d0 8)
  (check "ADD: kind = :add"         (second add-r) :add)
  (check "ADD: operand = d1"        (third  add-r) 'd1)
  (check "ADD: s1 = d0"             (fifth  add-r) 'd0)
  (check "ADD: s2 = 8"              (sixth  add-r) 8))

(format t "~%=== IL->IR: print-ir smoke test ===~%")
(let* ((ir (melsec-sim.ir:il->ir *example-program*))
       (out (with-output-to-string (s)
              (melsec-sim.ir:print-ir ir s))))
  (check "print-ir: non-empty output" (> (length out) 0) t)
  (check "print-ir: contains :normal" (not (null (search "NORMAL" out))) t)
  (check "print-ir: contains :ton"    (not (null (search "TON"    out))) t)
  (check "print-ir: contains :ctu"    (not (null (search "CTU"    out))) t))

(format t "~%Done.~%")
