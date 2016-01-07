;;;								-*- Lisp -*-
;;; terminal-curses.asd -- System definition for terminal-curses
;;;

(defpackage :terminal-curses-system
    (:use :common-lisp :asdf))

(in-package :terminal-curses-system)

(defsystem terminal-curses
    :name               "terminal-curses"
    :description        "Faking a terminal with curses."
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :license            "GPLv3"
    :source-control	:git
    :long-description   "So many layers of fake like a cake."
    :depends-on (:terminal :curses :fui)
    :components
    ((:file "terminal-curses")))