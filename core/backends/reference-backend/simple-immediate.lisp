;;;; © 2016-2018 Marco Heisig - licensed under AGPLv3, see the file COPYING     -*- coding: utf-8 -*-

(in-package :petalisp-reference-backend)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Classes

;;; A simple immediate is implemented as an EQUAL hash table that maps each
;;; index tuple to the corresponding value.
(defclass simple-immediate (immediate)
  ((%table :initarg :table :reader table)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Functions

(defun make-simple-immediate (shape value-fn)
  (let ((table (make-hash-table :test #'equal)))
    (loop for index in (set-elements shape) do
      (setf (gethash index table)
            (funcall value-fn index)))
    (make-instance 'simple-immediate
      :shape shape
      :table table)))

(defun iref (simple-immediate index)
  (multiple-value-bind (value present-p)
      (gethash index (table simple-immediate))
    (unless present-p
      (error "Invalid index ~S for the strided array ~S."
             index simple-immediate))
    value))

(defmethod lisp-datum-from-immediate ((simple-immediate simple-immediate))
  (with-accessors ((shape shape) (table table)) simple-immediate
    (if (zerop (rank shape))
        (gethash '() table)
        (let ((array (make-array (mapcar #'set-size (ranges shape)))))
          (loop for index in (set-elements shape) do
            (setf (apply #'aref array index)
                  (gethash index table)))
          array))))

(defmethod overwrite-instance ((instance strided-array) (replacement simple-immediate))
  (change-class instance 'simple-immediate
    :table (table replacement)))