;;
;; puca.lisp - Putative Muca (A very simple(istic) interface to CVS/git/svn)
;;
;; (a.k.a Muca-ing for fun)
;; This was translated from puca.pl, written in Perl, which is my excuse for
;; why it's poorly organized.
;;
;; TODO:
;;  - puca options, e.g. show all tracked files
;;  - file change history mode
;;  - way to provide command options?
;;  - way to invoke unbound subcommand?
;;  - improve git mode
;;    - show things to pull? (e.g. changes on remote)
;;  - Consider making a branch editing mode
;;  - Consider making a version editing mode
;;  - Consider configuration / options editing
;;     like for "git config ..." or whatever the equivalent is in other systems

(defpackage :puca
  (:documentation
   "Putative Muca (A very simple(istic) interface to CVS/git/svn).")
  (:use :cl :dlib :dlib-misc :opsys :keymap :char-util :curses :rl
	:completion :inator :terminal :terminal-curses :fui :options :ppcre)
  (:export
   ;; Main entry point
   #:puca
   #:!puca
   #:make-standalone
   ))
(in-package :puca)

(declaim (optimize (speed 0) (safety 3) (debug 3) (space 0)
		   (compilation-speed 0)))

(defstruct goo
  "A file/object under version control."
  selected
  modified
  filename
  extra-lines)

(defvar *puca* nil
  "The current puca instance.")

(defclass puca (fui-inator options-mixin)
  ((backend
    :initarg :backend :accessor puca-backend :initform nil
    :documentation "The revision control system backend that we are using.")
   (goo
    :initarg :goo :accessor puca-goo :initform nil
    :documentation "A list of goo entries.")
   (maxima
    :initarg :maxima :accessor puca-maxima :initform 0
    :documentation "Number of items.")
   (mark
    :initarg :mark :accessor puca-mark :initform nil
    :documentation "One end of the region")
   (top
    :initarg :top :accessor puca-top :initform 0
    :documentation "Top item")
   (bottom
    :initarg :bottom :accessor puca-bottom :initform nil
    :documentation "Bottom item.")
   (errors
    :initarg :errors :accessor puca-errors :initform nil
    :documentation "Error output")
   (extra
    :initarg :extra :accessor puca-extra :initform nil
    :documentation "extra lines")
   (message
    :initarg :has-message :accessor puca-message :initform nil
    :documentation "A message to show.")
   (first-line
    :initarg :first-line :accessor puca-first-line :initform nil 
    :documentation "The first line of the objects.")
   (debug
    :initarg :debug :accessor puca-debug :initform nil :type boolean
    :documentation "True to turn on debugging."))
  (:default-initargs
   :point 0)
  (:documentation "An instance of a version control frontend app."))

(defparameter *puca-prototype* nil
  "Prototype PUCA options.")

(defoption puca show-all-tracked option :value nil
	   :documentation "Show all tracked files.")

(defclass backend ()
  ((name
    :initarg :name :accessor backend-name :type string
    :documentation "The name of the back-end.")
   (list-command
    :initarg :list-command :accessor backend-list-command
    :documentation "Command to list the things.")
   (add
    :initarg :add :accessor backend-add :type string
    :documentation "Command to add a file to the repository.")
   (reset
    :initarg :reset :accessor backend-reset :type string
    :documentation "Command to do something like whatever git reset does.")
   (diff
    :initarg :diff :accessor backend-diff :type string
    :documentation "Command to show the difference vs the last change.")
   (diff-repo
    :initarg :diff-repo :accessor backend-diff-repo :type string
    :documentation "Command to show the some kind of more differences.")
   (commit
    :initarg :commit :accessor backend-commit :type string
    :documentation "Commit the changes.")
   (update
    :initarg :update :accessor backend-update :type string
    :documentation "Update the file from the remote or repository.")
   (update-all
    :initarg :update-all :accessor backend-update-all :type string
    :documentation "Update the whole directory from the remote or repository.")
   (push
    :initarg :push :accessor backend-push :type string
    :documentation "Push the changes to the remote in a distributed RCS.")
   (ignore-file
    :initarg :ignore-file :accessor backend-ignore-file  :type string
    :documentation "File which contains a list of files to ignore."))
  (:documentation "A generic version control back end."))

;; Things a backend may want / need to implement.

(defgeneric check-existence (type)
  (:documentation
   "Return true if we guess we are in a directory under this type."))

(defgeneric parse-line (backend line i)
  (:documentation "Take a line and add stuff to goo and/or *errors*."))

(defgeneric add-ignore (backend file)
  (:documentation "Add FILE to the list of ignored files."))

(defgeneric banner (backend)
  (:documentation "Print something at the top of the screen."))

(defgeneric get-status-list (backend)
  (:documentation "Return a list of files and their status."))

;; Generic implementations of some possibly backend specific methods.

(defmethod parse-line ((backend backend) line i)
  "Parse a status line LINE for a typical RCS. I is the line number."
  (with-slots (goo errors extra) *puca*
    (let (match words tag file)
      (multiple-value-setq (match words)
	(scan-to-strings "\\s*(\\S+)\\s+(.*)$" line))
      (when (and match words)
	(setf tag (elt words 0)
	      file (elt words 1)))
      ;; (debug-msg "~s ~s (~s) (~s)" line words tag file)
      (cond
	;; If the first word is more than 1 char long, save it as extra
	((> (length tag) 2)
	 (push line extra)
	 (push (format nil "~d: ~a" i line) errors))
	;; skip blank lines
	((or (not match) (not words)))
	(t
	 (push (make-goo :modified (subseq tag 0 1) :filename file) goo)
	 ;; If we've accumulated extra lines add them to this line.
	 (when extra
	   (setf (goo-extra-lines (car goo)) (nreverse extra))
	   (setf extra nil)))))))

(defmethod get-status-list ((backend backend))
  "This is for backends which just have a fixed list command."
  (let* ((i 0)
	 (cmd (backend-list-command (puca-backend *puca*)))
	 (cmd-name (car cmd))
	 (cmd-args (cdr cmd))
	 line)
    (with-process-output (stream cmd-name cmd-args)
      (loop :while (setf line (read-line stream nil nil))
	 :do
	 (incf i)
	 (message *puca* "Listing...~d" i)
	 (refresh)
	 :collect line))))

(defmethod add-ignore ((backend backend) file)
  "Add FILE to the list of ignored files."
  (when (not (backend-ignore-file backend))
    (info-window
     "Problem"
     (list (format nil "I don't know how to ignore with ~a."
		   (backend-name backend))))
    (return-from add-ignore nil))
  (with-open-file (stream (backend-ignore-file backend)
			  :direction :output
			  :if-exists :append
			  :if-does-not-exist :create)
    (write-line file stream))
  (get-list)
  (draw-screen))

(defmethod banner ((backend backend))
  "Print something useful at the top of the screen."
  (addstr (format nil "~a~%" (nos:current-directory))))

(defun check-dir-and-command (dir command)
  (let ((result (probe-directory dir)))
    (when (and result (not (command-pathname command)))
      (cerror "Proceed anyway."
	      "Looks like a ~a directory, but ~a isn't installed?"
	      dir command))
    result))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CVS

(defclass cvs (backend)
  ()
  (:default-initargs
   :name	 "CVS"
   :list-command '("cvs" "-n" "update")
   :add		 "cvs add ~{~a ~}"
   :reset	 "echo 'No reset in CVS'"
   :diff	 "cvs diff ~{~a ~} | pager"
   :diff-repo	 "cvs diff -r HEAD ~{~a ~} | pager"
   :commit	 "cvs commit ~{~a ~}"
   :update	 "cvs update ~{~a ~}"
   :update-all	 "cvs update"
   :push	 "echo 'No push in CVS'"
   :ignore-file	 ".cvsignore")
  (:documentation "CVS."))

(defparameter *backend-cvs* (make-instance 'cvs))

(defmethod check-existence ((type (eql :cvs)))
  (check-dir-and-command "CVS" "cvs"))

(defmethod parse-line ((backend cvs) line i)
  (with-slots (goo errors extra) *puca*
    (let ((words (split-sequence " " line
				 :omit-empty t
				 :test #'(lambda (a b)
					   (declare (ignore a))
					   (or (equal b #\space)
					       (equal b #\tab))))))
      (dbug "~s~%" words)
      (cond
	;; If the first word is more than 1 char long, save it as extra
	((> (length (first words)) 1)
	 (push line extra)
	 (push (format nil "~d: ~a" i line) errors))
	;; skip blank lines
	((or (not words)
	     (and (= (length words) 1)
		  (= (length (first words)) 0))))
	(t
	 (push (make-goo :modified (elt words 0)
			 :filename (elt words 1)) goo)
	 ;; If we've accumulated extra lines add them to this line.
	 (when extra
	   (setf (goo-extra-lines (first goo)) (nreverse extra))
	   (setf extra nil)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; GIT

(defclass git (backend)
  ((saved-branch
    :initarg :saved-branch :accessor git-saved-branch :initform nil
    :documentation "Saved branch description.")
   (saved-remotes
    :initarg :saved-remotes :accessor git-saved-remotes :initform nil
    :documentation "Saved list of remotes."))
  (:default-initargs
   :name	      "git"
   :list-command      '("git" "status" "--porcelain")
   :add		      "git --no-pager add ~{~a ~}"
   :reset	      "git --no-pager reset ~{~a ~}"
   :diff	      "git diff --color ~{~a ~} | pager"
   :diff-repo	      "git diff --color --staged | pager"
   :commit	      "git --no-pager commit ~{~a ~}"
   :update	      "git --no-pager pull ~{~a ~}"
   :update-all	      "git --no-pager pull"
   :push	      "git --no-pager push"
   :ignore-file	      ".gitignore")
  (:documentation "Backend for git."))

(defmethod check-existence ((type (eql :git)))
  (and (check-dir-and-command ".git" "git")
       (equal "true" (shell-line "git" "rev-parse" "--is-inside-work-tree"))))

(defun get-branch (git)
  (or (git-saved-branch git)
      (subseq (first (lish:!_ "git status -s -b --porcelain")) 3)))

(defun get-remotes (git)
  (or (git-saved-remotes git)
      (lish:!_ "git remote -v")))

(defmethod banner ((backend git))
  "Print something useful at the top of the screen."
  (let ((line (getcury *stdscr*))
	(col 5)
	(branch (get-branch backend)))
    (labels ((do-line (fmt &rest args)
	       (let ((str (apply #'format nil fmt args)))
		 (mvaddstr (incf line) col
			   (subseq str 0 (min (length str)
					      (- *cols* col 1)))))))
      (do-line "Repo:    ~a" (nos:current-directory))
      (do-line "Branch:  ~a" branch)
      (do-line "Remotes: ")
      (loop :with s
	 :for r :in (get-remotes backend)
	 :do
	 (setf s (split "\\s" r))
	 (do-line "~a ~a ~a" (elt s 0) (elt s 2) (elt s 1)))
      (move (incf line) col))))

(defmethod get-status-list ((backend git))
  (with-slots (backend) *puca*
    (let* ((cmd (backend-list-command backend))
	   (cmd-name (car cmd))
	   (cmd-args (cdr cmd))
	   (i 0)
	   line result)
      ;; Invalidate the cache of banner info.
      (setf (git-saved-branch backend) nil
	    (git-saved-remotes backend) nil
	    result
	    (with-process-output (stream cmd-name cmd-args)
	      (loop :while (setf line (read-line stream nil nil))
		 :do
		 (incf i)
		 (message *puca* "Listing...~d" i)
		 (refresh)
		 :collect line)))
      ;;(debug-msg "~a from git status" i)
      (when (puca-show-all-tracked *puca*)
	(setf result
	      (append result
		      (with-process-output (stream "git" '("ls-files"))
			(loop :while (setf line (read-line stream nil nil))
			   :do
			   (incf i)
			   (message *puca* "Listing...~d" i)
			   (refresh)
			   :collect (s+ " _ " line)))))
	;;(move 0 0) (erase) (addstr (format nil "~w" result))
	;;(debug-msg "~a from git ls-files" i)
	)
      result)))

;; history mode

#|
(defun glorp (f)
  (!_= "git" "--no-pager" "log" "--format=(\"%h\" \"%ae\" %ct \"%s\")" "--" f))

(defun zermel ()
  (let ((hh (loop :for r :in (glorp "completion.lisp")
	       :collect (safe-read-from-string r))))
    (table-print:nice-print-table
     (mapcar (_ (list
		 (s+ (subseq (first (cdr _)) 0 3) "..")
		 (dlib-misc:date-string
		  :format :relative
		  :time (uos:unix-to-universal-time (second (cdr _))))
		 (third (cdr _)))) hh)
     '("email" "date" "message"))))
|#

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SVN

(defclass svn (backend)
  ()
  (:default-initargs
   :name		"SVN"
   :list-command	'("svn" "status")
   :add			"svn add ~{~a ~}"
   :reset		"svn revert ~{~a ~}"
   :diff		"svn diff ~{~a ~} | pager"
   :diff-repo		"svn diff -r HEAD ~{~a ~} | pager"
   :commit		"svn commit ~{~a ~}"
   :update		"svn update ~{~a ~}"
   :update-all		"svn update"
   :push		"echo 'No push in SVN'")
  (:documentation "Backend for SVN."))

(defmethod check-existence ((type (eql :svn)))
  (check-dir-and-command ".svn" "svn"))

;; @@@ I haven't tested this.
(defmethod add-ignore ((backend svn) file)
  "Add FILE to the list of ignored files."
  (do-literal-command "svn propset svn:ignore \"~a\" ." (list file)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mercurial (hg)

(defclass hg (backend)
  ()
  (:default-initargs
   :name		"hg"
   :list-command	'("hg" "status")
   :add			"hg add ~{~a ~}"
   :reset		"hg revert ~{~a ~}"
   :diff		"hg diff ~{~a ~} | pager"
   :diff-repo		"hg diff ~{~a ~} | pager"
   :commit		"hg commit ~{~a ~}"
   :update		"hg pull ~{~a ~}?"
   :update-all		"hg pull"
   :push		"hg push")
  (:documentation "Backend for Mercurial."))

(defmethod check-existence ((type (eql :hg)))
  (check-dir-and-command ".hg" "hg"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defparameter *backends* '(:git :cvs :svn :hg)
  "The availible backends.")

(defun format-message (fmt &rest args)
  (move (- *lines* 2) 2)
  (clrtoeol)
  (addstr (apply #'format nil fmt args)))

(defun draw-message (p)
  (format-message (puca-message p)))

(defmethod message ((p puca) format-string &rest format-args)
  "Display a message in the message area."
  (setf (puca-message p) (apply #'format nil format-string format-args))
  (draw-message p)
  ;; (refresh)
  )

(defun goo-color (status-char)
  "Set the color based on the status character."
  (case status-char
    (#\M (color-attr +color-red+     +color-black+))    ; modified
    (#\? (color-attr +color-white+   +color-black+))    ; unknown
    (#\C (color-attr +color-magenta+ +color-black+))	; conflicts
    (t   (color-attr +color-green+   +color-black+))))	; updated or other

(defun draw-goo (i)
  "Draw the goo object, with the appropriate color."
  (with-slots (goo top first-line) *puca*
    (let ((g (elt goo i)))
      (let* ((attr (goo-color (aref (goo-modified g) 0))))
	(move (+ (- i top) first-line) 4)
	;; (clrtoeol)
	(attron attr)
	(addstr (format nil "~a ~a ~30a"
			(if (goo-selected g) "x" " ")
			(goo-modified g)
			(goo-filename g)))
	(attroff attr)
	(when (goo-extra-lines g)
;; Ugly inline error display:
;;      (if (= i cur)
;; 	  (loop :with j = 0
;; 	     :for line :in (goo-extra-lines g)
;; 	     :do
;; 	     (mvaddstr (+ (- i top) 3 j) 20 line)
;; 	     (incf j))
	  (mvaddstr (+ (- i top) 3) 30 " ****** "))))))

(defun draw-line (i)
  "Draw line I, with the appropriate color."
  (draw-goo i))

(defun get-list ()
  "Get the list of files/objects from the backend and parse them."
  (message *puca* "Listing...")
  (with-slots (goo top errors maxima (point inator::point) cur extra) *puca*
    (setf goo '()
	  errors '()
	  extra '())
    (loop
       :for line :in (get-status-list (puca-backend *puca*))
       :and i = 0 :then (1+ i)
       :do
       (parse-line (puca-backend *puca*) line i))
    (setf goo (nreverse goo)
	  errors (nreverse errors))
    (setf maxima (length goo))
    (when (>= point maxima)
      (setf point (1- maxima)))
    (when (>= top point)
      (setf top (max 0 (- point 10)))))
  (message *puca* "Listing...done"))

(defun draw-screen ()
  (with-slots (maxima top bottom goo message backend first-line) *puca*
    (erase)
    (border 0 0 0 0 0 0 0 0)
    (let* ((title (format nil "~a Muca (~a)" 
			  (backend-name backend)
			  (machine-instance)))
	   y x)
      (declare (ignorable x))
      (move 1 (truncate (- (/ *cols* 2) (/ (length title) 2))))
      (addstr title)
      (move 2 2) ;; Start of the banner area
      (banner backend)
      (getyx *stdscr* y x)
      ;; End of the banner and start of the first line of objects
      (setf first-line (1+ y)
	    bottom (min (- maxima top) (- curses:*lines* first-line 3)))
      ;; top scroll indicator
      (when (> top 0)
	(mvaddstr (1- first-line) 2 "^^^^^^^^^^^^^^^^^^^^^^^"))
      (when (> (length goo) 0)
	(loop :for i :from top :below (+ top bottom)
	   :do (draw-goo i)))
      ;; bottom scroll indicator
      (when (< bottom (- maxima top))
	(mvaddstr (+ first-line bottom) 2 "vvvvvvvvvvvvvvvvvvvvvvv")))
    (when message
      (draw-message *puca*)
      (setf message nil))))

(defun do-literal-command (format-str format-args
			   &key (relist t) (do-pause t) confirm)
  "Do the command resulting from applying FORMAT-ARGS to FORMAT-STRING.
If RELIST is true (the default), regenerate the file list. If DO-PAUSE is true,
pause after the command's output. If CONFIRM is true, ask the user for
confirmation first."
  (clear)
  (refresh)
  (endwin)
  (when (and confirm (not (yes-or-no-p "Are you sure? ")))
    (return-from do-literal-command (values)))
  (let* ((command (apply #'format nil format-str format-args)))
    (lish:! command))
  (when do-pause
    (write-string "[Press Return]")
    (terpri)
    (read-line))
  (initscr)
  (message *puca* "*terminal* = ~s" *terminal*)
  (when relist
    (get-list))
  (clear)
  (draw-screen))

(defun do-command (command format-args
		   &rest keys &key (relist t) (do-pause t) confirm)
  "Do a command resulting from the backend function COMMAND, applying
FORMAT-ARGS. If RELIST is true (the default), regenerate the file list.
If CONFIRM is true, ask the user for confirmation first."
  (declare (ignorable relist do-pause confirm))
  (apply #'do-literal-command (apply command (list (puca-backend *puca*)))
	 (list format-args) keys)
  (values))

(defun selected-files ()
  "Return the selected files or the current line, if there's no selections."
  (with-slots (maxima goo (point inator::point)) *puca*
    (let* ((files
	    (loop :for i :from 0 :below maxima
	       :when (goo-selected (elt goo i))
	       :collect (goo-filename (elt goo i)))))
      (or files (and goo (list (goo-filename (elt goo point))))))))

(defun select-all ()
  (with-slots (maxima goo) *puca*
    (loop :for i :from 0 :below maxima
       :do (setf (goo-selected (elt goo i)) t))))

(defun select-none ()
  (with-slots (maxima goo) *puca*
    (loop :for i :from 0 :below maxima
       :do (setf (goo-selected (elt goo i)) nil))))

#|
(defun fake-draw-screen ()
  "For debugging."
;  (init-curses)
  (draw-screen)
  (tt-get-char)
  (endwin))
|#

(defun debug-msg (fmt &rest args)
  "For debugging."
  (move (- *lines* 2) 2)
;  (clrtoeol)
  (addstr (apply #'format nil fmt args))
  (refresh)
  (tt-get-char))

(defun info-window (title text-lines)
  (fui:display-text title text-lines)
  (clear)
  ;;(refresh)
  (draw-screen)
  (refresh))

(defun input-window (title text-lines)
  (prog1
      (display-text
       title text-lines
       :input-func #'(lambda (w)
		       (cffi:with-foreign-pointer-as-string (str 40)
			 (curses:echo)
			 (wgetnstr w str 40)
			 (curses:noecho))))
    (clear)
    (draw-screen)
    (refresh)))

(defun puca-yes-or-no-p (&optional format &rest arguments)
  (equalp "Yes" (input-window
		 "Yes or No?"
		 (list 
		  (if format
		      (apply #'format nil format arguments)
		      "Yes or No?")))))

(defun delete-files ()
  (when (puca-yes-or-no-p
	 "Are you sure you want to delete these files from storage?~%~{~a ~}"
	 (selected-files))
    (loop :for file :in (selected-files) :do
       (delete-file file))
    (get-list)))

(defparameter *extended-commands*
  '(("delete" delete-files))
  "An alist of extended commands, key is the command name, value is a symbol
for the command-function).")

(defvar *complete-extended-command*
  (completion:list-completion-function (mapcar #'car *extended-commands*))
  "Completion function for extended commands.")

(defun extended-command (p)
  "Extended command"
  (declare (ignore p))
  (move (- *lines* 2) 2)
  (refresh)
  (reset-shell-mode)
  (let ((command (rl:rl
		  :prompt ": "
		  :completion-func *complete-extended-command*
		  :context :puca))
	func)
    ;;(reset-prog-mode)
    (setf func (cadr (assoc command *extended-commands* :test #'equalp)))
    (when (and func (fboundp func))
      (funcall func)))
  (draw-screen)
  (values))

(defun show-errors (p)
  "Show all messages / errors"
  (with-slots (errors) p
    (info-window "All Errors"
		 (or errors
		     '("There are no errors." "So this is" "BLANK")))))

(defun show-extra (p)
  "Show messages / errors"
  (with-slots (goo) p
    (let ((ext (and goo (goo-extra-lines (elt goo (inator-point *puca*))))))
      (info-window "Errors"
		   (or ext
		       '("There are no errors." "So this is" "BLANK"))))))

(defun pick-backend (&optional type)
  ;; Try find what was asked for.
  (when type
    (let ((be (find type *backends*)))
      (when be
	(return-from pick-backend
	  (make-instance (intern (symbol-name be) :puca))))))
  ;; Try to figure it out.
  (let ((result
	 (loop :for backend :in *backends* :do
	    (dbug "Trying backend ~s~%" backend)
	    (when (check-existence backend)
	      (dbug "Picked ~s~%" backend)
	      (return (make-instance (intern (symbol-name backend) :puca)))))))
    ;; (if (not result)
    ;; 	(make-instance 'cvs)
    ;; 	result)))
    result))

(defun add-command (p)
  "Add file"
  (declare (ignore p))
  (do-command #'backend-add (selected-files)))

(defun reset-command (p)
  "Revert file (undo an add)"
  (declare (ignore p))
  (do-command #'backend-reset (selected-files) :confirm t))

(defun diff-command (p)
  "Diff"
  (declare (ignore p))
  (do-command #'backend-diff (selected-files)
	      :relist nil :do-pause nil))

(defun diff-repo-command (p)
  "Diff against commited (-r HEAD)"
  (declare (ignore p))
  (do-command #'backend-diff-repo (selected-files)
	      :relist nil :do-pause nil))

(defun commit-command (p)
  "Commit selected"
  (declare (ignore p))
  (do-command #'backend-commit (selected-files)))

(defun update-command (p)
  "Update selected"
  (declare (ignore p))
  (do-command #'backend-update (selected-files)))

(defun update-all-command (p)
  "Update all"
  (declare (ignore p))
  (do-command #'backend-update-all nil))

(defun push-command (p)
  "Push"
  (declare (ignore p))
  (do-command #'backend-push nil :relist nil))

(defun add-ignore-command (p)
  "Ignore"
  (loop :for f :in (selected-files)
     :do (add-ignore (puca-backend p) f)))

(defun view-file (p)
  "View file"
  (declare (ignore p))
  ;; (pager:pager (selected-files))
  ;;(view:view-things (selected-files))
  ;;(draw-screen)
  (do-literal-command "view ~{\"~a\" ~}" (list (selected-files))
		      :do-pause nil))

(defmethod previous ((p puca))
  "Previous line"
  (with-slots ((point inator::point) top) p
    (decf point)
    (when (< point 0)
      (setf point 0))
    (when (< point top)
      (decf top)
      (draw-screen))))

(defmethod next ((p puca))
  "Next line"
  (with-slots ((point inator::point) maxima top bottom) p
    (incf point)
    (when (>= point maxima)
      (setf point (1- maxima)))
    (when (and (> (- point top) (- bottom 1)) (> bottom 1))
      (incf top)
      (draw-screen))))

(defmethod next-page ((p puca))
  "Next page"
  (with-slots ((point inator::point) maxima top bottom) p
    (setf point (+ point 1 bottom))
    (when (>= point maxima)
      (setf point (1- maxima)))
    (when (>= point (+ top bottom))
      (setf top (max 0 (- point (1- bottom))))
      (draw-screen))))

(defmethod previous-page ((p puca))
  "Previous page"
  (with-slots ((point inator::point) top) p
    (setf point (- point 1 (- curses:*lines* 7)))
    (when (< point 0)
      (setf point 0))
    (when (< point top)
      (setf top point)
      (draw-screen))))

(defmethod move-to-bottom ((p puca))
  "Bottom"
  (with-slots ((point inator::point) maxima top bottom) *puca*
    (setf point (1- maxima))
    (when (> point (+ top bottom))
      (setf top (max 0 (- maxima bottom)))
      (draw-screen))))

(defmethod move-to-top ((p puca))
  "Top"
  (with-slots ((point inator::point) top) p
    (setf point 0)
    (when (> top 0)
      (setf top 0)
      (draw-screen))))

(defun set-mark (p)
  "Set Mark"
  (with-slots ((point inator::point) mark) p
    (setf mark point)
    (message p "Set mark.")))

(defun toggle-region (p)
  "Toggle region"
  (with-slots ((point inator::point) mark) p
    (if mark
      (let ((start (min mark point))
	    (end (max mark point)))
	(loop :for i :from start :to end :do
	   (setf (goo-selected (elt (puca-goo p) i))
		 (not (goo-selected (elt (puca-goo p) i))))
	   (draw-line i)))
      (message p "No mark set."))))

(defun toggle-line (p)
  "Toggle line"
  (with-slots ((point inator::point) goo) p
    (when goo
      (setf (goo-selected (elt goo point))
	    (not (goo-selected (elt goo point))))
      (draw-line point))))

(defun select-all-command (p)
  "Select all"
  (declare (ignore p))
  (select-all)
  (draw-screen))

(defun select-none-command (p)
  "Select none"
  (declare (ignore p))
  (select-none)
  (draw-screen))

(defun relist (p)
  "Re-list"
  (declare (ignore p))
  (clear)
  ;;(refresh)
  (get-list)
  (draw-screen)
  ;(refresh)
  )

(defmethod redraw ((p puca))
  "Re-draw"
  (clear)
  (refresh)
  (draw-screen)
  ;(refresh)
  )

(defun toggle-debug (p)
  (setf (puca-debug p) (not (puca-debug p))))

(defparameter *option-setting*
  #((#\a show-all-tracked)))

(defun set-option-command (p)
  (format-message "Set option: ")
  (let* ((c (tt-get-char))
	 (tog (find c *option-setting* :key #'car))
	 (name (string (second tog)))
	 #| (options (options p)) |#)
    (if tog
	(progn
	  (set-option p name (not (get-option p name)))
	  (message p "~a is ~a" name (get-option p name)))
	(progn
	  (message p "Option not found: ~a" c))))
  (get-list))

(defkeymap *puca-keymap*
  `((#\q		. quit)
    (#\Q		. quit)
    (#\?		. help)
    (#\h		. help)
    (#\a		. add-command)
    (#\r		. reset-command)
    (#\d		. diff-command)
    (#\D		. diff-repo-command)
    (#\c		. commit-command)
    (#\u        	. update-command)
    (#\U        	. update-all-command)
    (#\P        	. push-command)
    (#\i        	. add-ignore-command)
    (#\v        	. view-file)
    (:UP        	. previous)
    (,(code-char 16)	. previous)
    (,(ctrl #\p)       	. previous)
    (:DOWN      	. next)
    (,(code-char 14)    . next)
    (,(ctrl #\n)	. next)
    (:NPAGE		. next-page)
    (,(ctrl #\V)	. next-page)
    (,(ctrl #\F)	. next-page)
    (:PPAGE		. previous-page)
    (,(ctrl #\B)	. previous-page)
    (#\>		. move-to-bottom)
    (#\<		. move-to-top)
    (,(meta-char #\>)	. move-to-bottom)
    (,(meta-char #\<)	. move-to-top)
    (,(ctrl #\@)	. set-mark)
    (,(code-char 0)	. set-mark)
    (#\X		. toggle-region)
    (#\space		. toggle-line)
    (#\x		. toggle-line)
    (#\return		. toggle-line)
    (#\s		. select-all-command)
    (#\S		. select-none-command)
    (#\g		. relist)
    (#\e		. show-extra)
    (#\E		. show-errors)
    (#\:		. extended-command)
    (#\-		. set-option-command)
    ;;(,(ctrl #\L)	. redraw)
    (,(code-char 12)	. redraw)
    (,(meta-char #\=)	. describe-key-briefly)
    (,(ctrl #\t)	. toggle-debug)
    (#\escape		. *puca-escape-keymap*)))

(defparameter *puca-escape-keymap* (build-escape-map *puca-keymap*))

(defun describe-key-briefly (p)
  "Prompt for a key and say what function it invokes."
  (message p "Press a key: ")
  (let* ((key (read-key-sequence p))
   	 (action (key-sequence-binding key *puca-keymap*)))
    (if action
	(message p "~a is bound to ~a" (nice-char key) action)
	(message p "~a is not defined" (nice-char key)))))

;; (defmethod default-action ((p puca))
;;   (message p "Event not bound ~s" (inator-command p)))

(defmethod update-display ((p puca))
  (with-slots ((point inator::point) top first-line bottom debug) p
    (draw-screen)
    (when debug
      (message p "point = ~s top = ~s first-line ~s bottom = ~s"
	       point top first-line bottom))
    (move (+ (- point top) first-line) 2)))

(defmethod start-inator ((p puca))
  (call-next-method)
  (clear)
  (draw-screen)
  (get-list)
  (draw-screen)
  (when (puca-errors p)
    (message p "**MESSAGES**")))

(defun puca (&key backend-type)
  (let ((backend (pick-backend backend-type)))
    (if backend
	(with-terminal (:curses)
	  (with-inator (*puca* 'puca
		        :keymap (list *puca-keymap* *default-inator-keymap*)
		        :backend backend)
	    (event-loop *puca*)))
	(error
  "The current directory is not under a source control system I know about."))))

(defun make-standalone (&optional (name "puca"))
  "FUFKFUFUFUFUFF"
  #+sbcl (sb-ext:save-lisp-and-die name :executable t
				   :toplevel #'puca)
  #+clisp (saveinitmem name :executable t :quiet t :norc t
		       :init-function #'puca:puca)
  #-(or sbcl clisp) (declare (ignore name))
  #-(or sbcl clisp) (missing-implementation 'make-standalone)
  )

(lish:defcommand puca
  (("cvs" boolean :short-arg #\c :help "True to use CVS.")
   ("svn" boolean :short-arg #\s :help "True to use SVN.")
   ("git" boolean :short-arg #\g :help "True to use GIT.")
   ("hg"  boolean :short-arg #\m :help "True to use Mercurial."))
  "Putative Muca interface to your version control software.
Arguments are: -c for CVS, -s for SVN, -g GIT, -m Mercurial."
  (puca :backend-type (cond (cvs :cvs) (svn :svn) (git :git) (hg :hg))))

; Joe would probably like the name but not the software.

;; EOF
