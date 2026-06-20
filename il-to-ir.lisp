;;;; il-to-ir.lisp --- Stack-to-tree IL → IR parser for melsec-sim.
;;;;
;;;; Converts a flat MELSEC Instruction List (IL) program into a list of
;;;; IR rung trees.  The IR format mirrors cl-plc-sim/plc-sim/src/ir.lisp so
;;;; the layout engine (layout.lisp) and McCLIM UI (clim-ui.lisp) from that
;;;; project can be adapted with minimal changes.
;;;;
;;;; The core challenge: MELSEC IL is a stack-based language.  To display
;;;; it as a ladder diagram we need an EXPRESSION TREE where series contacts
;;;; are (:and ...) nodes and parallel branches are (:or ...) nodes.
;;;; This file simulates the IL stack machine symbolically, building tree
;;;; nodes instead of evaluating boolean values.
;;;;
;;;; -----------------------------------------------------------------------
;;;; IR node format (plain lists — print readably, inspect at the REPL):
;;;;
;;;; Boolean expressions (the contact network on the left rail):
;;;;   (:contact :no  operand)   normally-open  contact  --| |--
;;;;   (:contact :nc  operand)   normally-closed contact --|/|--
;;;;   (:and <expr> ...)         series  (horizontal chain of contacts)
;;;;   (:or  <expr> ...)         parallel (vertical branches)
;;;;
;;;; Rungs (one row of ladder):
;;;;   (:coil <kind> <operand> <expr> [<arg1> [<arg2>]])
;;;;     :normal   OUT  plain output coil           no extra args
;;;;     :set      SET  latching coil               no extra args
;;;;     :reset    RST  reset coil/timer/counter    no extra args
;;;;     :ton      TIM  on-delay timer              arg1 = preset-ms
;;;;     :tof      TOF  off-delay timer             arg1 = preset-ms
;;;;     :ctu      CNT  count-up counter            arg1 = preset-count
;;;;     :ctd      CTD  count-down counter          arg1 = preset-count
;;;;     :mov      MOV  conditional register move   arg1 = source
;;;;     :add      ADD  conditional add             arg1 = s1, arg2 = s2
;;;;     :sub      SUB  conditional subtract        arg1 = s1, arg2 = s2
;;;;     :cmp      CMP  compare → M8020/M8021/M8022 arg1 = s1, arg2 = s2
;;;; -----------------------------------------------------------------------

(defpackage :melsec-sim.ir
  (:use :cl)
  (:export
   ;; IR smart constructors
   #:contact #:series #:parallel #:negate
   ;; IR node accessors
   #:node-op #:node-args #:contactp
   ;; Main parser
   #:il->ir
   ;; Debugging
   #:format-expr #:print-ir))

(in-package :melsec-sim.ir)

;;; ---------------------------------------------------------------------------
;;; 1.  IR smart constructors
;;;     Mirror cl-plc-sim/src/ir.lisp so both layout engines accept the same
;;;     node format.  n-ary :AND and :OR flatten associatively so a chain of
;;;     three ANDs becomes (:and a b c) rather than (:and a (:and b c)).
;;; ---------------------------------------------------------------------------

(declaim (inline node-op node-args contactp))

(defun node-op   (node) (and (consp node) (car  node)))
(defun node-args (node) (and (consp node) (cdr  node)))
(defun contactp  (node) (and (consp node) (eq (car node) :contact)))

(defun %parts (node op)
  "If NODE is an OP node return its argument list; else a singleton."
  (if (and (consp node) (eq (car node) op))
      (cdr node)
      (list node)))

(defun contact (operand &optional (mode :no))
  "Build (:contact MODE OPERAND).  MODE is :NO (default) or :NC."
  (list :contact mode operand))

(defun series (a b)
  "Combine A and B in series (:AND).  NIL is the identity element."
  (cond ((null a) b)
        ((null b) a)
        (t (cons :and (append (%parts a :and) (%parts b :and))))))

(defun parallel (a b)
  "Combine A and B in parallel (:OR).  NIL is the identity element."
  (cond ((null a) b)
        ((null b) a)
        (t (cons :or (append (%parts a :or) (%parts b :or))))))

(defun negate (expr)
  "Negate EXPR.  Flips a single contact's mode in-place (no :NOT wrapper).
For compound expressions wraps in :NOT; double negation cancels."
  (cond ((null expr) nil)
        ((contactp expr)
         (contact (third expr)
                  (if (eq (second expr) :no) :nc :no)))
        ((eq (node-op expr) :not) (second expr)) ; cancel double negation
        (t (list :not expr))))

;;; ---------------------------------------------------------------------------
;;; 2.  Stack-to-tree IL → IR parser
;;; ---------------------------------------------------------------------------

(defun %kw (sym)
  "Intern SYM's name into the keyword package for package-independent dispatch."
  (intern (symbol-name sym) :keyword))

(defun il->ir (program)
  "Convert a flat MELSEC IL PROGRAM (list of instruction forms) into a list
of IR rung nodes suitable for the layout engine and McCLIM UI.

Algorithm — simulate the MELSEC stack machine symbolically:
  LD/LDI          load a contact node onto the expression stack
  AND/ANI/OR/ORI  series/parallel-extend the top expression
  ANB/ORB         combine the top two stack frames in series/parallel
  MPS/MRD/MPP     master-control-relay save/restore for multi-output rungs
  OUT/SET/RST     pop expression, emit a coil rung
  TIM/TOF/CNT/CTD pop expression, emit a timer/counter rung (+ preset)
  MOV/ADD/SUB/CMP pop expression, emit a data-register application rung

Package note: instruction opcodes are normalized to keywords (:LD, :AND …)
before dispatch so that programs read in any CL package work correctly."
  (let ((estack '())   ; expression stack  — holds IR boolean trees
        (mstack '())   ; master-control stack — saved trees for MPS/MRD/MPP
        (rungs  '()))  ; completed rungs (built in reverse, nreverse at end)

    (labels
        ((push-e (x)
           (push x estack))
         (pop-e ()
           (or (pop estack)
               (error "il->ir: expression stack underflow near ~S"
                      (first rungs))))
         (emit (rung)
           (push rung rungs)))

      (dolist (instr program)
        (let* ((op  (first  instr))
               (arg (second instr))
               (kop (%kw op)))        ; keyword-normalised opcode

          (case kop

            ;; ---- Load contacts ------------------------------------------
            (:ld   (push-e (contact arg :no)))
            (:ldi  (push-e (contact arg :nc)))

            ;; ---- Series extensions (AND) --------------------------------
            (:and  (push-e (series  (pop-e) (contact arg :no))))
            (:ani  (push-e (series  (pop-e) (contact arg :nc))))

            ;; ---- Parallel extensions (OR) --------------------------------
            (:or   (push-e (parallel (pop-e) (contact arg :no))))
            (:ori  (push-e (parallel (pop-e) (contact arg :nc))))

            ;; ---- Block AND / OR (ANB / ORB) -----------------------------
            ;; Stack convention: B was pushed last (top), A was pushed first.
            ;; Preserve IL left-to-right order: series/parallel(A, B).
            (:anb  (let ((b (pop-e)) (a (pop-e)))
                     (push-e (series   a b))))
            (:orb  (let ((b (pop-e)) (a (pop-e)))
                     (push-e (parallel a b))))

            ;; ---- Master-control stack (MPS / MRD / MPP) -----------------
            ;; MPS: copy (not consume) the top expression so the first
            ;;      output branch can still extend it with AND/ANI/etc.
            (:mps  (push (first estack) mstack))
            ;; MRD: push a copy of the saved expression for the next branch.
            (:mrd  (push-e (first mstack)))
            ;; MPP: last branch — pop the saved expression and push it.
            (:mpp  (push-e (pop mstack)))

            ;; ---- Standard output coils ----------------------------------
            (:out  (emit (list :coil :normal arg (pop-e))))
            (:set  (emit (list :coil :set    arg (pop-e))))
            (:rst  (emit (list :coil :reset  arg (pop-e))))

            ;; ---- Timers -------------------------------------------------
            (:tim  (emit (list :coil :ton arg (pop-e) (third instr))))
            (:tof  (emit (list :coil :tof arg (pop-e) (third instr))))

            ;; ---- Counters -----------------------------------------------
            (:cnt  (emit (list :coil :ctu arg (pop-e) (third instr))))
            (:ctd  (emit (list :coil :ctd arg (pop-e) (third instr))))

            ;; ---- Data register operations (conditional) -----------------
            ;; Format: (:coil kind dst-or-nil expr [src1 [src2]])
            ;; MOV: (mov src dst) → dst := src when expr is true
            (:mov  (emit (list :coil :mov (third  instr) (pop-e)
                               (second instr))))
            ;; ADD: (add s1 s2 dst) → dst := s1 + s2 when expr is true
            (:add  (emit (list :coil :add (fourth instr) (pop-e)
                               (second instr) (third instr))))
            ;; SUB: (sub s1 s2 dst) → dst := s1 - s2 when expr is true
            (:sub  (emit (list :coil :sub (fourth instr) (pop-e)
                               (second instr) (third instr))))
            ;; CMP: (cmp s1 s2) → sets M8020/M8021/M8022; no output symbol
            (:cmp  (emit (list :coil :cmp nil (pop-e)
                               (second instr) (third instr))))

            ;; ---- End of program marker ----------------------------------
            (:end  nil)

            ;; ---- Unknown ------------------------------------------------
            (otherwise
             (warn "il->ir: skipping unrecognised instruction ~S" instr)))))

      ;; Post-parse sanity checks
      (unless (null estack)
        (warn "il->ir: ~D expression(s) left on stack at end: ~S"
              (length estack) estack))
      (unless (null mstack)
        (warn "il->ir: ~D expression(s) left on master-control stack at end: ~S"
              (length mstack) mstack)))

    (nreverse rungs)))

;;; ---------------------------------------------------------------------------
;;; 3.  Pretty-printer (REPL / debugging aid)
;;; ---------------------------------------------------------------------------

(defun format-expr (expr)
  "Return a compact human-readable string for IR boolean expression EXPR."
  (cond
    ((null expr) "T")                   ; unconditional (bare rail)
    ((contactp expr)
     (let ((mode (second expr))
           (op   (symbol-name (third expr))))
       (if (eq mode :nc) (format nil "~A/" op) op)))
    (t
     (ecase (node-op expr)
       (:and (format nil "(~{~A~^ AND ~})"
                     (mapcar #'format-expr (node-args expr))))
       (:or  (format nil "(~{~A~^ OR ~})"
                     (mapcar #'format-expr (node-args expr))))
       (:not (format nil "NOT(~A)" (format-expr (second expr))))))))

(defun print-ir (ir &optional (stream *standard-output*))
  "Print a list of IR rungs in a compact ladder-like form."
  (dolist (rung ir)
    (destructuring-bind (tag kind operand expr &rest extra) rung
      (declare (ignore tag))
      (format stream "~&  [~8A ~10A] ← ~A~A~%"
              kind
              (if operand (symbol-name operand) "-")
              (format-expr expr)
              (if extra
                  (format nil "  {~{~A~^ ~}}" extra)
                  "")))))
