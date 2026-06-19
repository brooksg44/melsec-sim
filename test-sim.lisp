;;;; test-sim.lisp  — Verification tests for melsec-sim

(ql:quickload :bordeaux-threads :silent t)
(load (merge-pathnames "melsec-sim.lisp" *load-pathname*))

(in-package :melsec-sim)

(defun check (label got expected)
  (if (eql got expected)
      (format t "  [PASS] ~a~%" label)
      (format t "  [FAIL] ~a  expected=~a  got=~a~%" label expected got)))

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

(format t "~%Done.~%")
