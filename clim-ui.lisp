;;;; clim-ui.lisp — McCLIM ladder diagram viewer for melsec-sim.
;;;;
;;;; Consumes the backend-agnostic layout primitives from melsec-sim.layout;
;;;; no grid logic lives here — only the mapping from primitives to CLIM drawing
;;;; calls plus user interaction.
;;;;
;;;; Entry point:
;;;;   (ql:quickload "melsec-sim/clim")
;;;;   (melsec-sim.clim:run)
;;;;   (melsec-sim.clim:run :program my-program :scan-time-ms 50)
;;;;
;;;; Contacts are drawn via WITH-OUTPUT-AS-PRESENTATION, so clicking an operand
;;;; label (e.g. "X0") executes COM-TOGGLE, which flips the bit and runs one scan.
;;;; INCREMENTAL-REDISPLAY repaints the energised path after each scan automatically.

(defpackage #:melsec-sim.clim
  (:use #:clim #:clim-lisp)
  (:export #:run #:ladder-frame))

(in-package #:melsec-sim.clim)

(defparameter *cell* 56
  "Pixels per grid cell (maximum; shrunk to fit the viewport).")
(defparameter *margin* 30 "Pixel padding around the ladder on each side.")
(defparameter *min-cell* 44
  "Smallest cell size when fitting.  Operand labels stay readable above this.")
(defparameter *run-tick-seconds* 0.1
  "How often the ticker thread sends a scan+redisplay event in Run mode.")

;;; Presentation type — a drawn operand label is a clickable CLIM object.
(define-presentation-type operand () :inherit-from 'symbol)

;;; ---------------------------------------------------------------------------
;;; Application frame
;;; ---------------------------------------------------------------------------

(define-application-frame ladder-frame ()
  ((plc          :initarg  :plc       :accessor frame-plc)
   ;; Free-run state lives on the frame, not in the PLC, so the scan thread
   ;; is driven by CLIM tick events (HANDLE-EVENT), not a separate BT thread.
   (running      :accessor frame-running      :initform nil)
   ;; Layout is fixed once the PLC program is known; cache to avoid recomputing.
   (cached-prims :accessor frame-cached-prims :initform nil)
   (cached-rows  :accessor frame-cached-rows  :initform 0))
  (:menu-bar nil)
  (:panes
   (ladder :application
           :display-function   'display-ladder
           :incremental-redisplay t
           :scroll-bars        t
           :text-style         (make-text-style :sans-serif :roman 12))
   (io :application
       :display-function   'display-io
       :scroll-bars        t
       :text-style         (make-text-style :fix :roman 12))
   (interactor :interactor :height 110 :max-height 110))
  (:layouts
   (default
    (vertically ()
      (horizontally ()
        (4/5 (labelling (:label "Ladder") ladder))
        (1/5 (labelling (:label "I/O")    io)))
      (labelling (:label "Commands") interactor)))))

;;; ---------------------------------------------------------------------------
;;; Grid → pixel coordinate helpers
;;; ---------------------------------------------------------------------------

(defun gx (g)       (+ *margin* (round (* g *cell*))))
(defun lbl-size ()  (max 7 (round (* *cell* 0.2))))

;;; ---------------------------------------------------------------------------
;;; Lazy layout: IR parse + primitives computed once (program is fixed)
;;; ---------------------------------------------------------------------------

(defun ensure-layout (frame)
  (unless (frame-cached-prims frame)
    (let ((ir (melsec-sim.ir:il->ir
               (melsec-sim:plc-program (frame-plc frame)))))
      (multiple-value-bind (prims rows)
          (melsec-sim.layout:layout-program ir)
        (setf (frame-cached-prims frame) prims
              (frame-cached-rows  frame) rows)))))

;;; ---------------------------------------------------------------------------
;;; Viewport sizing
;;; ---------------------------------------------------------------------------

(defun content-extent (prims rows)
  "Return (values COLS ROWS) — total grid extent occupied by PRIMS."
  (let ((maxx 1) (maxy 1))
    (dolist (p prims)
      (ecase (first p)
        ((:contact :coil)
         (setf maxx (max maxx (+ 2 (second p)))
               maxy (max maxy (+ 1 (third p)))))
        (:wire
         (destructuring-bind (x1 y1 x2 y2) (rest p)
           (setf maxx (max maxx x1 x2) maxy (max maxy y1 y2))))
        (:fb
         (destructuring-bind (x y w h label) (rest p)
           (declare (ignore label))
           (setf maxx (max maxx (+ x w)) maxy (max maxy (+ y h)))))))
    (values (1+ maxx) (max (1+ maxy) rows))))

(defun fit-cell (pane cols rows)
  "Largest cell (≤ *CELL*, ≥ *MIN-CELL*) that makes COLS×ROWS fit in PANE."
  (let* ((vp (or (pane-viewport-region pane) (sheet-region pane)))
         (w  (- (bounding-rectangle-width  vp) (* 2 *margin*)))
         (h  (- (bounding-rectangle-height vp) (* 2 *margin*))))
    (max *min-cell*
         (min *cell*
              (floor (max 1 w) (max 1 cols))
              (floor (max 1 h) (max 1 rows))))))

;;; ---------------------------------------------------------------------------
;;; Drawing primitives
;;; ---------------------------------------------------------------------------

(defun format-duration (ms)
  "Format integer milliseconds as a compact string (e.g. 100ms, 1.5s)."
  (let ((ms (or ms 0)))
    (if (>= ms 1000)
        (format nil "~,1Fs" (* ms 0.001))
        (format nil "~Dms" ms))))

(defun energized-p (plc mode op)
  (let ((v (melsec-sim:plc-get-bit plc op)))
    (if (eq mode :nc) (not v) v)))

(defun draw-contact (pane x y mode op live)
  (let* ((cx (gx x)) (cy (gx y)) (ink (if live +forest-green+ +gray40+))
         (q  (round (* *cell* 1/4)))
         (x0 (+ cx q)) (x1 (+ cx (* 3 q))))
    (draw-line* pane cx cy x0 cy :ink ink :line-thickness 2)
    (draw-line* pane x1 cy (+ cx *cell*) cy :ink ink :line-thickness 2)
    (draw-line* pane x0 (- cy q) x0 (+ cy q) :ink ink :line-thickness 3)
    (draw-line* pane x1 (- cy q) x1 (+ cy q) :ink ink :line-thickness 3)
    (when (eq mode :nc)
      (draw-line* pane x0 (+ cy q) x1 (- cy q) :ink ink :line-thickness 2))
    (with-output-as-presentation (pane op 'operand)
      (draw-text* pane (symbol-name op) x0 (- cy q 6) :text-size (lbl-size)))))

(defun draw-coil (pane x y kind op live)
  (let* ((cx (gx x)) (cy (gx y)) (ink (if live +forest-green+ +gray40+))
         (q  (round (* *cell* 1/4)))
         (x0 (+ cx q))
         (lbl (ecase kind (:normal "( )") (:set "(S)") (:reset "(R)"))))
    (draw-line* pane cx cy x0 cy :ink ink :line-thickness 2)
    (draw-circle* pane (+ cx (round (* *cell* 1/2))) cy q
                  :filled nil :ink ink :line-thickness 3)
    (draw-text* pane (format nil "~A ~A" (symbol-name op) lbl)
                x0 (- cy q 6) :text-size (lbl-size))))

(defun draw-timer-counter (pane x y kind op live cv preset)
  "Box showing kind mnemonic and current-value/preset (e.g. 300ms/1000ms)."
  (let* ((cx  (gx x)) (cy (gx y)) (ink (if live +forest-green+ +gray40+))
         (qh  (round (* *cell* 1/3)))
         (x0  (+ cx 4)) (x1 (+ cx (* 2 *cell*) -4)) (mid (+ cx *cell*))
         (timerp  (member kind '(:ton :tof)))
         (cv-str  (if timerp (format-duration cv)     (princ-to-string (or cv 0))))
         (pt-str  (if timerp (format-duration preset) (princ-to-string (or preset 0)))))
    (draw-line* pane cx cy x0 cy :ink ink :line-thickness 2)
    (draw-rectangle* pane x0 (- cy qh) x1 (+ cy qh)
                     :filled nil :ink ink :line-thickness 2)
    (draw-text* pane (symbol-name kind) mid (- cy 3)
                :align-x :center :text-size (lbl-size) :ink ink)
    (draw-text* pane (format nil "~A/~A" cv-str pt-str)
                mid (+ cy qh -4)
                :align-x :center :text-size (lbl-size) :ink ink)
    (with-output-as-presentation (pane op 'operand)
      (draw-text* pane (symbol-name op) x0 (- cy qh 6) :text-size (lbl-size)))))

(defun draw-fb-primitive (pane x y w label)
  "Generic function-block box for data-register ops (label already computed by layout)."
  (let* ((qh (round (* *cell* 1/3)))
         (px (gx x)) (py (gx y)))
    (draw-rectangle* pane px (- py qh) (gx (+ x w)) (+ py qh)
                     :filled nil :line-thickness 2)
    (draw-text* pane label (+ px 4) py :text-size (lbl-size))))

;;; ---------------------------------------------------------------------------
;;; Display functions (called by McCLIM's redisplay machinery)
;;; ---------------------------------------------------------------------------

(defun display-ladder (frame pane)
  (ensure-layout frame)
  (let* ((plc   (frame-plc frame))
         (prims (frame-cached-prims frame))
         (rows  (frame-cached-rows  frame)))
    (multiple-value-bind (cols nrows) (content-extent prims rows)
      (let ((*cell* (fit-cell pane cols nrows)))
        (dolist (p prims)
          (ecase (first p)
            (:wire
             (destructuring-bind (x1 y1 x2 y2) (rest p)
               (draw-line* pane (gx x1) (gx y1) (gx x2) (gx y2)
                           :line-thickness 2 :ink +gray40+)))
            (:contact
             (destructuring-bind (x y mode op) (rest p)
               (draw-contact pane x y mode op (energized-p plc mode op))))
            (:coil
             (destructuring-bind (x y kind op &rest extra) (rest p)
               (let ((live (melsec-sim:plc-get-bit plc op)))
                 (if (member kind '(:ton :tof :ctu :ctd))
                     (draw-timer-counter
                      pane x y kind op live
                      (if (member kind '(:ton :tof))
                          (melsec-sim:plc-timer-acc   plc op)
                          (melsec-sim:plc-counter-cv  plc op))
                      (first extra))
                     (draw-coil pane x y kind op live)))))
            (:fb
             (destructuring-bind (x y w h label) (rest p)
               (declare (ignore h))
               (draw-fb-primitive pane x y w label)))))))))

(defun display-io (frame pane)
  (let* ((plc   (frame-plc frame))
         (bits  (sort (melsec-sim:plc-snapshot-bits  plc)
                      #'string< :key (lambda (x) (symbol-name (car x)))))
         (words (sort (melsec-sim:plc-snapshot-words plc)
                      #'string< :key (lambda (x) (symbol-name (car x))))))
    (format pane "~A  scan ~D~2%"
            (if (frame-running frame) "RUN" "STOP")
            (melsec-sim:plc-scan-count plc))
    (dolist (pair bits)
      (with-output-as-presentation (pane (car pair) 'operand)
        (format pane "~A ~A~%"
                (if (cdr pair) "[#]" "[ ]")
                (symbol-name (car pair)))))
    (when words
      (terpri pane)
      (dolist (pair words)
        (format pane "~A = ~D~%"
                (symbol-name (car pair)) (cdr pair))))))

;;; ---------------------------------------------------------------------------
;;; Tick event — drives free-run mode without polluting the interactor.
;;;
;;; A custom event is handled by HANDLE-EVENT in the frame's own process, so
;;; the sim is only ever touched from one thread (no extra locking needed here).
;;; ---------------------------------------------------------------------------

(defclass tick-event (window-manager-event)
  ((frame :initarg :frame :reader tick-event-frame)))

(defmethod handle-event (sheet (event tick-event))
  (declare (ignore sheet))
  (let ((frame (tick-event-frame event)))
    (when (frame-running frame)
      (melsec-sim:plc-step (frame-plc frame))
      (redisplay-frame-panes frame))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(define-ladder-frame-command (com-toggle :name "Toggle")
    ((op 'operand :gesture :select))
  "Flip a bit.  While stopped, runs one scan immediately so the display
reflects the new input state."
  (let ((plc (frame-plc *application-frame*)))
    (melsec-sim:plc-set-bit plc op (not (melsec-sim:plc-get-bit plc op)))
    (unless (frame-running *application-frame*)
      (melsec-sim:plc-step plc))))

(define-ladder-frame-command (com-scan :name "Scan")
    ()
  "Execute one full scan cycle, pausing free-run mode first."
  (setf (frame-running *application-frame*) nil)
  (melsec-sim:plc-step (frame-plc *application-frame*)))

(define-ladder-frame-command (com-step :name "Step")
    ()
  "Execute one full scan cycle (alias for Scan; melsec-sim scans are atomic)."
  (setf (frame-running *application-frame*) nil)
  (melsec-sim:plc-step (frame-plc *application-frame*)))

(define-ladder-frame-command (com-run :name "Run")
    ()
  "Start free-running: scan + redisplay every *RUN-TICK-SECONDS*."
  (let* ((frame *application-frame*)
         (sheet (frame-top-level-sheet frame)))
    (unless (frame-running frame)
      (setf (frame-running frame) t)
      (bt:make-thread
       (lambda ()
         (loop while (frame-running frame)
               do (sleep *run-tick-seconds*)
                  (queue-event sheet (make-instance 'tick-event
                                                    :sheet sheet
                                                    :frame frame))))
       :name "melsec-sim CLIM ticker"))))

(define-ladder-frame-command (com-stop :name "Stop")
    ()
  "Pause free-run mode."
  (setf (frame-running *application-frame*) nil))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun run (&key (program melsec-sim:*example-program*) (scan-time-ms 100))
  "Open the McCLIM ladder viewer.
PROGRAM   — list of MELSEC IL instruction forms (default: *EXAMPLE-PROGRAM*).
SCAN-TIME-MS — simulated scan period in ms; controls timer accumulation rate."
  (run-frame-top-level
   (make-application-frame 'ladder-frame
                           :plc (melsec-sim:make-plc program
                                                     :scan-time-ms scan-time-ms)
                           :width 1000 :height 760)))
