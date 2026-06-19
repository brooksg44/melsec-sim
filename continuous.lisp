(ql:quickload :bordeaux-threads :silent t)
(load (merge-pathnames "melsec-sim.lisp" *load-pathname*))
(in-package :melsec-sim)

(defvar my-plc (make-plc *example-program* :scan-time-ms 100))

(plc-run my-plc)

;; While running, interact with it:
(set-input my-plc 'x0 t)
(sleep 1.5) ; Wait 1.5 seconds
(print-state my-plc 'y0 't0) ; Will show Y0 is on, T0 is on

(set-input my-plc 'x2 t)
(set-input my-plc 'x2 nil)
(set-input my-plc 'x2 t)
(set-input my-plc 'x2 nil)
(set-input my-plc 'x2 t)
(set-input my-plc 'x2 nil)
(print-state my-plc 'c0) ; Will show C0 is ON (count reached 3)

(plc-stop my-plc)
