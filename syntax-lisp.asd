;;;								-*- Lisp -*-
;;; syntax-lisp.asd -- System definition for syntax-lisp
;;;

(defsystem syntax-lisp
    :name               "syntax-lisp"
    :description        "Lexer for Lisp"
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :license            "GPLv3"
    :source-control	:git
    :long-description
    "A lexer for Lisp, which is nearly the same as a lisp reader."
    :depends-on (:dlib :syntax :dlib-misc #| :esrap |# :theme :style :grout
		 :fatchar)
    :components
    ((:file "syntax-lisp")))
