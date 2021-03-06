;;
;; table.lisp - Generic table data types
;;

;; @@@ This concept needs some refining. Like things called collection,
;; element, length, map, mappable, should rather be in generic collection and
;; sequence modules.
;;
;; The idea is to provide a generic interface to tables, regardless of the
;; storage of the data. We would like to be able to operate on tables in
;; memory, for example stored in sequences like arrays, lists, or hash tables,
;; with the same interface as tables stored in databases, files, networks,
;; etc. Tables of any underlying data representation or storage method should
;; be able to be accessed using the same interface.
;;
;; See table-print for printing tables.
;; See table-viewer for examining tables.

(defpackage :table
  (:documentation "Generic table data types.")
  (:use :cl :collections :dlib)
  (:export
   ;; column struct
   #:column #:make-column #:column-name #:column-type #:column-width
   ;; table
   #:table #:table-columns
   #:mem-table
   #:db-table #:table-name #:table-indexes
   ;; table funcs
   #:table-add-column
   #:table-update-column-width
   #:table-set-column-type
   #:make-table-from
   ))
(in-package :table)

(declaim (optimize (speed 0) (safety 3) (debug 3)
		   (space 0) (compilation-speed 0)))

(defstruct column
  "Description of a table column."
  (name nil)
  (type 'string)
  (width 0))

;; (defclass collection ()
;;   ((data :initarg :data
;; 	 :accessor collection-data
;; 	 :documentation "Collection of data."))
;;   (:documentation "A pile of stuff."))

(defclass table ()
  ((columns :initarg :columns
	    :accessor table-columns
	    :initform nil
	    :documentation "List of column descriptions."))
  (:documentation
   "Table with rows and columns / or a collection of objects with uniform
attributes."))

(defclass mem-table (table container)
  ()
  (:documentation "Table stored in ‘volatile’ memory."))

(defclass db-table (table)
  ((name    :initarg :name
	    :accessor table-name
	    :documentation "Name of the table.")
   (indexes :initarg :indexes
	    :accessor table-indexes
	    :documentation "List of column names that are indexed."))
  (:documentation "A table that is stored in a database."))

(defun table-add-column (table name &key type width)
  "Shorthand for adding a column to a table."
  (let ((col (make-column :name name)))
    (when type  (setf (column-type  col) type))
    (when width (setf (column-width col) width))
    (setf (table-columns table) (nconc (table-columns table) (list col)))))

;; I wish I could specialize on unsigned-byte.

(defgeneric table-update-column-width (table col width)
  (:documentation "Update the column width, growing not shrinking.")
  (:method (table (col string) width)
    (let ((e (find col (table-columns table)
		   :test #'string= :key #'column-name)))
      (when (> width (column-width e))
	(setf (column-width e) width))))
  (:method (table (col integer) width)
    (let ((e (nth col (table-columns table))))
      (when (> width (column-width e))
	(setf (column-width e) width)))))

;; Could be done with defsetf table-column-type
(defgeneric table-set-column-type (table col type)
  (:documentation "Update the column type.")
  (:method (table (col string) type)
    (setf (column-type
	   (find col (table-columns table) :test #'string= :key #'column-name))
	   type))
  (:method (table (col integer) type)
    (setf (column-type (nth col (table-columns table))) type)))

(defgeneric make-table-from (object &key column-names)
  (:documentation "Make a table from another object type."))

(defun uniform-classes (list)
  "Return true if every class in LIST is a subtype of the first element."
  (let ((first-type (class-of (first list))))
    (every (_ (subtypep (type-of _) first-type)) list)))

(defun set-columns-names-from-class (table obj)
  (loop :for slot :in (mop:class-slots (class-of obj)) :do
     (table-add-column table
		       (format nil "~:(~a~)" (mop:slot-definition-name slot))
		       :type (mop:slot-definition-type slot))))

(defun list-of-classes-p (obj)
  (let ((first-obj (first obj)))
    (and first-obj
	 (or (typep first-obj 'structure-object)
	     (typep first-obj 'standard-object))
	 (uniform-classes obj))))

(defmethod omap (function (table mem-table))
  (if (keyed-collection-p (container-data table))
      (omapk function (container-data table))
      (omap function (container-data table))))

(defmethod make-table-from ((object list) &key column-names)
  "Make a table from an alist."
  (let ((tt (make-instance 'mem-table :data object))
	(first-obj (first object)))
    (if column-names
	(loop :for c :in column-names :do
	   (table-add-column tt c))
	(when first-obj
	  (if (list-of-classes-p object)
	      (set-columns-names-from-class tt first-obj)
	      (loop :for i :from 0 :to (length first-obj)
		 :do (table-add-column tt (format nil "Column~d" i))))))
    tt))

(defmethod make-table-from ((object hash-table)
			    &key (column-names '("Key" "Value")))
  "Make a table from a hash table."
  (when (> (length column-names) 2)
    (error "Hash tables can only have 2 column names."))
  (let ((tt (make-instance 'mem-table :data object)))
    (loop :for c :in column-names :do
       (table-add-column tt c))
    tt))

(defmethod make-table-from ((object array) &key column-names)
  "Make a table from a hash table."
  (when (not (equal (array-dimensions object) '(2)))
    (error "Don't know how to make a table from an array of other than ~
2 dimensions."))
  (let ((tt (make-instance 'mem-table :data object)))
    (if column-names
	(loop :for c :in column-names :do
	   (table-add-column tt c))
	(loop :for i :from 0 :to (array-dimension object 0)
	   :do (table-add-column tt (format nil "Column~d" i))))
    tt))

(defmethod make-table-from ((object structure-object)
			    &key (column-names '("Slot" "Value")))
  "Make a table from an structure."
  (when (> (length column-names) 2)
    (error "Structures can only have 2 column names."))
  (let ((tt (make-instance 'mem-table :data object)))
    (loop :for c :in column-names :do
       (table-add-column tt c))
    tt))

;; EOF
