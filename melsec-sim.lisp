;;;; melsec-sim.lisp
;;; A Mitsubishi PLC (MELSEC) Instruction List Simulator.

(defpackage :melsec-sim
  (:use :cl)
  (:export #:make-plc
           #:plc-run
           #:plc-stop
           #:plc-step
           #:set-input
           #:get-output
           #:get-word
           #:set-word
           #:print-state
           #:*example-program*
           ;; Accessor helpers used by melsec-sim/clim and other extensions
           #:plc-program
           #:plc-get-bit
           #:plc-set-bit
           #:plc-timer-acc
           #:plc-counter-cv
           #:plc-scan-count
           #:plc-snapshot-bits
           #:plc-snapshot-words))

(in-package :melsec-sim)

;;;
;;; 1. PLC State Definition
;;;

(defclass plc ()
  ((memory    :accessor memory    :initform (make-hash-table :test 'eq)) ; X,Y,M,T,C bits
   (data-regs :accessor data-regs :initform (make-hash-table :test 'eq)) ; D word registers
   (timers    :accessor timers    :initform (make-hash-table :test 'eq)) ; T accumulators
   (counters  :accessor counters  :initform (make-hash-table :test 'eq)) ; C accumulators
   (stack     :accessor stack     :initform nil) ; logic evaluation stack
   (mstack    :accessor mstack    :initform nil) ; master control stack (MPS/MRD/MPP)
   (program   :accessor program   :initarg :program :initform nil)
   (scan-time-ms :accessor scan-time-ms :initarg :scan-time-ms :initform 100)
   (running    :accessor running    :initform nil)
   (scan-count :accessor scan-count :initform 0)
   (lock       :accessor lock       :initform nil)
   (thread     :accessor thread     :initform nil)))

(defun make-plc (program &key (scan-time-ms 100))
  (let ((plc (make-instance 'plc :program program :scan-time-ms scan-time-ms)))
    (setf (lock plc) (bt:make-recursive-lock "plc-lock"))
    plc))

;;;
;;; 2. Memory Accessors
;;; get-bit / set-bit are internal (called under the lock from eval-instr).
;;; get-word / set-word are public and acquire the lock themselves.
;;;

(defun get-bit (plc addr)
  (gethash addr (memory plc) nil))

(defun set-bit (plc addr val)
  (setf (gethash addr (memory plc)) val))

(defun get-word (plc addr)
  "Reads a word (integer) from a D data register, thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (gethash addr (data-regs plc) 0)))

(defun set-word (plc addr val)
  "Writes a word (integer) to a D data register, thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (setf (gethash addr (data-regs plc)) val)))

;;;
;;; 3. Instruction Set Implementation
;;;

(declaim (ftype function handle-timer handle-timer-off handle-counter handle-countdown))

(defun resolve-operand (plc x)
  "Returns x if numeric, otherwise reads x as a D register (called under the scan lock)."
  (if (numberp x) x (gethash x (data-regs plc) 0)))

(defun eval-instr (plc instr)
  "Evaluates a single instruction against the PLC state."
  (let ((op  (first  instr))
        (arg (second instr)))
    (case op
      ;; --- Contact Instructions ---
      (ld  (push (get-bit plc arg) (stack plc)))
      (ldi (push (not (get-bit plc arg)) (stack plc)))

      (and (let ((top (pop (stack plc))))
             (push (and top (get-bit plc arg)) (stack plc))))
      (ani (let ((top (pop (stack plc))))
             (push (and top (not (get-bit plc arg))) (stack plc))))

      (or  (let ((top (pop (stack plc))))
             (push (or top (get-bit plc arg)) (stack plc))))
      (ori (let ((top (pop (stack plc))))
             (push (or top (not (get-bit plc arg))) (stack plc))))

      ;; ANB/ORB: combine two fully-formed branch results on the stack
      (anb (let ((a (pop (stack plc))) (b (pop (stack plc))))
             (push (and a b) (stack plc))))
      (orb (let ((a (pop (stack plc))) (b (pop (stack plc))))
             (push (or  a b) (stack plc))))

      ;; MPS/MRD/MPP: master control stack for multi-output rungs
      ;; MPS saves the current accumulator top without consuming it
      (mps (push (first (stack plc)) (mstack plc)))
      ;; MRD re-loads the saved value for the next output branch
      (mrd (push (first (mstack plc)) (stack plc)))
      ;; MPP loads the saved value and clears it from the master stack
      (mpp (push (pop  (mstack plc)) (stack plc)))

      ;; --- Output Instructions ---
      (out (set-bit plc arg (pop (stack plc))))
      (set (when (pop (stack plc)) (set-bit plc arg t)))
      (rst (let ((val (pop (stack plc))))
             (when val
               (cond
                 ((gethash arg (counters plc))
                  (let* ((cnt (gethash arg (counters plc)))
                         (reset-val (if (eq (getf cnt :type) :ctd)
                                        (getf cnt :preset) 0)))
                    (setf (getf cnt :count) reset-val
                          (getf cnt :done)  nil))
                  (set-bit plc arg nil))
                 ((gethash arg (timers plc))
                  (let ((tmr (gethash arg (timers plc))))
                    (setf (getf tmr :acc)  0
                          (getf tmr :done) nil))
                  (set-bit plc arg nil))
                 (t (set-bit plc arg nil))))))

      ;; --- Timers ---
      ;; TON (on-delay): preset in ms; accumulates scan-time-ms each enabled scan.
      ;; Example: (tim t0 1000) fires after Y0 has been ON for 1000 ms total.
      (tim (let ((enable (pop (stack plc))) (preset (third instr)))
             (if preset
                 (handle-timer plc arg enable preset)
                 (format t "~&TIM ~a: missing preset — instruction skipped~%" arg))))
      ;; TOF (off-delay): output turns ON immediately when enabled and stays ON
      ;; for preset ms after the enable signal drops.
      (tof (let ((enable (pop (stack plc))) (preset (third instr)))
             (if preset
                 (handle-timer-off plc arg enable preset)
                 (format t "~&TOF ~a: missing preset — instruction skipped~%" arg))))

      ;; --- Counters ---
      ;; CTU (count-up): fires on rising edge when cumulative count reaches preset.
      (cnt (let ((enable (pop (stack plc))) (preset (third instr)))
             (if preset
                 (handle-counter plc arg enable preset)
                 (format t "~&CNT ~a: missing preset — instruction skipped~%" arg))))
      ;; CTD (count-down): fires when count decrements from preset to 0.
      (ctd (let ((enable (pop (stack plc))) (preset (third instr)))
             (if preset
                 (handle-countdown plc arg enable preset)
                 (format t "~&CTD ~a: missing preset — instruction skipped~%" arg))))

      ;; --- Data Registers / Arithmetic ---
      ;; All application instructions below are conditional: they execute only
      ;; when the top-of-stack (popped) is non-nil, mirroring MELSEC IL behaviour.

      ;; (mov src dst) — dst := src; src may be an integer literal or a D register symbol
      (mov (let ((enable (pop (stack plc)))
                 (src    (second instr))
                 (dst    (third  instr)))
             (when enable
               (setf (gethash dst (data-regs plc)) (resolve-operand plc src)))))

      ;; (add s1 s2 dst) — dst := s1 + s2
      (add (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr))
                 (dst    (fourth instr)))
             (when enable
               (setf (gethash dst (data-regs plc))
                     (+ (resolve-operand plc s1) (resolve-operand plc s2))))))

      ;; (sub s1 s2 dst) — dst := s1 - s2
      (sub (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr))
                 (dst    (fourth instr)))
             (when enable
               (setf (gethash dst (data-regs plc))
                     (- (resolve-operand plc s1) (resolve-operand plc s2))))))

      ;; (cmp s1 s2) — sets M8020 (s1=s2), M8021 (s1<s2), M8022 (s1>s2)
      (cmp (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr)))
             (when enable
               (let ((v1 (resolve-operand plc s1))
                     (v2 (resolve-operand plc s2)))
                 (set-bit plc 'm8020 (=  v1 v2))
                 (set-bit plc 'm8021 (<  v1 v2))
                 (set-bit plc 'm8022 (>  v1 v2))))))

      ;; --- Misc ---
      (end nil)
      (t (format t "Unknown instruction: ~a~%" op)))))

(defun handle-timer (plc addr enable preset)
  (let ((tmr (gethash addr (timers plc))))
    (unless tmr
      (setf tmr (list :acc 0 :preset preset :done nil)
            (gethash addr (timers plc)) tmr))
    (if enable
        (progn
          (incf (getf tmr :acc) (scan-time-ms plc))
          (when (>= (getf tmr :acc) preset)
            (setf (getf tmr :acc) preset
                  (getf tmr :done) t)))
        (setf (getf tmr :acc) 0
              (getf tmr :done) nil))
    (set-bit plc addr (getf tmr :done))))

(defun handle-timer-off (plc addr enable preset)
  "TOF: output is ON immediately when enabled; stays ON for preset ms after enable drops."
  (let ((tmr (gethash addr (timers plc))))
    (unless tmr
      (setf tmr (list :acc 0 :preset preset :done nil)
            (gethash addr (timers plc)) tmr))
    (if enable
        (setf (getf tmr :acc) 0
              (getf tmr :done) t)
        (progn
          (incf (getf tmr :acc) (scan-time-ms plc))
          (when (>= (getf tmr :acc) preset)
            (setf (getf tmr :done) nil))))
    (set-bit plc addr (getf tmr :done))))

(defun handle-counter (plc addr enable preset)
  (let ((cnt (gethash addr (counters plc))))
    (unless cnt
      (setf cnt (list :type :ctu :count 0 :preset preset :done nil :prev-enable nil)
            (gethash addr (counters plc)) cnt))
    (when (and enable (not (getf cnt :prev-enable)))
      (incf (getf cnt :count)))
    (setf (getf cnt :prev-enable) enable
          (getf cnt :done) (>= (getf cnt :count) preset))
    (set-bit plc addr (getf cnt :done))))

(defun handle-countdown (plc addr enable preset)
  "CTD: initialises count at preset; decrements on each rising edge; done when count reaches 0."
  (let ((cnt (gethash addr (counters plc))))
    (unless cnt
      (setf cnt (list :type :ctd :count preset :preset preset :done nil :prev-enable nil)
            (gethash addr (counters plc)) cnt))
    (when (and enable (not (getf cnt :prev-enable)) (> (getf cnt :count) 0))
      (decf (getf cnt :count)))
    (setf (getf cnt :prev-enable) enable
          (getf cnt :done) (zerop (getf cnt :count)))
    (set-bit plc addr (getf cnt :done))))

;;;
;;; 4. Scan Cycle Execution
;;;

(defun run-scan (plc)
  "Executes one full PLC scan cycle under the PLC lock."
  (bt:with-recursive-lock-held ((lock plc))
    (setf (stack plc) nil)
    (dolist (instr (program plc))
      (eval-instr plc instr))
    (incf (scan-count plc))))

;;;
;;; 5. Simulator Control (Interactive / Background Thread)
;;;

(defun plc-run (plc)
  "Starts the PLC scanning loop in a background thread."
  (bt:with-recursive-lock-held ((lock plc))
    (unless (running plc)
      (setf (running plc) t)
      (setf (thread plc)
            (bt:make-thread
             (lambda ()
               (loop while (running plc) do
                 (run-scan plc)
                 (sleep (/ (scan-time-ms plc) 1000.0))))
             :name "PLC-Scan-Loop")))))

(defun plc-stop (plc)
  "Stops the PLC background thread."
  (let ((thr nil))
    (bt:with-recursive-lock-held ((lock plc))
      (when (running plc)
        (setf (running plc) nil
              thr            (thread plc)
              (thread plc)   nil)))
    (when thr (bt:join-thread thr))))

(defun plc-step (plc)
  "Executes a single scan cycle manually (useful for debugging)."
  (run-scan plc))

;;;
;;; 6. User Interaction Helpers
;;;

(defun set-input (plc addr value)
  "Sets a physical input (X), thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (set-bit plc addr value)))

(defun get-output (plc addr)
  "Reads a physical output (Y), thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (get-bit plc addr)))

(defun print-state (plc &rest addrs)
  "Prints the current state of specified memory addresses, thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (format t "---- PLC State ----~%")
    (dolist (addr addrs)
      (format t "~a: ~a~%" addr (get-bit plc addr)))
    (format t "-------------------~%")))

;;;
;;; 7. Public accessors for extension packages (melsec-sim/clim etc.)
;;;

(defun plc-program (plc)
  "Returns the PLC's instruction list."
  (program plc))

(defun plc-get-bit (plc addr)
  "Reads any bit from PLC memory, thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (get-bit plc addr)))

(defun plc-set-bit (plc addr val)
  "Writes any bit to PLC memory, thread-safe."
  (bt:with-recursive-lock-held ((lock plc))
    (set-bit plc addr val)))

(defun plc-timer-acc (plc addr)
  "Returns the timer accumulator (ms) for ADDR, or NIL if not yet initialised."
  (bt:with-recursive-lock-held ((lock plc))
    (let ((tmr (gethash addr (timers plc))))
      (and tmr (getf tmr :acc)))))

(defun plc-counter-cv (plc addr)
  "Returns the counter current value for ADDR, or NIL if not yet initialised."
  (bt:with-recursive-lock-held ((lock plc))
    (let ((cnt (gethash addr (counters plc))))
      (and cnt (getf cnt :count)))))

(defun plc-scan-count (plc)
  "Returns the total number of completed scan cycles."
  (bt:with-recursive-lock-held ((lock plc))
    (scan-count plc)))

(defun plc-snapshot-bits (plc)
  "Returns a fresh alist of (sym . val) for every bit in memory, under lock."
  (bt:with-recursive-lock-held ((lock plc))
    (let ((result '()))
      (maphash (lambda (k v) (push (cons k v) result)) (memory plc))
      result)))

(defun plc-snapshot-words (plc)
  "Returns a fresh alist of (sym . val) for every D register, under lock."
  (bt:with-recursive-lock-held ((lock plc))
    (let ((result '()))
      (maphash (lambda (k v) (push (cons k v) result)) (data-regs plc))
      result)))

;;;
;;; 8. Example Ladder Logic Program
;;;

;; Network 1: Motor Start-Stop Seal-in
;;   X0 (Start)    /X1 (Stop NC)    Y0 (Motor)
;; ---| |---+---[/X1]---( Y0 )
;;          |
;; ---[Y0]--+
;;
;; Network 2: On-delay timer (1000 ms)
;; ---[Y0]--( T0 K1000 )
;;
;; Network 3: Count-up counter (preset 3)
;; ---[X2]--( C0 K3 )
;;
(defparameter *example-program*
  '(;; Network 1
    (ld x0)
    (or y0)
    (ani x1)
    (out y0)
    ;; Network 2
    (ld y0)
    (tim t0 1000)   ; fires after Y0 has been ON for 1000 ms
    ;; Network 3
    (ld x2)
    (cnt c0 3)))    ; counts up to 3
