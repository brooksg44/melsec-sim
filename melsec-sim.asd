(asdf:defsystem "melsec-sim"
  :description "Mitsubishi MELSEC Instruction List PLC simulator"
  :author "Gregory Brooks"
  :license "MIT"
  :version "0.3.0"
  :depends-on ("bordeaux-threads")
  :components ((:file "melsec-sim")))

;; IL→IR parser — standalone, no extra dependencies.
;; Load separately so the core simulator stays lightweight.
(asdf:defsystem "melsec-sim/ir"
  :description "Stack-to-tree IL→IR parser and IR constructors for melsec-sim"
  :author "Gregory Brooks"
  :license "MIT"
  :version "0.1.0"
  :depends-on ()
  :components ((:file "il-to-ir")))

(asdf:defsystem "melsec-sim/tests"
  :description "Test suite for melsec-sim"
  :depends-on ("melsec-sim" "melsec-sim/ir")
  :components ((:file "test-sim")))
