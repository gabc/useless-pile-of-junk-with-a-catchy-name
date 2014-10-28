;;;								-*- Lisp -*-
;;; fui.asd -- System definition for fui
;;;

(defpackage :fui-system
    (:use :common-lisp :asdf))

(in-package :fui-system)

(defsystem fui
    :name               "fui"
    :description        "Fake UI"
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :licence            "None" ; [sic]
    :long-description   "totally fake old style user interface"
    :depends-on (:curses :stretchy :dlib :dlib-misc :opsys)
    :components
    ((:file "fui")))