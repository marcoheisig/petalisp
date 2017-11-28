;;; © 2016-2017 Marco Heisig - licensed under AGPLv3, see the file COPYING

(in-package :petalisp)

;;; This is probably the most complicated part of Petalisp and deserves
;;; some explanation...
;;;
;;; The goal is to translate a data flow graph into a graph of executable
;;; parts, called kernels. The data flow nodes form a DAG (directed acyclic
;;; graph). The data flow graph is fully determined by a set of graph roots
;;; --- typically the nodes passed to SCHEDULE.
;;;
;;; The resulting graph consists only of immediate values. Each immediate
;;; comes with a set of kernels. Each kernel describes how the values of a
;;; subspace of the index space of its target immediate can be
;;; computed. Furthermore each kernel tracks the set of its sources,
;;; i.e. other immediates that are referenced during their
;;; evaluation. Since the resulting immediate graph is used to decide a
;;; scheduling and allocation strategy, it is important that its kernels
;;; are easy to analyze, yet expressive enough to denote fast programs.
;;;
;;; The high level steps of the kernelization algorithm are as follows:
;;;
;;; 1. Determine the set of critical nodes, i.e. nodes that are referenced
;;;    more than once, are graph roots, are the input of a broadcasting
;;;    reference or have multiple inputs containing reductions. Each
;;;    critical node will later be the target of one or more kernels.
;;;
;;; 2. By construction, the nodes starting from one critical node, up to
;;;    and including the next critical nodes, form a tree of application,
;;;    reduction, reference and fusion nodes. To eliminate fusion nodes in
;;;    the later stages, determine a set of index spaces such that their
;;;    union is the index space of the current critical node, but such that
;;;    each index space lies uniquely within a particular input of each
;;;    fusion node.
;;;
;;; 3. Each particular index space from 2. denotes a fusion-free
;;;    sub-problem on the way to computing the current critical
;;;    node. Determine the iteration space of this sub-problem and the set
;;;    of referenced immediates.
;;;
;;; 4. Given the iteration space and the set of referenced immediates,
;;;    translate the tree into an explicit blueprint. The blueprint
;;;    describes how the given inputs are used to compute the target. It is
;;;    important that this blueprint is normalized, such that as many
;;;    computationally similar operations as possible have the same
;;;    blueprint. To achieve this, blueprints do not use index space
;;;    coordinates, but the storage coordinates of the source and target
;;;    immediates.
;;;
;;; 5. Use each blueprint, together with the set of sources, the target and
;;;    the iteration space, to create one kernel and associates its target
;;;    node. Once every critical node and index space thereof has been
;;;    processed, the algorithm terminates.

(defun kernelize (graph-roots)
  (kernelize-subtrees
   (lambda (target root leaf-function)
     (setf (kernels target)
           (map 'vector
                (lambda (iteration-space)
                  (kernelize-subtree-fragment target root leaf-function iteration-space))
                (subtree-iteration-spaces root leaf-function))))
   graph-roots))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; 1. Critical Nodes
;;;
;;; Critical nodes are the nodes that will later be allocated in main
;;; memory. All other nodes will only appear implicit as the part of a
;;; blueprint. The naive approach --- to treat each node as a critical node
;;; --- would lead to an insane number of allocations and memory
;;; traffic. Instead, the goal is to find a minimal set of critical nodes,
;;; while preserving some crucial properties.
;;;
;;; The criteria to determine critical nodes are:
;;;
;;; - An immediate is a critical node. This implies that all leaves of the
;;;   data flow graph are critical nodes. However such a critical node is
;;;   cheap, because it has already been allocated.
;;;
;;; - Each graph root is a critical node. Since the whole purpose of
;;;   Petalisp is to compute the values of the graph roots, allocating them
;;;   is absolutely mandatory.
;;;
;;; - A node that appears as an input of multiple other nodes of the same
;;;   graph, is a critical node. As a result, all non-critical nodes have
;;;   only a single user and --- as a consequence --- appear inside a tree,
;;;   whose root and leaves are critical nodes.
;;;
;;;   This tree property is a crucial prerequisite for blueprint creation,
;;;   scheduling and code generation.
;;;
;;; - The input of a broadcasting reference is a critical node. This
;;;   criterion is hardly obvious, but prevents a particular edge-case. If
;;;   broadcasting nodes would be allowed inside kernels, one could
;;;   construct a sequence of alternating reductions and broadcasts and
;;;   produce arbitrarily large kernels. On the other hand, the input of a
;;;   broadcasting reference is usually orders of magnitude smaller than
;;;   the output, so allocating it explicitly is hardly severe.
;;;
;;; - A node is a critical node, if it has more than one input that
;;;   contains --- possibly further upward, but below the next critical
;;;   node --- a reduction node. This rather arcane criterion achieves,
;;;   that the iteration space of each kernel is an n-dimensional strided
;;;   cube, simplifying later analysis considerably. Introducing these
;;;   critical nodes is not terribly expensive, since the target of some
;;;   reductions is usually orders of magnitude smaller than their inputs.
;;;
;;; The first step in the algorithm is the creation of a *USE-TABLE*, a
;;; hash table mapping each graph node to its successors. It would seem
;;; more efficient to track the users of each node at DAG construction time
;;; and avoid this indirection, but we are only interested in those users
;;; that are reachable via the given graph roots. This way the system
;;; implicitly eliminates dead code.
;;;
;;; Once the *USE-TABLE* is populated, the graph is traversed a second
;;; time, to generate a kernelized copy of it. A node with more than one
;;; user triggers the creation of a new intermediate result and one or more
;;; kernels. The hash table *KERNEL-TABLE* memoizes repeated calls to
;;; KERNELIZE-NODE.

(defun kernelize-subtrees (subtree-fn graph-roots)
  "Invoke SUBTREE-FN on each subtree in the graph spanned by the supplied
   GRAPH-ROOTS. For each subtree, SUBTREE-FN receives the following
   arguments:
   1. The target immediate
   2. The root of the tree in the data flow graph
   3. A function, mapping each tree leaf to its corresponding immediate

   Return the sequence of immediates corresponding to the GRAPH-ROOTS."
  )

(defun kernelize-graph (graph-roots)
  "Convert the data flow graph defined by GRAPH-ROOTS to an executable
   specification. Return a sequence of immediate values, each with a
   (possibly empty) set of kernels and dependencies."
  (let ((table (make-hash-table :test #'eq))
        (graph-roots (ensure-sequence graph-roots)))
    ;; step 1 - define a mapping from nodes to immediate values
    (labels ((register (node)
               (setf (gethash node table)
                     (corresponding-immediate node))
               (values))
             (register-root (node)
               (unless (immediate? node)
                 (register node)))
             (traverse (node)
               (if (or (< (refcount node) 2)
                       (immediate? node))
                   (traverse-inputs node)
                   (multiple-value-bind (value recurring)
                       (gethash node table)
                     (cond ((not recurring)
                            (setf (gethash node table) nil)
                            (traverse-inputs node))
                           ((and recurring (not value))
                            (register node))))))
             (traverse-inputs (node)
               (dolist (input (inputs node))
                 (traverse input))))
      ;; explicitly register all non-immediate graph roots, because they
      ;; are tree roots regardless of their type or refcount
      (map nil #'register-root graph-roots)
      ;; now process the entire graph recursively
      (map nil #'traverse graph-roots))
    ;; step 2 - derive the kernels of each immediate
    (labels
        ((kernelize-hash-table-entry (tree-root target)
           ;; TABLE has an entry for all nodes that are potential kernel
           ;; targets (i.e. their refcount is bigger than 1). But only
           ;; those nodes with a non-NIL target actually need to be
           ;; kernelized, the rest is skipped
           (when target
             (flet ((leaf-function (node)
                      (cond
                        ;; the root is never a leaf
                        ((eq node tree-root) nil)
                        ;; all immediates are leaves
                        ((immediate? node) node)
                        ;; skip the table lookup when the refcount is small
                        ((< (refcount node) 2) nil)
                        ;; otherwise check the table
                        (t (values (gethash node table))))))
               (declare (dynamic-extent #'leaf-function))
               (let ((kernels (subgraph-kernels target tree-root #'leaf-function)))
                 (setf (kernels target) kernels))))))
      (maphash #'kernelize-hash-table-entry table))
    (map 'vector
         (lambda (node)
           (if (immediate? node)
               node
               (gethash node table)))
         graph-roots)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; 2. Fusion Free Index Spaces

(defun subtree-iteration-spaces (root leaf-function)
  "Return a partitioning of the index space of ROOT, whose elements
   describe the maximal fusion-free paths through the subgraph from ROOT to
   some leaves, as determined by the supplied LEAF-FUNCTION."
  (labels
      ((iteration-spaces (node relevant-space transformation)
         (cond
           ((funcall leaf-function node) nil)
           ((fusion? node)
            (iterate
              (for input in (inputs node))
              (when-let ((subspace (intersection relevant-space (index-space input))))
                (nconcing (or (iteration-spaces input subspace transformation)
                              (list (funcall (inverse transformation) subspace)))))))
           ((reference? node)
            (when-let ((subspace (intersection relevant-space (index-space node))))
              (iteration-spaces (input node) subspace
                                (composition (transformation node) transformation))))
           ((reduction? node)
            (iteration-spaces (input node) relevant-space transformation))
           ((application? node)
            (let* ((number-of-fusing-subtrees 0)
                   (index-spaces
                     (iterate
                       (for input in (inputs node))
                       (when-let ((spaces (iteration-spaces input relevant-space transformation)))
                         (incf number-of-fusing-subtrees)
                         (nconcing spaces)))))
              (if (> number-of-fusing-subtrees 1)
                  (subdivision index-spaces)
                  index-spaces))))))
    (or
     (iteration-spaces root (index-space root) (make-identity-transformation (dimension root)))
     (list (index-space root)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; 3. iteration space and sources

(defun subtree-ranges-and-sources (root leaf-function iteration-space initial-ranges)
  "Return as multiple values a vector of the ranges and a vector of the
  sources reachable from ROOT, as determined by the supplied
  LEAF-FUNCTION."
  (let ((sources (fvector)))
    (labels
        ((traverse (node relevant-space)
           (when relevant-space
             (if-let ((leaf (funcall leaf-function node)))
               (fvector-pushnew leaf sources :test #'eq)
               (etypecase node
                 (application
                  (map nil
                       (λ input (traverse input relevant-space))
                       (inputs node)))
                 (reduction
                  (traverse (input node) relevant-space))
                 (fusion
                  (map nil
                       (λ input (traverse input (intersection (index-space input) relevant-space)))
                       (inputs node)))
                 (reference
                  (traverse (input node)
                            (intersection
                             (index-space (input node))
                             (funcall (transformation node) relevant-space)))))))))
      (traverse root iteration-space))
    (values initial-ranges sources)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; 4. Blueprint Creation
;;;
;;; The blueprint of a kernel is used to construct some
;;; performance-critical function and as a key to search whether such a
;;; function has already been generated and compiled. The latter case is
;;; expected to be far more frequent, so the primary purpose of a blueprint
;;; is to select an existing function as fast as possible and without
;;; consing.
;;;
;;; To achieve this, each blueprint is built from uconses. Furthermore, the
;;; blueprint grammar has been chosen to maximize structural sharing and to
;;; avoid unnecessary uconses.

(deftype blueprint () 'ucons)

(define-ustruct %blueprint
  (range-info ulist)
  (storage-info ulist)
  (expression ulist))

(define-ustruct %reference
  (storage non-negative-fixnum)
  &rest indices)

(define-ustruct %store
  (reference ulist)
  (expression ulist))

(define-ustruct %call
  operator
  &rest expressions)

(define-ustruct %reduce
  (range non-negative-fixnum)
  operator
  (expression ulist))

(define-ustruct %accumulate
  (range non-negative-fixnum)
  operator
  initial-value
  (expression ulist))

(define-ustruct %for
  (range non-negative-fixnum)
  (expression ulist))

(defgeneric %indices (transformation)
  (:method ((transformation identity-transformation))
    (let ((dimension (input-dimension transformation)))
      (let (result)
        (iterate
          (for index from (1- dimension) downto 0)
          (setf result (ulist* (ulist index 1 0) result)))
        result)))
  (:method ((transformation affine-transformation))
    (let (result)
      (iterate
        (for column in-vector (spm-column-indices (linear-operator transformation)) downto 0)
        (for value in-vector (spm-values (linear-operator transformation)) downto 0)
        (for offset in-vector (translation-vector transformation) downto 0)
        (setf result (ulist* (ulist column value offset) result)))
      result)))

(defun blueprint-range-information (ranges)
  (flet ((range-info (range)
           (let ((lb (log (size range) 2)))
             (ulist (expt (floor lb) 2)
                    (expt (ceiling lb) 2)
                    (range-step range)))))
    (map-ulist #'range-info ranges)))

(defun blueprint-storage-information (target sources)
  (flet ((storage-info (immediate)
           (element-type immediate)))
    (ulist* (storage-info target)
            (map-ulist #'storage-info sources))))

(defun subtree-fragment-blueprint (target root leaf-function iteration-space sources)
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; 5. Kernel Creation
;;;
;;; The goal is to determine a sequence of kernels that compute the
;;; elements of a target immediate according to a subgraph specified by a
;;; root and a leaf function. The latter is a function returning the
;;; corresponding immediate of each leaf node and NIL for all other nodes.
;;;
;;; Most importantly, it is necessary to generate, for each kernel, a
;;; blueprint that describes how it should be computed. It is crucial that
;;; this blueprint is normalized, i.e. similar operations should lead to
;;; identical blueprints. This makes it possible to efficiently cache and
;;; compile these blueprints. In particular, a blueprint must not depend on
;;; the absolute index space of any of the involved immediates and instead
;;; work directly on their storage.
;;;
;;; Another normalization is obtained by observing that, since the
;;; subgraphs are now much smaller than the original data flow graph, it is
;;; possible to move all references upwards until they merge into a single
;;; reference per leaf. As a result, transformations concern only the
;;; references to the sources of each kernel.
;;;
;;; The final and perhaps most controversial normalization is the
;;; elimination of all fusion nodes. Each fusion node can be eliminated by
;;; instead generating multiple kernels. The iteration space of each of
;;; these kernels is chosen such that only a single input of each fusion is
;;; utilized, effectively turning it into a reference node. The downside of
;;; this normalization step is that for subgraphs with multiple fusion
;;; nodes, the number of generated kernels grows exponentially. Time will
;;; tell whether this case occurs in practical applications.

(defun kernelize-subtree-fragment (target root leaf-function iteration-space)
  "Return the kernel that computes the ITERATION-SPACE of TARGET, according
   to the data flow graph prescribed by ROOT and LEAF-FUNCTION."
  (let ((dimension (dimension root)))
    (multiple-value-bind (ranges sources)
        (subgraph-ranges-and-sources
         root leaf-function iteration-space
         (ranges (funcall (to-storage target) iteration-space)))
      (make-instance 'kernel
        :target target
        :ranges ranges
        :sources sources
        :blueprint
        (%blueprint
         (blueprint-range-information ranges)
         (blueprint-storage-information target sources)
         (funcall
          (named-lambda build-blueprint (range-id)
            (if (= range-id dimension)
                (%store (%reference 0 (%indices (make-identity-transformation dimension)))
                        (subgraph-blueprint-body
                         root leaf-function sources iteration-space (from-storage target)))
                (%for range-id (build-blueprint (1+ range-id)))))
          0))))))

(defun subgraph-blueprint-body (node leaf-function sources iteration-space transformation)
  (labels ((traverse (node relevant-space transformation)
             (if-let ((immediate (funcall leaf-function node)))
               (%reference (1+ (position immediate sources))
                           (%indices (composition (to-storage immediate) transformation)))
               (etypecase node
                 (reference
                  (traverse
                   (input node)
                   relevant-space
                   (composition (transformation node) transformation)))
                 (fusion
                  (traverse
                   (find-if (λ input (subspace? relevant-space (index-space input)))
                            (inputs node))
                   relevant-space
                   transformation))
                 (application
                  (%call (operator node)
                         (map-ulist (λ input (traverse input relevant-space transformation))
                                    (inputs node))))))))
    (traverse node iteration-space transformation)))
