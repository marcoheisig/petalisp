;;;; © 2016-2018 Marco Heisig - licensed under AGPLv3, see the file COPYING     -*- coding: utf-8 -*-

(in-package :petalisp)

(defclass backend () ()
  (:documentation
   "A backend is an abstraction over a set of hardware
resources. All handling of kernels --- such as performance analysis,
compilation and execution --- is done in the context of a particular
backend."))

(defgeneric vm/schedule (backend targets recipes)
  (:documentation
   "Instruct BACKEND to compute all given GRAPH-ROOTS
asynchronously. Return an object of type REQUEST that can be used to block
until the task is complete."))