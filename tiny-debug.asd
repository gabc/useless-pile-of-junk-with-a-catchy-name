;;;								-*- Lisp -*-
;;; tiny-debug.asd -- System definition for tiny-debug
;;;

(defsystem tiny-debug
    :name               "tiny-debug"
    :description        "Command line debugger"
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :license            "GPLv3"
    :source-control	:git
    :long-description
    "This exists because I wanted command line editing in the debugger from my
REPL. It does afford one that modicum of efficacy, but scant else. Another
smidgeon is a uniform interface between platforms.
Unfortunately it's barely usable."
    :depends-on
    (:dlib :char-util :keymap :table-print :opsys :terminal :terminal-ansi
     :rl :fatchar :tiny-repl #+sbcl :sb-introspect)
    :components
    ((:file "tiny-debug")))
