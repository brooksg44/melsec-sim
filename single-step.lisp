(ql:quickload :bordeaux-threads :silent t)
(load (merge-pathnames "melsec-sim.lisp" *load-pathname*))
(in-package :melsec-sim)

(defvar my-plc (make-plc *example-program* :scan-time-ms 100))

;; Press the Start button (X0)
(set-input my-plc 'x0 t)
(plc-step my-plc)
(print-state my-plc 'x0 'y0 't0 'c0)

;; Seal-in is active, we can release Start
(set-input my-plc 'x0 nil)
(plc-step my-plc)
(print-state my-plc 'x0 'y0 't0 'c0)

;; Step 10 more times to let the timer (T0) reach 1000ms (10 scans * 100ms)
(dotimes (i 10) (plc-step my-plc))
(print-state my-plc 'y0 't0) ; T0 should now be T

;; Press the Stop button (X1)
(set-input my-plc 'x1 t)
(plc-step my-plc)
(print-state my-plc 'y0 't0) ; Motor and Timer reset
(set-input my-plc 'x1 nil)
