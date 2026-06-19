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
           #:*example-program*))

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
   (running   :accessor running   :initform nil)
   (lock      :accessor lock      :initform nil)
   (thread    :accessor thread    :initform nil)))

(defun make-plc (program &key (scan-time-ms 100))
  (let ((plc (make-instance 'plc :program program :scan-time-ms scan-time-ms)))
    (setf (lock plc) (bt:make-lock "plc-lock"))
    plc))

;;;
;;; 2. Memory Accessors (internal, no locking)
;;;

(defun get-bit (plc addr)
  (gethash addr (memory plc) nil))

(defun set-bit (plc addr val)
  (setf (gethash addr (memory plc)) val))

(defun get-word (plc addr)
  "Reads a word (integer) from a D data register."
  (gethash addr (data-regs plc) 0))

(defun set-word (plc addr val)
  "Writes a word (integer) to a D data register."
  (setf (gethash addr (data-regs plc)) val))

;;;
;;; 3. Instruction Set Implementation
;;;

(declaim (ftype function handle-timer handle-timer-off handle-counter handle-countdown))

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
                  (setf (getf (gethash arg (timers plc)) :acc)  0
                        (getf (gethash arg (timers plc)) :done) nil)
                  (set-bit plc arg nil))
                 (t (set-bit plc arg nil))))))

      ;; --- Timers ---
      ;; TON (on-delay): preset in ms; accumulates scan-time-ms each enabled scan.
      ;; Example: (tim t0 1000) fires after Y0 has been ON for 1000 ms total.
      (tim (handle-timer     plc arg (pop (stack plc)) (third instr)))
      ;; TOF (off-delay): output turns ON immediately when enabled and stays ON
      ;; for preset ms after the enable signal drops.
      (tof (handle-timer-off plc arg (pop (stack plc)) (third instr)))

      ;; --- Counters ---
      ;; CTU (count-up): fires on rising edge when cumulative count reaches preset.
      (cnt (handle-counter   plc arg (pop (stack plc)) (third instr)))
      ;; CTD (count-down): fires when count decrements from preset to 0.
      (ctd (handle-countdown plc arg (pop (stack plc)) (third instr)))

      ;; --- Data Registers / Arithmetic ---
      ;; All application instructions below are conditional: they execute only
      ;; when the top-of-stack (popped) is non-nil, mirroring MELSEC IL behaviour.

      ;; (mov src dst) — dst := src; src may be an integer literal or a D register symbol
      (mov (let ((enable (pop (stack plc)))
                 (src    (second instr))
                 (dst    (third  instr)))
             (when enable
               (set-word plc dst (if (numberp src) src (get-word plc src))))))

      ;; (add s1 s2 dst) — dst := s1 + s2
      (add (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr))
                 (dst    (fourth instr)))
             (when enable
               (set-word plc dst
                         (+ (if (numberp s1) s1 (get-word plc s1))
                            (if (numberp s2) s2 (get-word plc s2)))))))

      ;; (sub s1 s2 dst) — dst := s1 - s2
      (sub (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr))
                 (dst    (fourth instr)))
             (when enable
               (set-word plc dst
                         (- (if (numberp s1) s1 (get-word plc s1))
                            (if (numberp s2) s2 (get-word plc s2)))))))

      ;; (cmp s1 s2) — sets M8020 (s1=s2), M8021 (s1<s2), M8022 (s1>s2)
      (cmp (let ((enable (pop (stack plc)))
                 (s1     (second instr))
                 (s2     (third  instr)))
             (when enable
               (let ((v1 (if (numberp s1) s1 (get-word plc s1)))
                     (v2 (if (numberp s2) s2 (get-word plc s2))))
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
  (bt:with-lock-held ((lock plc))
    (setf (stack plc) nil)
    (dolist (instr (program plc))
      (eval-instr plc instr))))

;;;
;;; 5. Simulator Control (Interactive / Background Thread)
;;;

(defun plc-run (plc)
  "Starts the PLC scanning loop in a background thread."
  (when (not (running plc))
    (setf (running plc) t)
    (setf (thread plc)
          (bt:make-thread
           (lambda ()
             (loop while (running plc) do
               (run-scan plc)
               (sleep (/ (scan-time-ms plc) 1000.0))))
           :name "PLC-Scan-Loop"))))

(defun plc-stop (plc)
  "Stops the PLC background thread."
  (when (running plc)
    (setf (running plc) nil)
    (bt:join-thread (thread plc))
    (setf (thread plc) nil)))

(defun plc-step (plc)
  "Executes a single scan cycle manually (useful for debugging)."
  (run-scan plc))

;;;
;;; 6. User Interaction Helpers
;;;

(defun set-input (plc addr value)
  "Sets a physical input (X), thread-safe."
  (bt:with-lock-held ((lock plc))
    (set-bit plc addr value)))

(defun get-output (plc addr)
  "Reads a physical output (Y), thread-safe."
  (bt:with-lock-held ((lock plc))
    (get-bit plc addr)))

(defun print-state (plc &rest addrs)
  "Prints the current state of specified memory addresses."
  (format t "---- PLC State ----~%")
  (dolist (addr addrs)
    (format t "~a: ~a~%" addr (get-bit plc addr)))
  (format t "-------------------~%"))

;;;
;;; 7. Example Ladder Logic Program
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
