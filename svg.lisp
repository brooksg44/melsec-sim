;;;; svg.lisp — SVG ladder diagram renderer for melsec-sim.
;;;;
;;;; Consumes the same backend-agnostic layout primitives as the McCLIM UI and
;;;; emits a self-contained SVG document.  No dependencies beyond the core
;;;; system — works without McCLIM installed.
;;;;
;;;; Static snapshot (no PLC state — all elements drawn in grey):
;;;;   (melsec-sim.svg:render-to-file *example-program* #p"ladder.svg")
;;;;   (melsec-sim.svg:render-to-string *example-program*)
;;;;
;;;; Live snapshot (energised elements coloured green):
;;;;   (melsec-sim.svg:render-to-file *example-program* #p"ladder.svg" :plc *plc*)

(defpackage #:melsec-sim.svg
  (:use #:cl)
  (:export #:render-to-string #:render-to-file #:render-to-stream))

(in-package #:melsec-sim.svg)

(defparameter *cell* 56 "Pixels per grid cell.")
(defparameter *margin* 32 "Pixel border around the diagram on each side.")

(defun %px (g) (+ *margin* (* g *cell*)))
(defun %ink (live) (if live "#1a7f37" "#444"))

(defun %xml (s)
  "Escape <, > and & for safe embedding in SVG text content."
  (with-output-to-string (out)
    (loop for c across s
          do (case c
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\& (write-string "&amp;" out))
               (t   (write-char c out))))))

(defun %fmt-duration (ms)
  (let ((ms (or ms 0)))
    (if (>= ms 1000)
        (format nil "~,1Fs" (* ms 0.001))
        (format nil "~Dms" ms))))

;;; ---------------------------------------------------------------------------
;;; Primitive draw functions
;;; ---------------------------------------------------------------------------

(defun %wire (out x1 y1 x2 y2)
  (format out
   "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='#444' stroke-width='2'/>~%"
   (%px x1) (%px y1) (%px x2) (%px y2)))

(defun %contact (out x y mode op plc)
  (let* ((cx (%px x)) (cy (%px y))
         (live (and plc
                    (let ((v (melsec-sim:plc-get-bit plc op)))
                      (if (eq mode :nc) (not v) v))))
         (color (%ink live))
         (x0 (round (+ cx (* *cell* 1/4))))
         (x1 (round (+ cx (* *cell* 3/4)))))
    ;; lead-in and lead-out wires within the 1-cell glyph
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
     cx cy x0 cy color)
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
     x1 cy (+ cx *cell*) cy color)
    ;; left and right contact bars
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='3'/>~%"
     x0 (- cy 12) x0 (+ cy 12) color)
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='3'/>~%"
     x1 (- cy 12) x1 (+ cy 12) color)
    ;; normally-closed diagonal slash
    (when (eq mode :nc)
      (format out
       "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
       x0 (+ cy 12) x1 (- cy 12) color))
    ;; operand label centred above
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace' fill='~A'>~A</text>~%"
     (+ cx (round (/ *cell* 2))) (- cy 16) color (symbol-name op))))

(defun %coil (out x y kind op plc &optional preset)
  (when (member kind '(:ton :tof :ctu :ctd))
    (return-from %coil (%box-coil out x y kind op plc preset)))
  (let* ((cx (%px x)) (cy (%px y))
         (live  (and plc (melsec-sim:plc-get-bit plc op)))
         (color (%ink live))
         (x0    (round (+ cx (* *cell* 1/4))))
         (x1    (round (+ cx (* *cell* 3/4))))
         (label (ecase kind (:normal "( )") (:set "(S)") (:reset "(R)"))))
    ;; lead-in wire
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
     cx cy x0 cy color)
    ;; left coil arc (curves left → forms the "(" shape)
    (format out
     "  <path d='M ~D ~D A 10 12 0 0 0 ~D ~D' fill='none' stroke='~A' stroke-width='3'/>~%"
     x0 (- cy 12) x0 (+ cy 12) color)
    ;; right coil arc (curves right → forms the ")" shape)
    (format out
     "  <path d='M ~D ~D A 10 12 0 0 1 ~D ~D' fill='none' stroke='~A' stroke-width='3'/>~%"
     x1 (- cy 12) x1 (+ cy 12) color)
    ;; label centred above
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace' fill='~A'>~A ~A</text>~%"
     (+ cx (round (/ *cell* 2))) (- cy 16) color (symbol-name op) label)))

(defun %box-coil (out x y kind op plc preset)
  "Two-cell-wide box for timer (:ton :tof) and counter (:ctu :ctd) outputs.
Shows the kind mnemonic and CV/PT (e.g. 300ms/1.0s or 2/3)."
  (let* ((cx  (%px x)) (cy (%px y))
         (live  (and plc (melsec-sim:plc-get-bit plc op)))
         (color (%ink live))
         (x0    (+ cx 5))
         (x1    (+ cx (* 2 *cell*) -5))
         (mid   (+ cx *cell*))
         (timerp (member kind '(:ton :tof)))
         (cv    (when plc
                  (if timerp
                      (melsec-sim:plc-timer-acc  plc op)
                      (melsec-sim:plc-counter-cv plc op))))
         (cv-str (if cv
                     (if timerp (%fmt-duration cv) (princ-to-string cv))
                     nil))
         (pt-str (if timerp
                     (%fmt-duration (or preset 0))
                     (princ-to-string (or preset 0)))))
    ;; lead-in wire
    (format out
     "  <line x1='~D' y1='~D' x2='~D' y2='~D' stroke='~A' stroke-width='2'/>~%"
     cx cy x0 cy color)
    ;; box
    (format out
     "  <rect x='~D' y='~D' width='~D' height='~D' fill='white' stroke='~A' stroke-width='2'/>~%"
     x0 (- cy 18) (- x1 x0) 36 color)
    ;; kind mnemonic (top line inside box)
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace' fill='~A'>~A</text>~%"
     mid (- cy 4) color (symbol-name kind))
    ;; CV/PT (bottom line inside box)
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace' fill='~A'>~A</text>~%"
     mid (+ cy 13) color
     (if cv-str
         (format nil "~A/~A" cv-str pt-str)
         (format nil "PT=~A" pt-str)))
    ;; instance name above box
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='11' font-family='monospace'>~A</text>~%"
     mid (- cy 22) (symbol-name op))))

(defun %fb (out x y w h label)
  "Generic function-block box for data-register operations (MOV / ADD / SUB / CMP).
The label string is pre-formatted by the layout engine."
  (declare (ignore h))
  (let* ((cx  (%px x)) (cy (%px y))
         (qh  (round (* *cell* 1/3)))
         (w-px (* w *cell*)))
    (format out
     "  <rect x='~D' y='~D' width='~D' height='~D' fill='#eef' stroke='#446' stroke-width='2'/>~%"
     cx (- cy qh) w-px (* 2 qh))
    (format out
     "  <text x='~D' y='~D' text-anchor='middle' font-size='10' font-family='monospace'>~A</text>~%"
     (+ cx (round (/ w-px 2))) (+ cy 4) (%xml label))))

;;; ---------------------------------------------------------------------------
;;; SVG bounding box
;;; ---------------------------------------------------------------------------

(defun %content-cols (prims)
  "Rightmost grid column occupied by PRIMS."
  (let ((maxx 1))
    (dolist (p prims maxx)
      (ecase (first p)
        ((:contact :coil)
         (setf maxx (max maxx (+ 2 (second p)))))
        (:wire
         (setf maxx (max maxx (second p) (fourth p))))
        (:fb
         (setf maxx (max maxx (+ (second p) (fourth p)))))))))

;;; ---------------------------------------------------------------------------
;;; Entry points
;;; ---------------------------------------------------------------------------

(defun render-to-stream (program &key plc (stream *standard-output*)
                                      (cell *cell*) (margin *margin*))
  "Write an SVG ladder diagram for PROGRAM to STREAM.
PLC — if supplied, energised contacts and coils are coloured green.
CELL — pixels per grid cell (default 56).
MARGIN — pixel border (default 32)."
  (let* ((*cell* cell) (*margin* margin)
         (ir (melsec-sim.ir:il->ir program)))
    (multiple-value-bind (prims total-rows)
        (melsec-sim.layout:layout-program ir)
      (let* ((cols   (%content-cols prims))
             (svg-w  (+ (* 2 margin) (* (1+ cols)       cell)))
             (svg-h  (+ (* 2 margin) (* (max 1 total-rows) cell))))
        (format stream "<?xml version='1.0' encoding='UTF-8'?>~%")
        (format stream
         "<svg xmlns='http://www.w3.org/2000/svg' width='~D' height='~D'>~%"
         svg-w svg-h)
        (format stream "  <rect width='100%' height='100%' fill='white'/>~%")
        (dolist (p prims)
          (ecase (first p)
            (:wire
             (apply #'%wire stream (rest p)))
            (:contact
             (destructuring-bind (x y mode op) (rest p)
               (%contact stream x y mode op plc)))
            (:coil
             (destructuring-bind (x y kind op &rest extra) (rest p)
               (%coil stream x y kind op plc (first extra))))
            (:fb
             (destructuring-bind (x y w h label) (rest p)
               (%fb stream x y w h label)))))
        (format stream "</svg>~%")))))

(defun render-to-string (program &key plc (cell *cell*) (margin *margin*))
  "Return an SVG document string for PROGRAM.
See RENDER-TO-STREAM for keyword arguments."
  (with-output-to-string (s)
    (render-to-stream program :plc plc :stream s :cell cell :margin margin)))

(defun render-to-file (program path &key plc (cell *cell*) (margin *margin*))
  "Write an SVG ladder diagram for PROGRAM to PATH.  Returns PATH.
See RENDER-TO-STREAM for keyword arguments."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (render-to-stream program :plc plc :stream out :cell cell :margin margin))
  path)
