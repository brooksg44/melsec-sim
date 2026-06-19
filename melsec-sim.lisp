;;;; melsec-sim.lisp
;;; A simple Mitsubishi PLC (MELSEC) Instruction List Simulator.

(defpackage :melsec-sim
  (:use :cl)
  (:export #:make-plc
           #:plc-run
           #:plc-stop
           #:plc-step
           #:set-input
           #:get-output
           #:print-state
           #:*example-program*))

(in-package :melsec-sim)

;;;
;;; 1. PLC State Definition
;;;

(defclass plc ()
  ((memory :accessor memory :initform (make-hash-table :test 'eq)) ; For X, Y, M, T, C bits
   (timers :accessor timers :initform (make-hash-table :test 'eq)) ; For T accumulators
   (counters :accessor counters :initform (make-hash-table :test 'eq)) ; For C accumulators
   (stack :accessor stack :initform nil) ; Logic evaluation stack
   (program :accessor program :initarg :program :initform nil)
   (scan-time-ms :accessor scan-time-ms :initarg :scan-time-ms :initform 100)
   (running :accessor running :initform nil)
   (thread :accessor thread :initform nil)))

(defun make-plc (program &key (scan-time-ms 100))
  (make-instance 'plc :program program :scan-time-ms scan-time-ms))

;;;
;;; 2. Memory Accessors
;;;

(defun get-bit (plc addr)
  "Reads a boolean value from PLC memory."
  (gethash addr (memory plc) nil))

(defun set-bit (plc addr val)
  "Writes a boolean value to PLC memory."
  (setf (gethash addr (memory plc)) val))

;;;
;;; 3. Instruction Set Implementation
;;;

;; Forward declarations to suppress style warnings
(declaim (ftype function handle-timer handle-counter))

(defun eval-instr (plc instr)
  "Evaluates a single instruction against the PLC state."
  (let ((op (first instr))
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

      ;; --- Output Instructions ---
      (out (set-bit plc arg (pop (stack plc))))
      (set (when (pop (stack plc)) (set-bit plc arg t)))
      (rst (let ((val (pop (stack plc))))
             (when val
               (cond
                 ((gethash arg (counters plc)) ; Reset Counter
                  (let ((cnt (gethash arg (counters plc))))
                    (setf (getf cnt :count) 0
                          (getf cnt :done) nil))
                  (set-bit plc arg nil))
                 ((gethash arg (timers plc)) ; Reset Timer
                  (setf (getf (gethash arg (timers plc)) :acc) 0
                        (getf (gethash arg (timers plc)) :done) nil)
                  (set-bit plc arg nil))
                 (t (set-bit plc arg nil)))))) ; Reset standard bit

      ;; --- Timers (TON - Timer On Delay) ---
      ;; Syntax: (tim T0 100) -> 100 * 100ms = 10 seconds
      (tim (let ((enable (pop (stack plc)))
                 (preset (third instr)))
             (handle-timer plc arg enable preset)))

      ;; --- Counters (CTU - Count Up) ---
      ;; Syntax: (cnt C0 5) -> Counts up to 5
      (cnt (let ((enable (pop (stack plc)))
                 (preset (third instr)))
             (handle-counter plc arg enable preset)))

      ;; --- Misc ---
      (end () nil) ; End of scan marker
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
        (progn
          (setf (getf tmr :acc) 0
                (getf tmr :done) nil)))
    (set-bit plc addr (getf tmr :done))))

(defun handle-counter (plc addr enable preset)
  (let ((cnt (gethash addr (counters plc))))
    (unless cnt
      (setf cnt (list :count 0 :preset preset :done nil :prev-enable nil)
            (gethash addr (counters plc)) cnt))
    ;; Rising edge detection
    (when (and enable (not (getf cnt :prev-enable)))
      (incf (getf cnt :count)))
    (setf (getf cnt :prev-enable) enable)
    
    (if (>= (getf cnt :count) preset)
        (setf (getf cnt :done) t)
        (setf (getf cnt :done) nil))
    (set-bit plc addr (getf cnt :done))))

;;;
;;; 4. Scan Cycle Execution
;;;

(defun run-scan (plc)
  "Executes one full PLC scan cycle."
  ;; 1. Clear stack
  (setf (stack plc) nil)
  ;; 2. Execute program
  (dolist (instr (program plc))
    (eval-instr plc instr)))

;;;
;;; 5. Simulator Control (Interactive / Background Thread)
;;;

;; Note: Requires a Lisp implementation with threads (e.g., SBCL, CCL).
;; If your Lisp lacks threads, you can just call (plc-step) in a loop.
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
  "Sets a physical input (X)."
  (set-bit plc addr value))

(defun get-output (plc addr)
  "Reads a physical output (Y)."
  (get-bit plc addr))

(defun print-state (plc &rest addrs)
  "Prints the current state of specified memory addresses."
  (format t "---- PLC State ----~%")
  (dolist (addr addrs)
    (format t "~a: ~a~%" addr (get-bit plc addr)))
  (format t "-------------------~%"))

;;;
;;; 7. Example Ladder Logic Program
;;;

;; Equivalent Ladder Logic:
;; 
;; Network 1: Motor Start-Stop Seal-in
;;   X0 (Start)       X1 (Stop)         Y0 (Motor)
;; ---| |------|/|-----------( )--------- 
;;              |
;;;    Y0      |
;;; ---| |------+
;;
;; Network 2: Timer Delay
;;;   Y0 (Motor)                    T0 (Timer 1000ms)
;;; ---| |--------------------------( T0 K1000 )---
;;;
;; Network 3: Counter
;;;   X2 (Pulse)                    C0 (Counter 3)
;;; ---| |--------------------------( C0 K3 )---
;;;
(defparameter *example-program*
  '(
    ;; Network 1
    (ld x0)
    (or y0)
    (ani x1)
    (out y0)
    
    ;; Network 2
    (ld y0)
    (tim t0 1000)  ;; 1000ms timer
    
    ;; Network 3
    (ld x2)
    (cnt c0 3)     ;; Count up to 3
    ))
