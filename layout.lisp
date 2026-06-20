;;;; layout.lisp --- Two-pass ladder layout engine for melsec-sim.
;;;;
;;;; Adapted from cl-plc-sim/plc-sim/src/layout.lisp.
;;;;
;;;; The layout is deliberately backend-agnostic: it produces a flat list
;;;; of abstract drawing primitives in a grid coordinate system.  Both an
;;;; SVG renderer (future) and the McCLIM UI (future clim-ui.lisp) consume
;;;; the same primitives, so layout logic never leaks into a graphics toolkit.
;;;;
;;;; -----------------------------------------------------------------------
;;;; Algorithm:
;;;;
;;;;   Pass 1  EXPR-SIZE  — bottom-up traversal; each IR node reports its
;;;;                        natural (width, height) in grid cells.
;;;;                          :contact → (2, 1)   glyph + lead-out stub
;;;;                          :and     → (Σ widths, max height)
;;;;                          :or      → (max width, Σ heights)
;;;;                          :not     → delegates to inner node
;;;;                          nil      → (1, 1)   bare wire, no contacts
;;;;
;;;;   Pass 2  LAYOUT-RUNG — top-down placement; assign each node an
;;;;                         (x, y) grid origin and emit drawing primitives
;;;;                         plus connecting horizontal/vertical wires.
;;;; -----------------------------------------------------------------------
;;;; Emitted primitives (grid units; x grows right, y grows down):
;;;;
;;;;   (:contact  x y mode operand)
;;;;       normally-open (mode=:NO) or normally-closed (mode=:NC) contact glyph
;;;;   (:coil     x y kind operand [preset])
;;;;       output coil; kind = :normal :set :reset :ton :tof :ctu :ctd
;;;;       preset is the timer ms or counter edge-count (may be absent)
;;;;   (:wire     x1 y1 x2 y2)
;;;;       horizontal (y1=y2) or vertical (x1=x2) wire segment
;;;;   (:fb       x y w h label)
;;;;       function-block box; used for data-register ops: MOV ADD SUB CMP
;;;; -----------------------------------------------------------------------

(defpackage :melsec-sim.layout
  (:use :cl)
  (:import-from :melsec-sim.ir
                #:node-op #:node-args #:contactp)
  (:export
   ;; Sizing
   #:expr-size
   ;; Placement
   #:layout-rung
   #:layout-program
   ;; Primitive predicates (useful for tests and renderers)
   #:prim-kind
   #:prims-of-kind
   ;; FB-coil predicate (used by renderers)
   #:fb-coil-p
   #:fb-coil-label))

(in-package :melsec-sim.layout)

;;; ---------------------------------------------------------------------------
;;; Primitive accessors (convenience for tests and renderer code)
;;; ---------------------------------------------------------------------------

(defun prim-kind (p)   (first p))
(defun prims-of-kind (kind prims) (remove-if-not (lambda (p) (eq (prim-kind p) kind)) prims))

;;; ---------------------------------------------------------------------------
;;; Pass 1: sizing
;;; ---------------------------------------------------------------------------

(defun expr-size (expr)
  "Return (values WIDTH HEIGHT) in grid cells for IR expression EXPR.

:CONTACT  2 × 1  — 1 cell glyph + 1 cell lead-out stub
:AND      sums child widths; takes max child height (series layout)
:OR       takes max child width; sums child heights (parallel layout)
:NOT      same size as its inner expression
NIL       1 × 1  — bare wire (rung with no contacts)"
  (cond
    ;; Empty / unconditional rung
    ((null expr)
     (values 1 1))

    ((not (consp expr))
     (error "layout:expr-size — not an IR expression: ~S" expr))

    (t
     (ecase (node-op expr)

       (:contact
        (values 2 1))

       ;; :NOT delegates to the inner expression.
       ;; Normally-closed contacts are encoded as (:contact :NC op) by the
       ;; parser, so :NOT only wraps compound sub-expressions and is rare.
       (:not
        (expr-size (second expr)))

       ;; :AND — contacts in series: widths add, height is the maximum.
       (:and
        (let ((w 0) (h 1))
          (dolist (child (node-args expr))
            (multiple-value-bind (cw ch) (expr-size child)
              (incf w cw)
              (setf h (max h ch))))
          (values w h)))

       ;; :OR — contacts in parallel: width is the maximum (widest branch),
       ;;        height is the sum (branches stack vertically).
       (:or
        (let ((w 1) (h 0))
          (dolist (child (node-args expr))
            (multiple-value-bind (cw ch) (expr-size child)
              (setf w (max w cw))
              (incf h ch)))
          (values w h)))))))

;;; ---------------------------------------------------------------------------
;;; Pass 2: placement helpers
;;; ---------------------------------------------------------------------------

(defun fb-coil-p (kind)
  "True for coil kinds rendered as function-block boxes rather than coil glyphs."
  (member kind '(:mov :add :sub :cmp) :test #'eq))

(defun fb-coil-label (kind operand extra)
  "Build a compact display label for a data-register application coil."
  (flet ((str (x) (if x (princ-to-string x) "?")))
    (ecase kind
      (:mov  (format nil "MOV ~A→~A"
                     (str (first extra))
                     (if operand (symbol-name operand) "?")))
      (:add  (format nil "ADD ~A+~A→~A"
                     (str (first extra)) (str (second extra))
                     (if operand (symbol-name operand) "?")))
      (:sub  (format nil "SUB ~A-~A→~A"
                     (str (first extra)) (str (second extra))
                     (if operand (symbol-name operand) "?")))
      (:cmp  (format nil "CMP ~A,~A"
                     (str (first extra)) (str (second extra)))))))

;;; ---------------------------------------------------------------------------
;;; Pass 2: layout-rung
;;; ---------------------------------------------------------------------------

(defun layout-rung (rung &key (row 0))
  "Return a flat list of drawing primitives for RUNG, placed at grid row ROW.

RUNG must be an IR rung node of the form (:coil kind operand expr [extras...])
as produced by MELSEC-SIM.IR:IL->IR.

The coil (or function-block box) is placed one cell right of the contact
network's right edge.  All coordinates are in grid units."
  (destructuring-bind (tag kind operand expr &rest extra) rung
    (declare (ignore tag))
    ;; prims is accumulated by EMIT and returned reversed at the end.
    ;; The LET is the outermost form so NREVERSE at the bottom is in scope.
    (let ((prims '()))
      (flet ((emit (p) (push p prims)))
        (labels
            ((place (e x y w)
               "Place IR expression E in a box of width W at top-left (X, Y).
Emits :contact and :wire primitives only; coils are handled by the caller."
               (cond
                 ;; NIL / unconditional: bare horizontal wire
                 ((null e)
                  (emit (list :wire x y (+ x w) y)))

                 ;; Single contact: glyph at x, lead-out stub from x+1 to x+w
                 ((eq (node-op e) :contact)
                  (destructuring-bind (mode op) (node-args e)
                    (emit (list :contact x y mode op))
                    (when (> w 1)
                      (emit (list :wire (1+ x) y (+ x w) y)))))

                 ;; :NOT — NC is already encoded in the contact mode;
                 ;; for compound :NOT just delegate to the inner expr.
                 ((eq (node-op e) :not)
                  (place (second e) x y w))

                 ;; :AND — series layout: children left-to-right
                 ((eq (node-op e) :and)
                  (let ((cx x))
                    (dolist (child (node-args e))
                      (multiple-value-bind (cw ignore-h) (expr-size child)
                        (declare (ignore ignore-h))
                        (place child cx y cw)
                        (incf cx cw)))))

                 ;; :OR — parallel layout: children stacked vertically.
                 ;; Short branches are padded; vertical rails join branches
                 ;; below the first to the main trunk at row Y.
                 ((eq (node-op e) :or)
                  (let ((cy y))
                    (dolist (child (node-args e))
                      (multiple-value-bind (cw ch) (expr-size child)
                        (place child x cy cw)
                        (when (< cw w)
                          (emit (list :wire (+ x cw) cy (+ x w) cy)))
                        (when (> cy y)
                          (emit (list :wire x       y x       cy))
                          (emit (list :wire (+ x w) y (+ x w) cy)))
                        (incf cy ch)))))

                 (t
                  (error "layout:place — unknown IR node: ~S" e)))))

          ;; Main body: pass 2
          (multiple-value-bind (w ignore-h) (expr-size expr)
            (declare (ignore ignore-h))
            ;; 2a: contact network
            (place expr 0 row w)
            ;; 2b: stub wire into the coil
            (emit (list :wire w row (1+ w) row))
            ;; 2c: coil or FB box
            (if (fb-coil-p kind)
                (emit (list :fb (1+ w) row 2 1
                            (fb-coil-label kind operand extra)))
                (emit (list* :coil (1+ w) row kind operand extra))))))
      ;; Return primitives in chronological order.
      ;; This form is the last in the LET body, so PRIMS is still in scope.
      (nreverse prims))))

;;; ---------------------------------------------------------------------------
;;; layout-program
;;; ---------------------------------------------------------------------------

(defun layout-program (ir-program &key (row-gap 1))
  "Lay out a complete IR program (list of rung nodes), stacking rungs
vertically ROW-GAP grid cells apart.

Returns three values:
  PRIMITIVES       — flat list of all emitted drawing primitives
  TOTAL-ROWS       — total height consumed (grid cells)
  RUNG-ROW-STARTS  — list giving the starting row of each rung, in order

ROW-GAP defaults to 1 (one blank row between rungs); set to 0 for a compact
display or to 2 for extra breathing room."
  (let ((all  '())
        (row  0)
        (starts '()))
    (dolist (rung ir-program)
      (push row starts)
      ;; Rung height = height of its contact expression (≥ 1)
      (let* ((expr (fourth rung))
             (h    (if expr (nth-value 1 (expr-size expr)) 1)))
        (dolist (p (layout-rung rung :row row))
          (push p all))
        (incf row (+ (max h 1) row-gap))))
    (values (nreverse all)
            row
            (nreverse starts))))
