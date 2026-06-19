(asdf:defsystem "melsec-sim"
  :description "Mitsubishi MELSEC Instruction List PLC simulator"
  :author "Gregory Brooks"
  :license "MIT"
  :version "0.2.0"
  :depends-on ("bordeaux-threads")
  :components ((:file "melsec-sim")))

(asdf:defsystem "melsec-sim/tests"
  :description "Test suite for melsec-sim"
  :depends-on ("melsec-sim")
  :components ((:file "test-sim")))
