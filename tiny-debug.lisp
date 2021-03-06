;;
;; tiny-debug.lisp - Debugger for use with :TINY-REPL
;;

;;; TODO:
;;; - how about using swank?
;;; - split me up!
;;; - try getting more specific source location with *read-intern*

(defpackage :tiny-debug
  (:documentation
   "A crappy half-assed debugger for your enjoyment and frustration. But at
least you can type things using RL.")
  (:use :cl :dlib :char-util :table-print :keymap :terminal :terminal-ansi
	:rl :fatchar :tiny-repl #+sbcl :sb-introspect)
  (:export
   #:tiny-debug
   #:*default-interceptor*
   #:*interceptor-condition*
   #:*visual-mode*
   #:toggle
   #:active-p
   #:activate
   ))
(in-package :tiny-debug)

(declaim
 (optimize (speed 0) (safety 3) (debug 3) (space 0) (compilation-speed 0)))

(defvar *visual-mode* nil
  "True to use visual mode.")

(defvar *visual-term* nil
  "Terminal for visual mode.")

(defvar *current-frame* nil
  "Current frame number. Frames are numbered from the top or innermost 0 to
the outermost. When entering the debugger the current frame is 0.")

(defvar *saved-frame* nil
  "Implementation handle to frame that the debugger started from.")

;; Temporarily set the feature if the implementation supports breakpoints.
#+sbcl (eval-when (:compile-toplevel)
	 (d-add-feature :tdb-has-breakpoints))

(defun debugger-sorry (x)
  "What to say when we can't do something."
  (format *debug-io* "~%Sorry, don't know how to ~a on ~a. ~
		       Snarf some slime!~%" x (lisp-implementation-type)))

(defun print-span (span)
  ;; This doesn't work since some implementations wrap our terminal stream
  ;; with something else before it gets to print-object.
  ;;(princ (span-to-fat-string span) *terminal*)
  (render-fatchar-string (span-to-fatchar-string span) :terminal *terminal*))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Implementation specifc functions
;;
;; debugger-backtrace n     - Show N frames of normal backtrace
;; debugger-wacktrace n     - Alternate backtrace
;; debugger-show-source n   - Show the source for frame N
;; debugger-show-locals n   - Show local variables for frame N
;; debugger-internal-frame  - Return the best approximation of the error frame.

#+sbcl
(defun print-frame (f &optional (stream *debug-io*))
  "Print a frame."
  (labels ((print-lambda-list (f arg-list)
	     (loop :for v :in arg-list
		:do
		(cond
		  ((sb-di::debug-var-p v)
		   ;;(sb-di::debug-var-symbol v)
		   (let ((vv (handler-case
				 (sb-di::debug-var-value v f)
			       (condition () '#:|<Unavailable>|))))
		     (when (not (or (eql vv '#:|<Unavailable>|)
				    (typep vv 'condition)))
		       (format stream " ~s" vv))))
		  ((and (listp v) (eql (car v) :rest))
		   (format stream " &rest")
		   (print-lambda-list f (cdr v)))))))
    (let* ((loc     (sb-di:frame-code-location f))
	   (dbg-fun (sb-di:code-location-debug-fun loc))
	   (name    (sb-di:debug-fun-name dbg-fun)))
      (format stream "(")
      (if (symbolp name)
	  (let ((pkg (symbol-package name)))
	    (if (not (eql (find-package :cl) pkg))
		(format stream "~(~a~)::" (package-name pkg)))))
      (format stream "~(~a~)" name)
      (if (sb-di::debug-fun-%lambda-list dbg-fun)
	  (print-lambda-list f (sb-di::debug-fun-lambda-list dbg-fun))
	  (princ " <unavailable>" stream))
      (format stream ")"))))

#+sbcl
(defun sbcl-start-frame ()
  ;; introduced sometime after 1.0.57
  (let ((sym (find-symbol "BACKTRACE-START-FRAME" :sb-debug)))
    (if sym
     (funcall sym :debugger-frame)
     (sb-di:top-frame))))

#+sbcl
(defun debugger-wacktrace (n)
  "Our own backtrace for SBCL."
  ;; (or *saved-frame* (sb-di:top-frame))
  (loop
     :with f = (sbcl-start-frame)
     :and i = 0
     :do
     ;; (format *debug-io* "~3d " (sb-di:frame-number f))
     ;; (print-frame f)
     ;; (terpri *debug-io*)
     (print-span `((:fg-yellow ,(format nil "~3d" (sb-di:frame-number f))) " "))
     (print-frame f *terminal*)
     (terpri *terminal*)
     (setf f (sb-di:frame-down f))
     (incf i)
     :until (or (not f) (and n (>= i n)))))

#+sbcl
(defun debugger-backtrace-lines (n)
  (loop 
;;;     :with f = *saved-frame* #| (sbcl-start-frame) |#
     :with f = *current-frame*
     :for i :from 1 :to n
     :collect
     (with-output-to-string (str)
       (format str "~3d " (sb-di:frame-number f))
       (print-frame f str))
     :do
     (setf f (sb-di:frame-down f))
     :while f))

#|
#+ccl
(defun debugger-backtrace-lines (n)
  "Our own backtrace for CCL."
  (let ((frames '()) (*print-readably* nil))
    (ccl:map-call-frames
     #'(lambda (frame-ptr context)
	 (push (list frame-ptr context) frames))
     :origin ccl:*top-error-frame*
     :start-frame-number 0
     :count most-positive-fixnum)
    (setf frames (nreverse frames))
    (loop :with i = 0
       :for (f context) :in frames
       :collect
       (format nil "~3a (~a~{ ~s~})~%"
	       i (ccl:function-name (ccl:frame-function f context))
	       (ccl:frame-supplied-arguments f context))
       :do
       (incf i)
       :while (< i n))))
|#
#+ccl
(defun debugger-backtrace-lines (n)
  (loop :with i = 0
     :for b :in (ccl::backtrace-as-list)
     :if (>= i *current-frame*)
     :collect (format nil "~(~3d ~a~)" i b)
     :end
     :do
     (incf i)
     :while (< i (+ *current-frame* n))))

#+ccl
(defun debugger-wacktrace (n)
  "Our own backtrace for CCL."
  (declare (ignore n))			; @@@
  (let ((frames '()) (*print-readably* nil))
    (ccl:map-call-frames
     #'(lambda (frame-ptr context)
	 (push (list frame-ptr context) frames))
     :origin ccl:*top-error-frame*
     :start-frame-number 0
     :count most-positive-fixnum)
    (setf frames (nreverse frames))
    (loop :with i = 0
       :for (f context) :in frames
       :do
       ;; (format *debug-io* "~3a (~(~a~{ ~s~}~))~%" i
       ;; 	       (or (ignore-errors
       ;; 		     (ccl:function-name (ccl:frame-function f context))) "")
       ;; 	       (or (ignore-errors
       ;; 		     (ccl:frame-supplied-arguments f context)) '("")))
       (print-span `((:fg-yellow ,(format nil "~3a" i)) " ("
		     ,(format nil "~(~a~{ ~s~}~)~%"
			      (or (ignore-errors
				    (ccl:function-name
				     (ccl:frame-function f context))) "")
			      (or (ignore-errors
				    (ccl:frame-supplied-arguments f context))))))
       (incf i))))

#-(or ccl sbcl)
(defun debugger-wacktrace (n)
  (declare (ignore n)) (debugger-sorry "wacktrace"))

#+ccl
(defun OLD-get-frame (n)
  (let ((f 0) frame-ptr context)
    (ccl:map-call-frames
     #'(lambda (p c)
	 (when (= f n)
	   (setf frame-ptr p
		 context c)
	   (incf f)))
     :origin ccl:*top-error-frame*
     :start-frame-number 0
     :count most-positive-fixnum)
    (values frame-ptr context)))

#+ccl
(defun get-frame (n)
  (let ((f 0) frame-ptr context)
    (ccl:map-call-frames
     #'(lambda (p c)
	 (when (= f (1+ n))
	   (setf frame-ptr p
		 context c))
	 (incf f)))
    (values frame-ptr context)))

;; (ccl:map-call-frames
;;  #'(lambda (p c)
;;      (multiple-value-bind (func pc) (ccl:frame-function p c)
;;        (format t "~s ~s ~4d ~s~%~s~%" p c pc func
;; 	       (ccl:source-note-filename (ccl:function-source-note func))))))

#+ccl
(defun debugger-source-note (n)
  (multiple-value-bind (pointer context) (get-frame n)
    (multiple-value-bind (func pc) (ccl:frame-function pointer context)
      (if pc
	  (or (ccl:find-source-note-at-pc func pc)
	      (ccl:function-source-note func))
	  (ccl:function-source-note func)))))
#+ccl
(defun debugger-show-source (n)
  (when (not n)
    (setf n 0))
  (let ((*print-readably* nil))
    (multiple-value-bind (pointer context) (get-frame n)
      (multiple-value-bind (func pc) (ccl:frame-function pointer context)
	(let ((note (if pc
			(or (ccl:find-source-note-at-pc func pc)
			    (ccl:function-source-note func))
			(ccl:function-source-note func))))
	  (when note
	    (cond
	      ((ccl:source-note-text note)
	       (format *debug-io* "~a~%" (ccl:source-note-text note)))
	      ((ccl:source-note-filename note)
	       (with-open-file (stream (ccl:source-note-filename note))
		 (file-position stream (ccl:source-note-start-pos note))
		 (let* ((len (- (ccl:source-note-end-pos note)
				(ccl:source-note-start-pos note)))
			(str (make-array (list len) :element-type 'character)))
		   (read-sequence str stream)
		   (format *debug-io* "~a~%" str)))))))))))


#|#+sbcl
(defun stream-source-position (code-location stream)
  (let* ((cloc (sb-debug::maybe-block-start-location code-location))
         (tlf-number (sb-di::code-location-toplevel-form-offset cloc))
         (form-number (sb-di::code-location-form-number cloc)))
    (multiple-value-bind (tlf pos-map) (read-source-form tlf-number stream)
      (let* ((path-table (sb-di::form-number-translations tlf 0))
             (path (cond ((<= (length path-table) form-number)
                          (warn "inconsistent form-number-translations")
                          (list 0))
                         (t
                          (reverse (cdr (aref path-table form-number)))))))
        (source-path-source-position path tlf pos-map)))))

#+sbcl
(defun code-location-has-debug-block-info-p (code-location)
  (handler-case
      (progn (sb-di:code-location-debug-block code-location)
             t)
    (sb-di:no-debug-blocks  () nil)))

(defun fallback-source-location (code-location)
  )

(defun source-file-source-location (code-location)
  )
|#

#|
#+sbcl
(defun debugger-source (frame-number)
  (when (not frame-number)
    (setf frame-number 0))
  (let ((frame (frame-number frame-number))
	(loc  (sb-di::frame-code-location frame))
	(src  (sb-di::code-location-debug-source loc))
	(filename (sb-c::debug-source-namestring src)))
    (if filename
	(if (code-location-has-debug-block-info-p code-location)
	    (source-file-source-location code-location)
	    (fallback-source-location code-location))
	(prin1-to-string
	 (sb-debug::code-location-source-form loc 100)))))
|#

#|
(with-open-file (str filename)
      (file-position str pos)
      (loop
	 :for i :from 1 :to 10
	 :collect
	 (read-line str nil nil)
	 ;;(format nil "~s~%" (sb-di:debug-fun-start-location dbg-fun))
	 ))))
|#

#+sbcl
(defun debugger-source-path (frame)
#|  (let* ((fun (sb-di:code-location-debug-fun
	       (sb-di:frame-code-location frame)))
	 (src (and fun (sb-introspect:find-definition-source
			(symbol-function
			 (sb-di:debug-fun-name fun))))))
    (if src
	(definition-source-pathname src)
	":Unknown"))) |#
  (let* ((loc (sb-di:frame-code-location frame))
	 (src (sb-di::code-location-debug-source loc)))
    (sb-c::debug-source-namestring src)))
  
#+ccl
(defun debugger-source-path (frame &optional (window-size 10))
  (declare (ignore window-size)) ; @@@
  (let ((note (debugger-source-note frame)))
    (cond
      ((not note)
       ":Unknown")
      ((ccl:source-note-filename note)
       (ccl:source-note-filename note))
      (t
       ":Internal"))))

;;; Return the number of the form corresponding to CODE-LOCATION. The
;;; form number is derived by a walking the subforms of a top level
;;; form in depth-first order.
;;; (defun code-location-form-number (code-location)

#+sbcl
(defun get-loc-subform-pos (loc)
  "Return the file position of the subform."
  (declare (ignore loc))
  )

#+sbcl
(defmacro compiled-debug-function-form-number (fun)
  (let ((sym
	 (or (find-symbol "COMPILED-DEBUG-FUN-TLF-NUMBER" :sb-c)    ; older name
	     (find-symbol "COMPILED-DEBUG-FUN-FORM-NUMBER" :sb-c))))
    `(,sym ,fun)))

#+sbcl
(defun get-loc-form-offset (loc)
  (if (sb-di::code-location-unknown-p loc)
      ;; on some version before 1.4.2 it was:
      ;;(sb-c::compiled-debug-fun-tlf-number
      (compiled-debug-function-form-number
       (sb-di::compiled-debug-fun-compiler-debug-fun
	(sb-di::compiled-code-location-debug-fun loc)))
      (sb-di:code-location-toplevel-form-offset loc)))

#+sbcl
(defun get-snippet-pos (stream loc)
  (let ((form-offset (get-loc-form-offset loc))
	start-pos form)
    (let ((*read-suppress* t)
	  (eof (cons nil nil)))
      (loop :with i = 0
	 :while (and (<= i form-offset)
		     (not (eq eof
			      (setf start-pos (file-position stream)
				    form (read stream nil eof)))))
	 :do
	 (incf i)))
    (values start-pos form)))

#+sbcl
(defun debugger-source (frame &optional (window-size 10))
  (let* ((loc (sb-di:frame-code-location frame))
	 ;;(fun (and loc (sb-di:code-location-debug-fun loc)))
	 ;;(src (and fun (sb-introspect:find-definition-source
	 ;;		(symbol-function
	 ;;		 (sb-di:debug-fun-name fun)))))
	 ;;(path (definition-source-pathname src))
	 ;;(offset (definition-source-character-offset src))
	 ;;
	 (src2        (sb-di::code-location-debug-source loc))
	 ;;(form-num    (sb-di::code-location-form-number loc))
	 ;;(form-offset (sb-di::code-location-toplevel-form-offset loc))
	 ;; (sb-di::code-location-source-form loc context??)
	 ;; (sb-di::get-toplevel-form loc)
	 (path2       (sb-c::debug-source-namestring src2))
	 offset)
;;;    (if src2
    (with-open-file (stream path2)
      (setf offset (get-snippet-pos stream loc))
      (file-position stream offset)
      (loop :with line
	 :for i :from 1 :to window-size
	 :while (setf line (read-line stream nil nil))
	 :collect line))))

#+ccl
(defun debugger-source (frame &optional (window-size 10))
  (let ((note (debugger-source-note frame)))
    (if (not note)
	(list "Sorry, I can't figure it out.")
	(cond
	  ((ccl:source-note-text note)
	   (list (format nil "~a~%" (ccl:source-note-text note))))
	  ((ccl:source-note-filename note)
	   (with-open-file (stream (ccl:source-note-filename note))
	     (file-position stream (ccl:source-note-start-pos note))
	     #|(let* ((len (- (ccl:source-note-end-pos note)
			    (ccl:source-note-start-pos note)))
		    (str (make-array (list len) :element-type 'character)))
	       (read-sequence str stream)
	     (format nil "~a~%" str)))))))) |#
	     (loop :with line
		:for i :from 1 :to window-size
		:while (setf line (read-line stream nil nil))
		:collect line)))))))

#+sbcl
(defun debugger-show-source (n)
  (let ((frame
	 (cond
	   ((numberp n) (frame-number n))
	   (t *current-frame*))))
    ;;(format t "~s~%" (debugger-source frame))))
    (loop :for s :in (debugger-source frame)
       :do (format t "~a~%" s))))

#-(or ccl sbcl)
(defun debugger-show-source (n)
  (declare (ignore n)) (debugger-sorry "show source"))

#+ccl
(defun debugger-show-locals (n)
  (let ((*print-readably* nil))
    (multiple-value-bind (pointer context) (get-frame n)
    (loop :for (name . value) :in (ccl:frame-named-variables pointer context)
       :do
       (format *debug-io* "~a = ~a~%" name value)))))

#+sbcl
(defun frame-number (n)
  "Return the internal frame object given a frame number."
  (let ((result 
	 (loop :with f = (sb-di:top-frame)
	    :for fn :from 0 :below n
	    :do (setf f (sb-di:frame-down f))
	    :finally (return f))))
    (assert (= (sb-di:frame-number result) n))
    result))

#+sbcl
(defun frame-number-or-current (&optional (n *current-frame*))
  "Return the frame numbered N, or the *current-frame*, or the top frame."
  (cond
    ((numberp n) (frame-number n))
    ((sb-di:frame-p n) n)
    (t (frame-number 0))))

#+sbcl
(defun debugger-show-locals (n)
  (if n
      (format *debug-io* "Locals for frame ~s:~%" n)
      (format *debug-io* "Locals for current frame:~%"))
  (let* ((cur (frame-number-or-current n))
	 (fun (sb-di:frame-debug-fun cur)))
    (if (sb-di:debug-var-info-available fun)
	(let* ((*print-readably* nil)
	       (loc (sb-di:frame-code-location cur)))
	  (loop :for v :in (sb-di:ambiguous-debug-vars fun "")
	     :do
	     (when (eq (sb-di:debug-var-validity v loc) :valid)
              (format *debug-io* "~S~:[#~W~;~*~] = ~S~%"
                      (sb-di:debug-var-symbol v)
                      (zerop (sb-di:debug-var-id v))
                      (sb-di:debug-var-id v)
                      (sb-di:debug-var-value v cur))))))))

;; test fun for locals:
;; (defun foo (x)
;;   (declare (optimize (debug 3)))
;;   (let ((a "hi") (b "bye")) (+ x 23) (format t "~a ~a~%" a b)))

#-(or sbcl ccl)
(defun debugger-show-locals (n)
  (declare (ignore n)) (debugger-sorry "show locals"))

#|
#+ecl (defvar *stack-base* 0)

#+ecl
(defun ecl-args (frame)
  (let ((base (or (si::sch-frs-base si::*frs-top* *stack-base*)
		  (1+ (si::frs-top)))))
    (loop :with i :and name
       :for f :from base :until (si::frs-top)
       :do
       (setf i (- (si::frs-ihs f) *stack-base* 1))
       :if (and (plusp i) (= i frame) (not (si::fixnump (si::frs-tag f))))
       :collect (si::frs-tag f))))

(si::ihs-env i)
|#

#+ecl
(defun ecl-backtrace (n)
  ;; (loop :for i :from 0 :below (min (si::ihs-top) n)
  ;;    :do (format *debug-io* "~a ~a~%" (si::ihs-fun i) #|(ecl-args i)|#))
  (let* ((top (if n (min n (si::ihs-top)) (si::ihs-top)))
	 (stack (reverse (loop :for i :from 1 :below top
			    :collect (si::ihs-fun i)))))
    (loop :for s :in stack :and i = 0 :then (1+ i)
       :do (format *debug-io* "~3d: ~w~%" i s))))

;; As you may know, this is very implementation specific.
(defun debugger-backtrace (n)
  "Output a list of execution stack contexts. Try to limit it to the
innermost N contexts, if we can."
  #+sbcl
  (let ((bt-func (if (< *lisp-version-number* 10300)
		     (intern "BACKTRACE" :sb-debug)
		     (intern "PRINT-BACKTRACE" :sb-debug))))
    (if n (funcall bt-func n) (funcall bt-func)))
;  #+sbcl (sbcl-wacktrace)
  #+cmu (if n (debug:backtrace n) (debug:backtrace))
  #+ccl (loop :with i = 0
	   :for b :in (ccl::backtrace-as-list)
	   :do
	   (print-span `((:fg-yellow ,(format nil "~3d" i))
			 ,(format nil " ~(~a~)~%" b)))
	   ;;(format *debug-io* "~(~3d ~a~)~%" i b)
	   (incf i)
	   :while (or (null n) (and (numberp n) (< i n))))
;  #+clisp (system::print-backtrace :mode 4)  ; @@@ pick different modes?
  ;; Or perhaps
  #+clisp (catch 'debug (system::debug-backtrace "4"))
  #+lispworks (dbg:output-backtrace :full)
  #+ecl (ecl-backtrace n)
  #+abcl
  (loop :with i = 0
     :for f :in (sys:backtrace)
     :do (format *debug-io* "~(~3d ~a~)~%" i (sys:frame-to-string f)) (incf i)
     :while (or (null n) (and (numberp n) (< i n))))
  #-(or sbcl ccl clisp lispworks ecl cmu abcl)
  (debugger-sorry "backtrace"))

(declaim (inline debugger-internal-frame))
(defun debugger-internal-frame ()
  #+sbcl (or sb-debug::*stack-top-hint* (sb-di::top-frame))
  ;;  #+ccl ccl:*top-error-frame*
  #+ccl 0
  ;; We don't want to be sorry here, so just be wrong.
  #-(or sbcl ccl) nil)

#+sbcl
(defun debugger-up-frame (&optional (count 1))
  (declare (ignore count))
  (let ((next (sb-di:frame-up *current-frame*)))
    (if next
	(setf *current-frame* next))))

#+ccl
(defun debugger-up-frame (&optional (count 1))
  (when (> *current-frame* 0)
    (decf *current-frame* (or count 1))))

#+sbcl
(defun debugger-down-frame (&optional (count 1))
  (declare (ignore count))
  (let ((next (sb-di:frame-down *current-frame*)))
    (if next
	(setf *current-frame* next))))

#+ccl
(defun debugger-down-frame (&optional (count 1))
  (incf *current-frame* (or count 1)))

#+sbcl
(defun debugger-set-frame (frame)
  (cond
    ((or (not frame) (and (numberp frame) (= frame 0)))
     (sb-di:top-frame))
    ((numberp frame)
     (setf *current-frame* (frame-number frame)))
    ((sb-di:frame-p frame)
     (setf *current-frame* frame))
    (t
     (format *debug-io* "No such frame ~s~%" frame))))

#+ccl
(defun debugger-set-frame (frame)
  (setf *current-frame* frame))

#+sbcl
(defun debugger-top-frame (count)
  (declare (ignore count))
  (setf *current-frame* *saved-frame*))

#+ccl
(defun debugger-top-frame (count)
  (declare (ignore count))
  (setf *current-frame* 0)) ;; XXX wrong?

;; Stepping

#+sbcl
(progn
  ;; (defvar *step-form* nil)
  ;; (defvar *step-args* nil)
  (defun stepper (c)
    "Thing to set the stepper hook to."
    ;; (setf *step-form* (sb-ext::step-condition-form c)
    ;;  	  *step-args* (sb-ext::step-condition-args c))
    (format *debug-io* "-- TinY SteppeR --~%")
    ;; Handle special stepping conditions:
    (typecase c
      (sb-ext:step-values-condition
       (format *debug-io* "Form: ~s~%Result: ~s~%"
	       (slot-value c 'sb-kernel::form)
	       (slot-value c 'sb-kernel::result))
       (finish-output *debug-io*)
       (return-from stepper)))
    (finish-output *debug-io*)
    (let ((sb-debug::*stack-top-hint* (sb-di::find-stepped-frame))
	  (sb-ext::*stepper-hook* nil))
      (invoke-debugger c))))

(defun activate-stepper ()
  "Activate the Tiny-DEBUG setpper."
  #+sbcl (setf sb-ext::*stepper-hook* 'stepper)
  #+(or sbcl) (format *debug-io* "Activating the TINY stepper.~%"))

;; Breakpoints

#+(and sbcl tdb-has-breakpoints)
(progn
  (defvar *breakpoints* '()
    "List of known breakpoints.")

  (defun breaker (frame obj)
    "Function called when a breakpoint is hit."
    (declare (ignore obj))
    (format *debug-io* "You gots breaked!~%")
    ;; (invoke-debugger (make-condition
    ;; 		      'simple-condition
    ;; 		      :format-control "Breakpoint"))
    (tiny-debug (make-condition
		 'simple-condition
		 :format-control "Breakpoint") nil frame))

  (defun set-func-breakpoint (fun)
    (if (sb-di:fun-debug-fun fun)
	(let ((bp (sb-di:make-breakpoint
		   #'breaker
		   (sb-di:fun-debug-fun fun) :kind :fun-start)))
	  (if bp
	      (progn
		(push bp *breakpoints*)
		(sb-di:activate-breakpoint bp))
	      (format *debug-io* "Can't make no breakpoint fer ~s~%" fun)))
	(format *debug-io* "Ain't no debug fun fer ~s~%" fun)))

  (defun find-breakpoint (n)
    (nth (1- n) *breakpoints*))
  
  (defun activate-breakpoint (n)
    (let ((bp (find-breakpoint n)))
      (if bp
	  (sb-di:activate-breakpoint bp)
	  (format *debug-io* "No such breakpoint ~a~%" n))))

  (defun deactivate-breakpoint (n)
    (let ((bp (find-breakpoint n)))
      (if bp
	  (sb-di:deactivate-breakpoint bp)
	  (format *debug-io* "No such breakpoint ~a~%" n))))

  (defun toggle-breakpoint (n)
    (let ((bp (find-breakpoint n)))
      (if bp
	  (if (sb-di:breakpoint-active-p bp)
	      (sb-di:deactivate-breakpoint bp)
	      (sb-di:activate-breakpoint bp))
	  (format *debug-io* "No such breakpoint ~a~%" n))))

  (defun delete-breakpoint (n)
    (let ((bp (find-breakpoint n)))
      (if bp
	  (sb-di:deactivate-breakpoint bp)
	  (format *debug-io* "No such breakpoint ~a~%" n))))

  (defun list-breakpoints ()
    (let ((rows
	   (loop :for b :in *breakpoints* :and i = 1 :then (1+ i)
	      :collect (list i
			     (sb-di:breakpoint-active-p b)
			     (sb-di:breakpoint-kind b)
			     (sb-di:breakpoint-what b)
			     (sb-di:breakpoint-info b)))))
      (nice-print-table rows '("#" "Act" "Kind" "What" "Info")
			:stream *debug-io*)))
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Implementation independent functions

(defparameter *box_drawings_light_horizontal*
  #+(or sbcl cmu) #\box_drawings_light_horizontal
  #+(or ccl lispworks) #\U+2500
  #-(or sbcl cmu ccl lispworks) #\-)

(defparameter *box_drawings_light_vertical_and_left*
  #+(or sbcl cmu) #\box_drawings_light_vertical_and_left
  #+(or ccl lispworks) #\U+2524
  #-(or sbcl cmu ccl lispworks) #\|)

(defparameter *box_drawings_light_vertical_and_right*
  #+(or sbcl cmu) #\box_drawings_light_vertical_and_right
  #+(or ccl lispworks) #\U+251C
  #-(or sbcl cmu ccl lispworks) #\|)

(defun horizontal-line (tt &optional note)
  (terminal-color tt :blue :default)
  (if note
      (progn
	(terminal-write-string tt (s+
			     *box_drawings_light_horizontal*
			     *box_drawings_light_horizontal*
			     *box_drawings_light_vertical_and_left*))
	(terminal-color tt :white :black)
	(terminal-write-string tt (s+ " " note " "))
	(terminal-color tt :blue :default)
	(terminal-write-char tt *box_drawings_light_vertical_and_right*)
	(terminal-format tt "~v,,,va"
		   (- (terminal-window-columns tt) (length (s+ note)) 6)
		   *box_drawings_light_horizontal*
		   *box_drawings_light_horizontal*)
	(terminal-color tt :default :default)
	(terminal-write-char tt #\newline))
      ;; no note, just a line
      (progn
      	(terminal-color tt :blue :default)
	(terminal-format tt "~v,,,va~%"
		   (1- (terminal-window-columns tt))
		   *box_drawings_light_horizontal*
		   *box_drawings_light_horizontal*)
	(terminal-color tt :default :default))))

(defun sanitize-line (line)
  (when line
    (if (> (length line) 0)
	(apply #'s+ (map 'list #'char-util:displayable-char line))
	line)))

(defun visual ()
  (let ((tt *visual-term*))
    (terminal-get-size tt)
    (with-saved-cursor (tt)
      (let* ((source-height (truncate (/ (terminal-window-rows tt) 3)))
	     (stack-height (min 10 source-height))
	     (command-height (- (terminal-window-rows tt)
				(+ stack-height source-height 2)))
	     (command-top (- (terminal-window-rows tt) (1- command-height)))
	     (src (or (ignore-errors
			(debugger-source *current-frame* source-height))
		      '("Unavailable.")))
	     (path (or (ignore-errors
			 (debugger-source-path *current-frame*))
		       '("Unknown")))
	     (stack (or (ignore-errors
			  (debugger-backtrace-lines stack-height))
			'("????"))))
	;; Source area
	;;(terminal-clear tt)
	(terminal-move-to tt (+ source-height stack-height 2) 0)
	(terminal-erase-above tt)
	(terminal-home tt)
	(loop :with line :and sp = src
	   :for i :from 0 :below source-height :do
	   (setf line (car sp))
	   (if line
	       (progn
		 (setf line (sanitize-line line))
		 (terminal-format tt "~a~%"
			    (subseq line
				    0 (min (- (terminal-window-columns tt) 2)
					   (length line))))
		 (setf sp (cdr sp)))
	       (terminal-format tt "~~~%")))
	(horizontal-line tt path)
	;; Stack area
	(loop :with line :and sp = stack
	   :for i :from 0 :below stack-height :do
	   (setf line (car sp))
	   (if line
	       (progn
		 (terminal-format tt "~a~%"
			    (subseq line
				    0 (min (1- (terminal-window-columns tt))
					   (length line))))
		 (setf sp (cdr sp)))
	       (terminal-format tt "~~~%")))
	(horizontal-line tt)
	;; Command area
	(terminal-set-scrolling-region tt command-top (terminal-window-rows tt))
	(terminal-move-to tt (1- (terminal-window-rows tt)) 0)
	(terminal-finish-output tt)))))

(defun start-visual ()
  (when *visual-mode*
    (when (not *visual-term*)
      (setf *visual-term* (make-instance 'terminal-ansi))
      (terminal-start *visual-term*))
    (let ((tt *visual-term*))
      (terminal-get-size tt)
      (terminal-move-to tt (1- (terminal-window-rows tt)) 0)
      (terminal-finish-output tt))))

(defun reset-visual ()
  (when *visual-term*
    (let ((tt *visual-term*))
      (terminal-set-scrolling-region tt nil nil)
      (terminal-move-to tt (1- (terminal-window-rows tt)) 0)
      (terminal-finish-output tt)
      #| (terminal-end tt) |#)))

(defun debugger-up-frame-command (&optional foo)
  (declare (ignore foo))
  (debugger-up-frame)
  (visual))

(defun debugger-down-frame-command (&optional foo)
  (declare (ignore foo))
  (debugger-down-frame)
  (visual))

(defun list-restarts (rs)
  #|
  (format *debug-io* "Restarts are:~%")
  (loop :with i = 0 :for r :in rs :do
     (format *debug-io* "~&")
     (print-span `((:fg-cyan ,(format nil "~d" i)) ": "))
     (when (not (ignore-errors (progn (format *debug-io* "~s ~a~%"
					      (restart-name r) r) t)))
       (format *debug-io* "Error printing restart ")
       (print-unreadable-object (r *debug-io* :type t :identity t)
	 (format *debug-io* "~a" (restart-name r)))
       (terpri *debug-io*))
     (incf i))
  |#
  (format *terminal* "Restarts are:~%")
  (loop :with i = 0 :for r :in rs :do
     (format *terminal* "~&")
     (print-span `((:fg-cyan ,(princ-to-string i)) ": "))
     (when (not (ignore-errors (progn (format *terminal* "~s ~a~%"
					      (restart-name r) r) t)))
       (format *terminal* "Error printing restart ")
       (print-unreadable-object (r *terminal* :type t :identity t)
	 (format *terminal* "~a" (restart-name r)))
       (terpri *terminal*))
     (incf i))
  )

(defun debug-prompt (e p)
;;;  (format *debug-io* "Debug ~d~a" *repl-level* p)
  (when *visual-mode*
    (visual))
  (fresh-line *debug-io*)
  (rl::editor-write-string		; XXX
   e
   (format nil "Debug ~d~a" *repl-level* p))
;  (finish-output *debug-io*)
  nil)

;;;(declaim (special *interceptor-condition*))
(defvar *interceptor-condition* nil
  "The condition that happened.")

(defun debugger-help ()
  (print-span
   `("Tiny Debugger help:" #\newline
(:fg-cyan ":h") "      " (:fg-white "Show this help.") #\newline
(:fg-cyan ":e") "      " (:fg-white "Show the error again.") #\newline
(:fg-cyan ":a") "      " (:fg-white "Abort to top level.") #\newline
(:fg-cyan ":c") "      " (:fg-white "Invoke continue restart.") #\newline
(:fg-cyan ":q") "      " (:fg-white "Quit the whatever.") #\newline
(:fg-cyan ":r") "      " (:fg-white "Show restarts.") #\newline
(:fg-cyan ":b") "      " (:fg-white "Backtrace stack.") #\newline
(:fg-cyan ":w") "      " (:fg-white "Wacktrace.") #\newline
(:fg-cyan ":s [n]") "  " (:fg-white "Show source for a frame N, which defaults to the current frame.") #\newline
(:fg-cyan ":l [n]") "  " (:fg-white "Show local variables for a frame N, which defaults to the current frame.") #\newline))
 #+tdb-has-breakpoints
(print-span `(
(:fg-cyan ":lbp") "    " (:fg-white "List breakpointss.") #\newline
(:fg-cyan ":sbp") "    " (:fg-white "Set breakpoints on function.")  #\newline
(:fg-cyan ":tbp") "    " (:fg-white "Toggle breakpoints.")  #\newline
(:fg-cyan ":abp") "    " (:fg-white "Activate breakpoints.")  #\newline
(:fg-cyan ":dbp") "    " (:fg-white "Deactivate breakpoints.")  #\newline
(:fg-cyan ":xbp") "    " (:fg-white "Delete breakpoints.")  #\newline))
(print-span `(
(:fg-cyan "number") "     " (:fg-white "Invoke that number restart (from the :r list).") #\newline
(:fg-cyan "...") "      " (:fg-white "Or just type a some lisp code.") #\newline))
(list-restarts (cdr (compute-restarts *interceptor-condition*))))

(defun debugger-snargle (arg)
  "Magic command just for me."
  (error "Pizza ~s ~s." arg (type-of arg)))

(defun toggle-visual-mode (state)
  (declare (ignore state))
  (setf *visual-mode* (not *visual-mode*))
  (if *visual-mode*
      (start-visual)
      (reset-visual)))

;;; @@@ I actually want to take defcommand out of lish and make it be generic.
;;; And then also the command completion from lish to generic completion.
;;; Then we can define debugger commands nicely with completion and the whole
;;; shebang.

(defun debugger-interceptor (value state)
  "Handle special debugger commands, which are usually keywords."
  (let ((restarts (cdr (compute-restarts *interceptor-condition*))))
    (labels
	((do-restart (r)
	   (format *debug-io* "~:(~a~).~%" r)
	   ;; This is like find-restart, but omits the most recent abort
	   ;; which is this debugger's.
	   (let ((borty (find r restarts :key #'restart-name)))
	     (if (not borty)
		 (format *debug-io* "Can't find an ~a restart!~%" r)
		 (invoke-restart-interactively borty)))))
      (cond
	;; We use keywords as commands, just in case you have a variable or some
	;; other symbol clash. I dunno. I 'spose we could use regular symbols,
	;; and have a "print" command.
	((typep value 'keyword)
	 (let ((ks (string value)))
	   ;; :r<n> restart keywords - to be compatible with CLisp
	   (when (and (> (length ks) 1) (equal (aref ks 0) #\R))
	     (let ((n (parse-integer (subseq ks 1))))
	       ;; (invoke-restart-interactively (nth n (compute-restarts)))))
	       ;; (format t "[Invoking restart ~d (~a)]~%" n (nth n restarts))
	       (invoke-restart-interactively (nth n restarts))))
	   (or
	    (case value
	      (:b (debugger-backtrace (read-arg state)) t)
	      (:w (debugger-wacktrace (read-arg state)) t)
	      (:r (list-restarts restarts) t)
	      (:s (debugger-show-source (read-arg state)) t)
	      (:l (debugger-show-locals (read-arg state)) t)
	      ((:h :help) (debugger-help) t)
	      (:z (debugger-snargle    (read-arg state)) t)
	      (:v (toggle-visual-mode  (read-arg state)) t)
	      (:u (debugger-up-frame   (read-arg state)) t)
	      (:d (debugger-down-frame (read-arg state)) t)
	      (:f (debugger-set-frame  (read-arg state)) t)
	      (:t (debugger-top-frame  (read-arg state)) t)
	      (:e (print-condition *interceptor-condition*) t)
	      (:a (do-restart 'abort) t)
	      (:c (do-restart 'continue) t)
	      ((:q :quit)
	       (when (y-or-n-p "Really quit?")
		 (format *debug-io* "We quit.~%")
		 (nos:exit-lisp))
	       t))
	    #+tdb-has-breakpoints
	    (case value
	      ((:lb :lbp :list)	      (list-breakpoints) t)
	      ((:sb :sbp :set)	      (set-func-breakpoint
				       (eval (read-arg state))) t)
	      ((:tb :tbp :toggle)     (toggle-breakpoint (read-arg state)) t)
	      ((:ab :abp :activate)   (activate-breakpoint (read-arg state)) t)
	      ((:db :dbp :deactivate) (deactivate-breakpoint (read-arg state)) t)
	      ((:xb :xbp :delete)     (delete-breakpoint (read-arg state)) t)
	      ))))
	;; symbols that aren't keywords
	((typep value 'symbol)
	 (case (intern (string value) :tiny-debug)
	   (backtrace (debugger-backtrace (read-arg state)) t)
	   (source    (debugger-show-source (read-arg state)) t)
	   (locals    (debugger-show-locals (read-arg state)) t)
	   (help      (debugger-help) t)
	   (abort     (do-restart 'abort) t)
	   (continue  (do-restart 'continue) t)
	   (next      t)
	   (step      t)
	   (out       t)
	   ))
	;; Numbers invoke that numbered restart.
	((typep value 'number)
	 (if (and (>= value 0) (< value (length restarts)))
	     (invoke-restart-interactively (nth value restarts))
	     (format *debug-io*
		     "~a is not a valid restart number.~%" value)))))))

(defun try-to-reset-curses ()
  "If curses is loaded and active, try to reset the terminal to a sane state
so when we get in error in curses we can type at the debugger."
  (when (find-package :curses)
    (funcall (find-symbol (symbol-name '#:endwin) (find-package :curses)))))

;; @@@ It might be nice if we could avoid this duplication and just call the
;; one in terminal-ansi.
(defun try-to-reset-terminal ()
  "Try to reset the terminal to a sane state so when we get in error in some
program that messes with the terminal, we can still type at the debugger."
  (flet ((out (s) (format *terminal-io* "~c~a" #\escape s)))
    ;; First reset the terminal driver to a sane state.
    (nos:reset-terminal-modes)
    ;; Then try to reset the terminal itself to a sane state, assuming an ANSI
    ;; terminal. We could just do ^[c, which is quite effective, but it's
    ;; pretty drastic, and usually clears the screen and can even resize the
    ;; window, which is so amazingly annoying. So let's just try do individual
    ;; things that need resetting.  This is pretty much the idea of
    ;; termcap/info reset string, usually the "rs2", since "rs" usually just
    ;; does ^[c.
    (when (typep *terminal* 'terminal-ansi:terminal-ansi)
      (mapcar
       #'out '(" F"  ;; 7 bit controls
	       "[0m" ;; color and attributes
	       ">"   ;; normal keypad
	       "#@"  ;; default char set
	       "m"   ;; memory unlock
	       "[4l" ;; replace mode (vs insert mode)
	       "[?4l" ;; jump scroll (vs smooth scroll)
	       "[?25h" ;; show the cursor
	       "[?9l"  ;; Don't send position on mouse press
	       "[?47l" ;; Use normal screen buffer
	       )))
    (finish-output)))

(defvar *debugger-keymap* nil "Keymap for the debugger.")
(defvar *debugger-escape-keymap* nil "Escape key Keymap for the debugger.")

(defun setup-keymap ()
  (setf *debugger-keymap* (copy-keymap rl:*normal-keymap*))
  (define-key *debugger-keymap* (meta-char #\i) 'debugger-up-frame-command)
  (define-key *debugger-keymap* (meta-char #\o) 'debugger-down-frame-command)
  (setf *debugger-escape-keymap*
;;	(add-keymap rl::*escape-raw-keymap*
;;		    (build-escape-map *debugger-keymap*)))
	(build-escape-map *debugger-keymap*))
  (define-key *debugger-keymap* #\escape '*debugger-escape-keymap*))

(defun print-condition (c)
  (print-span
   `((:fg-white "Condition: ")
     (:fg-red (:underline ,(princ-to-string (type-of c))) #\newline
	      ,(princ-to-string c) #\newline))))

(defun tiny-debug (c hook &optional frame)
  "Entry point for the tiny debugger, used as the debugger hook."
  (declare (ignore hook))		;@@@ wrong
  (setf *saved-frame* (or frame (debugger-internal-frame)))
  (when (not *debugger-keymap*)
    (setup-keymap))
  (unwind-protect
    (progn
      ;;(try-to-reset-curses)
      (try-to-reset-terminal)
      (start-visual)
      (when (> *repl-level* 20)
	(format t "Something has probably gone wrong, so I'm breaking.~%")
	;; Abort assumes a restart is active, which may not be the case.
	;; But break seems to work.
	(break))
      (format *debug-io* "Entering the TINY debugger.~%")
;      (invoke-restart-interactively nil)
      ;; @@@ how do i invoke a restart to resolve conflicts?
      ;; or set variables?
      (with-standard-io-syntax
	(let ((*interceptor-condition* c)
	      (*current-frame* *saved-frame*)
	      ;; Reset reader vars to sane values:
	      ;; [probably uneeded since we use with-standard-io-syntax]
	      (*read-suppress* nil)
	      (*read-base* 10)
	      (*read-eval* t)
	      ;; printer vars
	      (*print-readably* nil)
	      (*print-length* 50)	; something reasonable?
	      (*print-circle* t))
	  (print-condition c)
	  (list-restarts (compute-restarts c))
	  (tiny-repl :interceptor #'debugger-interceptor
		     :prompt-func #'debug-prompt
		     :keymap *debugger-keymap*
		     :output *debug-io*
		     :debug t
		     :no-announce t))))
;;;    (Format *debug-io* "Exiting the debugger level ~d~%" *repl-level*)
    (reset-visual)))

; (defvar *repl-debug* nil
;   "True to invoke the debugger when a error occurs.")

(defun in-emacs-p ()
  "Return true if we're being run under Emacs, like probably in SLIME."
  (d-getenv "EMACS"))

(defun activate ()
  (when (not (in-emacs-p))
    (format *debug-io* "Activating the TINY debugger.~%")
    (setf *debugger-hook* 'tiny-debug)
    (activate-stepper)))

(defvar *saved-debugger-hook* nil
  "The old value of *debugger-hook*, so we can restore it.")

(defun toggle ()
  "Toggle the ‘Tiny’ debugger on and off."
  (when (not (in-emacs-p))
    (if (eq *debugger-hook* 'tiny-debug)
	(setf *debugger-hook* *saved-debugger-hook*)
	(setf *saved-debugger-hook* *debugger-hook*
	      *debugger-hook* 'tiny-debug))))

(defun active-p ()
  "Return true if the debugger is set to activate."
  (eq *debugger-hook* 'tiny-debug))

;; Remove temporary features
#+tbd-has-breakpoints (d-remove-feature :tdb-has-breakpoints)

;; EOF
