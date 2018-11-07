;;;; © 2016-2018 Marco Heisig - licensed under AGPLv3, see the file COPYING     -*- coding: utf-8 -*-

(in-package :petalisp-development)

(defgenerator shape (&key (rank 3) (max-size 30) (max-extent 100) intersecting)
  (assert (or (not intersecting)
              (= rank (rank intersecting))))
  (let ((range-generators
          (if intersecting
              (mapcar (lambda (range)
                        (make-range-generator
                         :max-size max-size
                         :max-extent max-extent
                         :intersecting range))
                      (ranges intersecting))
              (make-list rank :initial-element
                         (make-range-generator
                          :max-size max-size
                          :max-extent max-extent)))))
    (lambda ()
      (shape-from-ranges
       (mapcar #'funcall range-generators)))))