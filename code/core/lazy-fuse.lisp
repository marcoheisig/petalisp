;;;; © 2016-2021 Marco Heisig         - license: GNU AGPLv3 -*- coding: utf-8 -*-

(in-package #:petalisp.core)

(defun lazy-fuse (array &rest more-arrays)
  (let ((first (lazy-array array))
        (rest (mapcar #'lazy-array more-arrays)))
    ;; No need to fuse when only a single array is supplied.
    (when (null rest)
      (return-from lazy-fuse first))
    (let ((rank (lazy-array-rank first))
          (lazy-arrays (list* first rest)))
      ;; Check that all lazy arrays have the same rank.
      (dolist (lazy-array rest)
        (unless (= (lazy-array-rank lazy-array) rank)
          (error
           "~@<Can only fuse arrays with ~
               equal rank. The arrays ~A and ~A ~
               violate this requirement.~:@>"
           first lazy-array)))
      ;; Check that all lazy arrays have a pairwise disjoint shape.
      (alexandria:map-combinations
       (lambda (lazy-arrays)
         (destructuring-bind (lazy-array-1 lazy-array-2) lazy-arrays
           (when (shape-intersectionp
                  (lazy-array-shape lazy-array-1)
                  (lazy-array-shape lazy-array-2))
             (error "~@<Can only fuse disjoint shapes, ~
                        but the arrays ~S and the shape ~S have the ~
                        common subshape ~S.~:@>"
                    lazy-array-1
                    lazy-array-2
                    (shape-intersection
                     (lazy-array-shape lazy-array-1)
                     (lazy-array-shape lazy-array-2))))))
       lazy-arrays :length 2 :copy nil)
      (let ((shape (apply #'fuse-shapes (mapcar #'lazy-array-shape lazy-arrays)))
            (ntype (reduce #'petalisp.type-inference:ntype-union
                           lazy-arrays
                           :key #'lazy-array-ntype)))
        ;; Check that the predicted result shape is valid.
        (unless (= (reduce #'+ lazy-arrays :key #'lazy-array-size)
                   (shape-size shape))
          (error "~@<Cannot fuse the arrays ~
                     ~{~#[~;and ~S~;~S ~:;~S, ~]~}.~:@>"
                 lazy-arrays))
        ;; If the content of the fusion is predicted to be a
        ;; constant, we replace the entire fusion by a reference to
        ;; that constant.  Otherwise, we create a regular lazy-fuse
        ;; object.
        (if (petalisp.type-inference:eql-ntype-p ntype)
            (lazy-ref
             (lazy-array-from-scalar ntype)
             shape
             (make-transformation
              :input-rank (shape-rank shape)
              :output-rank 0))
            (make-lazy-array
             :delayed-action (make-delayed-fuse :inputs lazy-arrays)
             :shape shape
             :ntype ntype
             :depth (1+ (maxdepth lazy-arrays))))))))


