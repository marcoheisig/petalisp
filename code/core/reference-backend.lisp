;;;; © 2016-2020 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(in-package #:petalisp.core)

;;; The purpose of the reference backend is to compute reference solutions
;;; for automated testing. It is totally acceptable that this
;;; implementation is slow or eagerly consing, as long as it is obviously
;;; correct.

(defclass reference-backend (backend)
  ())

(defun make-reference-backend ()
  (make-instance 'reference-backend))

(defvar *table*)

(defmethod compute-immediates ((lazy-arrays list) (backend reference-backend))
  (let ((*table* (make-hash-table :test #'eq)))
    (mapcar #'compute-immediate lazy-arrays)))

(defun compute-immediate (lazy-array)
  (with-accessors ((shape lazy-array-shape)
                   (element-type element-type))
      lazy-array
    (let ((array (make-array (shape-dimensions shape) :element-type element-type)))
      (map-shape
       (lambda (index)
         (setf (apply #'aref array index)
               (lazy-array-value lazy-array index)))
       shape)
      (make-array-immediate array))))

(defgeneric lazy-array-value (lazy-array index))

(defmethod lazy-array-value :around (lazy-array index)
  (alexandria:ensure-gethash
   index
   (alexandria:ensure-gethash
    lazy-array *table*
    (make-hash-table :test #'equal))
   (call-next-method)))

(defmethod lazy-array-value
    ((array-immediate array-immediate) index)
  (apply #'aref (storage array-immediate) index))

(defmethod lazy-array-value
    ((range-immediate range-immediate) index)
  (first index))

(defmethod lazy-array-value
    ((lazy-map lazy-map) index)
  (apply (operator lazy-map)
         (mapcar
          (lambda (input)
            (lazy-array-value input index))
          (inputs lazy-map))))

(defmethod lazy-array-value
    ((lazy-multiple-value-map lazy-multiple-value-map) index)
  (multiple-value-list
   (apply (operator lazy-multiple-value-map)
          (mapcar
           (lambda (input)
             (lazy-array-value input index))
           (inputs lazy-multiple-value-map)))))

(defmethod lazy-array-value
    ((lazy-multiple-value-ref lazy-multiple-value-ref) index)
  (nth
   (value-n lazy-multiple-value-ref)
   (lazy-array-value (input lazy-multiple-value-ref) index)))

(defmethod lazy-array-value
    ((lazy-fuse lazy-fuse) index)
  (lazy-array-value
   (loop for input in (inputs lazy-fuse)
         when (shape-contains (lazy-array-shape input) index)
           return input)
   index))

(defmethod lazy-array-value
    ((lazy-reshape lazy-reshape) index)
  (lazy-array-value
   (input lazy-reshape)
   (transform index (transformation lazy-reshape))))