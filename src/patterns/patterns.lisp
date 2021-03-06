(in-package :cl-patterns)

;; NOTES:
;; FIX: make fork method, which copies the pstream and continues it from the same position in the copy and the original.
;; FIX: remove :remaining key and just use :pfin instead?
;; FIX: make a "peek" function to get future values of a pstream without affecting `next'.
;; FIX: take each pattern's name out of its docstring, and make sure the first sentence in each docstring is a good concise description of the functionality.

;;; pattern glue

(defun make-default-event ()
  (or *event* (event)))

(defun set-parents (pattern)
  "Loop through PATTERN's slots and set the \"parent\" slot of any patterns to this pattern."
  (labels ((set-parent (list parent)
             "Recurse through LIST, setting the parent of any pattern found to PARENT."
             (cond ((typep list 'list)
                    (mapc (lambda (x) (set-parent x parent)) list))
                   ((typep list 'pattern)
                    (setf (slot-value list 'parent) parent)))))
    (loop :for slot :in (mapcar #'closer-mop:slot-definition-name (closer-mop:class-slots (class-of pattern)))
       :do
       (when (slot-boundp pattern slot)
         (set-parent (slot-value pattern slot) pattern)))
    pattern))

(defmacro defpattern (name superclasses slots &optional documentation creation-function) ;; FIX: should warn if `set-parents' is not called in the creation-function.
  "Define a pattern. This macro automatically generates the pattern's class, its pstream class, and the function to create an instance of the pattern, and makes them external in the cl-patterns package.

NAME is the name of the pattern. Typically a word or two that describes its function, prefixed with p.

SUPERCLASSES is a list of superclasses of the pattern. Most patterns just subclass the 'pattern' class.

SLOTS is a list of slots that the pattern and pstreams derived from it have. Each slot can either be just a symbol, or a slot definition a la `defclass'. You can provide a default for the slot with the :default key, and you can set a slot as a state slot (which only appears in the pattern's pstream class) by setting the :state key to t.

DOCUMENTATION is a docstring describing the pattern. We recommend providing at least one example, and a \"See also\" section to refer to similar pattern classes.

CREATION-FUNCTION is an expression which will be inserted into the pattern creation function prior to initialization of the instance. Typically you'd use this for inserting `assert' statements, for example."
  (let* ((superclasses (or superclasses (list 'pattern)))
         (slots (mapcar #'alexandria:ensure-list slots))
         (name-pstream (intern (concatenate 'string (symbol-name name) "-PSTREAM") 'cl-patterns))
         (super-pstream (if (eq 'pattern (car superclasses))
                            'pstream
                            (intern (concatenate 'string (symbol-name (car superclasses)) "-PSTREAM") 'cl-patterns))))
    (labels ((desugar-slot (slot)
               "Convert a slot into something appropriate for defclass to handle."
               (let ((name (car slot))
                     (rest (cdr slot)))
                 (setf rest (alexandria:remove-from-plist rest :default))
                 (setf rest (alexandria:remove-from-plist rest :state))
                 (when (not (position :initarg (keys rest)))
                   (alexandria:appendf rest (list :initarg (alexandria:make-keyword name))))
                 (append (list name) rest)))
             (optional-slot-p (slot)
               "Whether the slot is optional or not. A slot is optional if a default is provided."
               (position :default (keys (cdr slot))))
             (state-slot-p (slot)
               "Whether the slot is a state slot or not. State slots will not be included as arguments to the pattern creation function."
               (position :state (keys (cdr slot))))
             (function-lambda-list (slots)
               "Generate the lambda list for the pattern's creation function."
               (let ((optional-used nil))
                 (loop :for slot :in slots
                    :append (when (not (state-slot-p slot))
                              (if (optional-slot-p slot)
                                  (prog1
                                      (append (if (not optional-used)
                                                  (list '&optional)
                                                  (list))
                                              (list (list (car slot) (getf (cdr slot) :default))))
                                    (setf optional-used t))
                                  (list (car slot)))))))
             (make-defun (pre-init)
               `(defun ,name ,(function-lambda-list slots)
                  ,documentation
                  ,@(when pre-init (list pre-init))
                  (set-parents
                   (make-instance ',name
                                  ,@(mapcan (lambda (i) (list (alexandria:make-keyword (car i)) (car i)))
                                            (remove-if #'state-slot-p slots))))))
             (add-doc-to-defun (sexp)
               (if (and (listp sexp)
                        (position (car sexp) (list 'defun 'defmacro))
                        (not (typep (nth 3 sexp) 'string)))
                   (append (subseq sexp 0 3) (list documentation) (subseq sexp 3))
                   sexp)))
      `(progn
         (defclass ,name ,superclasses
           ,(mapcar #'desugar-slot (remove-if #'state-slot-p slots))
           ,@(when documentation
               `((:documentation ,documentation))))
         (defclass ,name-pstream (,name ,super-pstream)
           ,(mapcar #'desugar-slot (remove-if-not #'state-slot-p slots))
           (:documentation ,(format nil "pstream class for ~a." name)))
         ,(let* ((gen-func-p (or (null creation-function)
                                 (and (listp creation-function)
                                      (position (car creation-function) (list 'assert)))))
                 (pre-init (when gen-func-p
                             creation-function)))
            (if gen-func-p
                (make-defun pre-init)
                (add-doc-to-defun creation-function)))
         (export '(,name ,name-pstream))))))

(defparameter *max-pattern-yield-length* 64
  "The maximum amount of events or values that will be used by patterns like pshift, etc, in order to prevent hangs caused by infinite-length patterns.")

;;; pattern

(defclass pattern ()
  ((remaining :initarg :remaining :initform :inf)
   (quant :initarg :quant :initform (list 1) :reader quant) ;; quant, phase, timing-offset
   (parent :initarg :parent :initform nil)
   (loop-p :initarg :loop-p :initform nil :accessor loop-p)
   (cleanup-functions :initarg :cleanup-functions :initform (list)))
  (:documentation "Abstract pattern superclass."))

(defun all-patterns ()
  (mapcar #'class-name (closer-mop:class-direct-subclasses (find-class 'pattern))))

(defmethod (setf quant) (value (pattern pattern))
  (setf (slot-value pattern 'quant) (alexandria:ensure-list value)))

(defgeneric next (pattern)
  (:documentation "Returns the next value of a pattern stream, function, or other object, advancing the pattern stream forward in the process.

See also: `next-n', `next-upto-n'")
  (:method-combination pattern))

(defmethod next ((pattern t))
  pattern)

(defmethod next ((pattern pattern))
  (next (as-pstream pattern)))

(defmethod next ((pattern function))
  (funcall pattern))

(defun next-n (pattern n)
  "Returns the next N results of a pattern stream, function, or other object, advancing the pattern stream forward N times in the process.

See also: `next', `next-upto-n'"
  (let ((pstream (as-pstream pattern)))
    (loop
       :for i :from 0 :below n
       :collect (next pstream))))

(defun next-upto-n (pattern &optional (n *max-pattern-yield-length*))
  "Return a list of up to N results from PATTERN. If PATTERN ends after less than N values, then all of its results will be returned.

See also: `next', `next-upto-n'"
  (let ((pstream (as-pstream pattern)))
    (loop
       :for number :from 0 :upto n
       :for val = (next pstream)
       :while (and (not (null val))
                   (< number n))
       :append (list val))))

;;; pstream

(defclass pstream (pattern)
  ((number :initform 0)
   (pattern-stack :initform (list))
   (history :initarg :history :initform (list)))
  (:documentation "Pattern stream class."))

(defun value-remaining-p (value)
  "Return t if VALUE represents that a pstream has outputs \"remaining\"; i.e. VALUE is a symbol (i.e. :inf), or a number greater than 0."
  (typecase value
    (null nil)
    (symbol t)
    (number (plusp value))
    (otherwise nil)))

(defun remainingp (pattern &optional (repeats-key 'repeats) (remaining-key 'current-repeats-remaining))
  "Return true if PATTERN's REMAINING-KEY slot value represents outputs \"remaining\" (see `value-remaining-p'). If PATTERN's REMAINING-KEY slot is unbound or 0, and REPEATS-KEY is not nil, then it is automatically set to the `next' of PATTERN's REPEATS-KEY slot. Then if that new value is 0 or nil, remainingp returns nil. Otherwise, :reset is returned as a generalized true value and to indicate that `next' was called on PATTERN's REPEATS-KEY slot."
  (labels ((set-next ()
             (setf (slot-value pattern remaining-key) (next (slot-value pattern repeats-key)))
             (when (value-remaining-p (slot-value pattern remaining-key))
               :reset)))
    (if (not (slot-boundp pattern remaining-key))
        (set-next)
        (progn
          (typecase (slot-value pattern remaining-key)
            (null nil)
            (symbol t) ;; :inf or the like
            (number (if (plusp (slot-value pattern remaining-key))
                        t
                        (set-next))) ;; if it's already set to 0, it was decf'd to 0 in the pattern, so we get the next one. if the next is 0, THEN we return nil.
            (otherwise nil))))))

(defun decf-remaining (pattern &optional (key 'remaining))
  "Decrease PATTERN's KEY value."
  (when (numberp (slot-value pattern key))
    (decf (slot-value pattern key))))

(defmethod next :around ((pattern pstream))
  (labels ((pattern-embed (pattern embed)
             (assert (typep pattern 'pstream) (pattern))
             (push (as-pstream embed) (slot-value pattern 'pattern-stack)))
           (get-value-from-stack (pattern)
             (if (null (slot-value pattern 'pattern-stack))
                 (prog1
                     (get-value pattern)
                   (incf (slot-value pattern 'number))
                   (decf-remaining pattern))
                 (let* ((popped (pop (slot-value pattern 'pattern-stack)))
                        (nv (next popped)))
                   (if (null nv)
                       (get-value-from-stack pattern)
                       (progn
                         (push popped (slot-value pattern 'pattern-stack))
                         nv)))))
           (get-value (pattern)
             (let ((res (call-next-method)))
               (typecase res
                 (pattern
                  (pattern-embed pattern res)
                  (get-value-from-stack pattern))
                 (t res)))))
    (let ((result (when (or (not (slot-boundp pattern 'remaining))
                            (value-remaining-p (slot-value pattern 'remaining)))
                    (get-value-from-stack pattern))))
      (alexandria:appendf (slot-value pattern 'history) (list result))
      result)))

(defgeneric as-pstream (thing)
  (:documentation "Return THING as a pstream object.

See also: `pattern-as-pstream'"))

(defun pattern-as-pstream (thing)
  "Like `as-pstream', but only converts THING to a pstream if it is a pattern."
  (if (typep thing 'pattern)
      (as-pstream thing)
      thing))

(defclass t-pstream (pstream)
  ((value :initarg :value :initform nil))
  (:documentation "Pattern stream object that returns itself only once."))

(defmethod as-pstream ((pattern t))
  (make-instance 't-pstream
                 :value pattern))

(defmethod next ((pattern t-pstream))
  (when (= 0 (slot-value pattern 'number))
    (let ((value (slot-value pattern 'value)))
      (if (functionp value)
          (funcall value)
          value))))

(defmethod as-pstream ((pstream pstream))
  pstream)

(defmethod as-pstream ((pattern pattern))
  (let ((slots (remove-if (lambda (x) (eq x 'parent)) (mapcar #'closer-mop:slot-definition-name (closer-mop:class-slots (class-of pattern))))))
    (apply #'make-instance
           (intern (concatenate 'string (symbol-name (class-name (class-of pattern))) "-PSTREAM") 'cl-patterns)
           (loop :for slot :in slots
              :collect (alexandria:make-keyword slot)
              :collect (as-pstream (slot-value pattern slot))))))

(defmethod as-pstream :around ((pattern pattern))
  (let ((pstream (call-next-method)))
    (setf (slot-value pstream 'remaining) (slot-value pattern 'remaining))
    (set-parents pstream)
    pstream))

(defmethod as-pstream :around ((pstream pstream))
  pstream)

(define-condition pstream-out-of-range () ((index :initarg :index :reader pstream-nth-index))
  (:report (lambda (condition stream)
             (format stream "The pstream has insufficient history to index to element ~d." (pstream-nth-index condition)))))

(defun pstream-nth (n pstream)
  "Return the Nth element from PSTREAM's history. Does not automatically advance PSTREAM if N is out of range.

Example: (let ((pstream (as-pstream (pseq '(1 2 3)))))
(next-upto-n pstream)
(pstream-nth 2 pstream)) ;=> 3

See also: `pstream-nth-future', `phistory'"
  (assert (integerp n) (n))
  (unless (typep pstream 'pstream)
    (return-from pstream-nth (pstream-nth n (as-pstream pstream))))
  (with-slots (history) pstream
    (if (>= n (length history))
              (error 'pstream-out-of-range :index n)
              (nth-wrap n history))))

(defun pstream-nth-future (n pstream)
  "Return the Nth element from PSTREAM's history, automatically advancing PSTREAM as necessary if the Nth element has not yet occurred.

When N is negative, NILs at the end of PSTREAM's history are not included in indexing, but NIL may be returned if the negative index points to a position prior to the first element in history. Be careful when using negative numbers for N, since infinite-length patterns will cause this function to never return.

Note that if the Nth element has not yet occurred, this function will advance the pstream, thus affecting what will be returned when `next' is called on the pstream. However, this behavior may change in the future.

Example: (pstream-nth-future -1 (as-pstream (pbind :foo (pseq '(1 2 3) 1)))) ;=> (EVENT :FOO 3)

See also: `pstream-nth', `pfuture'"
  (assert (integerp n) (n))
  (unless (typep pstream 'pstream)
    (return-from pstream-nth-future (pstream-nth-future n (as-pstream pstream))))
  (with-slots (history) pstream
    (flet ((should-advance ()
             (if (>= n 0)
                 (>= n (length history))
                 (not (position nil history)))))
      (loop :while (should-advance)
         :do (next pstream)) ;; FIX: use `peek' instead once `peek' is implemented.
      (if (>= n 0)
          (nth n history)
          (let ((sub-history (subseq history 0 (position nil history))))
            (nth (+ n (length sub-history)) sub-history))))))

(defgeneric parent-pattern (pattern)
  (:documentation "Get the containing pattern of PATTERN, or NIL if there isn't one.

See also: `parent-pbind'"))

(defmethod parent-pattern ((pattern pattern))
  (slot-value pattern 'parent))

(defgeneric parent-pbind (pattern)
  (:documentation "Get the containing pbind of PATTERN, or NIL if there isn't one.

See also: `parent-pattern'"))

(defmethod parent-pbind ((pattern pattern))
  (let ((par (parent-pattern pattern)))
    (loop :until (or (null par) (typep par 'pbind))
       :do (setf par (slot-value par 'parent)))
    par))

(defgeneric beats-elapsed (pstream)
  (:documentation "Get the number of beats elapsed in PSTREAM's execution."))

(defmethod beats-elapsed ((pstream pstream))
  (float
   (loop :for i :in (slot-value pstream 'history)
      :if (typep i 'event)
      :sum (event-value i :dur)
      :if (null i)
      :do (loop-finish)
      :if (and (not (typep i 'event)) (not (null i)))
      :do (error "beats-elapsed only works on pstreams that have duration information, such as those from a pbind."))))

;;; pbind

(defparameter *pbind-special-init-keys* (list)
  "The list of special keys for pbind that alters it during its initialization.

See also: `define-pbind-special-init-key'")

(defparameter *pbind-special-wrap-keys* (list)
  "The list of special keys for pbind that causes the pbind to be replaced by another pattern during its initialization.

See also: `define-pbind-special-wrap-key'")

(defparameter *pbind-special-process-keys* (list)
  "The list of special keys for pbind that alter the outputs of the pbind.

See also: `define-pbind-special-process-key'")

(defclass pbind (pattern)
  ((pairs :initarg :pairs :initform (list)))
  (:documentation "Please refer to the `pbind' documentation."))

(defun pbind (&rest pairs)
  "pbind yields events determined by its PAIRS, which are a list of keys and values. Each key corresponds to a key in the resulting events, and each value is treated as a pattern that is evaluated for each step of the pattern to generate the value for its key.

Example:

;; (next-n (pbind :foo (pseq '(1 2 3)) :bar :hello) 4)
;; => ((EVENT :FOO 1 :BAR :HELLO) (EVENT :FOO 2 :BAR :HELLO) (EVENT :FOO 3 :BAR :HELLO) NIL)

See also: `pmono'"
  (assert (evenp (length pairs)) (pairs))
  (when (> (count :pdef (keys pairs)) 1)
    (warn "More than one :pdef key detected in pbind."))
  (let* ((res-pairs (list))
         (pattern-chain (list))
         (pattern (make-instance 'pbind)))
    (loop :for (key value) :on pairs :by #'cddr
       :do
         (progn
           (when (typep value 'pattern)
             (setf (slot-value value 'parent) pattern))
           (cond ((position key *pbind-special-init-keys*)
                  (alexandria:when-let ((result (funcall (getf *pbind-special-init-keys* key) value pattern)))
                    (setf res-pairs (append res-pairs result))))
                 ((position key *pbind-special-wrap-keys*)
                  (unless (null res-pairs)
                    (setf (slot-value pattern 'pairs) res-pairs)
                    (setf res-pairs (list)))
                  (unless (null pattern-chain)
                    (setf pattern (apply #'pchain (append pattern-chain (list pattern))))
                    (setf pattern-chain (list)))
                  (setf pattern (funcall (getf *pbind-special-wrap-keys* key) value pattern)))
                 (t
                  (unless (typep pattern 'pbind)
                    (alexandria:appendf pattern-chain (list pattern))
                    (setf pattern (make-instance 'pbind)))
                  (alexandria:appendf res-pairs (list key (if (and (eq key :inject)
                                                                   (typep value 'symbol))
                                                              (pdef value)
                                                              value)))))))
    (unless (null res-pairs)
      (setf (slot-value pattern 'pairs) res-pairs))
    (alexandria:appendf pattern-chain (list pattern))
    (unless (= 1 (length pattern-chain))
      (setf pattern (apply #'pchain pattern-chain)))
    ;; process :quant key. ;; FIX: should this be applied to the pdef, or the pattern itself?
    (alexandria:when-let ((quant (getf pairs :quant)))
      (setf (quant pattern)
            (if (functionp quant)
                (funcall quant)
                quant)))
    ;; process :pdef key.
    (alexandria:when-let ((pdef-name (getf pairs :pdef)))
      (pdef pdef-name pattern))
    pattern))

(setf (documentation 'pbind 'type) (documentation 'pbind 'function))

(defmacro pb (name &body pairs) ;; FIX: should automatically convert +, *, -, /, etc to their equivalent patterns.
  "pb is a small convenience wrapper around `pbind'. NAME is a keyword for the name of the pattern (same as pbind's :pdef key or `pdef' itself), and PAIRS is the same as in regular pbind.

See also: `pbind', `pdef'"
  `(pbind :pdef ,name ,@pairs))

(defclass pbind-pstream (pbind pstream)
  ())

(defun as-pstream-pairs (pairs)
  (let ((results (list)))
    (loop :for (key val) :on pairs :by #'cddr
       :do (setf results (append results (list key (pattern-as-pstream val)))))
    results))

(defmethod as-pstream ((pattern pbind))
  (let ((slots (mapcar #'closer-mop:slot-definition-name (closer-mop:class-slots (class-of pattern)))))
    (apply #'make-instance
           (intern (concatenate 'string (symbol-name (class-name (class-of pattern))) "-PSTREAM") 'cl-patterns)
           (loop :for slot :in slots
              :collect (alexandria:make-keyword slot)
              :if (equal :pairs (alexandria:make-keyword slot))
              :collect (as-pstream-pairs (slot-value pattern 'pairs))
              :else
              :collect (slot-value pattern slot)))))

(defmacro define-pbind-special-init-key (key &body body)
  "Define a special key for pbind that alters the pbind during its initialization, either by injecting a plist into its pattern-pairs or in another way. These functions are called once, when the pbind is created, and must return a plist if the key should inject values into the pbind pairs, or NIL if it should not."
  (let ((keyname (alexandria:make-keyword key)))
    `(setf (getf *pbind-special-init-keys* ,keyname)
           (lambda (value pattern)
             (declare (ignorable value pattern))
             ,@body))))

(define-pbind-special-init-key remaining
  (setf (slot-value pattern 'remaining) (next value))
  nil)

(define-pbind-special-init-key inst ;; FIX: this should be part of event so it will affect the event as well. maybe just rename to 'synth'?
  (list :instrument value))

(defmacro define-pbind-special-wrap-key (key &body body)
  "Define a special key for pbind that replaces the pbind with another pattern during the pbind's initialization. Each encapsulation key is run once on the pbind after it has been initialized, altering the type of pattern returned if the return value of the function is non-NIL."
  (let ((keyname (alexandria:make-keyword key)))
    `(setf (getf *pbind-special-wrap-keys* ,keyname)
           (lambda (value pattern)
             (declare (ignorable value pattern))
             ,@body))))

(define-pbind-special-wrap-key parp
  (parp pattern value))

(define-pbind-special-wrap-key pfin
  (pfin pattern value))

(define-pbind-special-wrap-key pfindur
  (pfindur pattern value))

(define-pbind-special-wrap-key psync
  (if (listp value)
      (destructuring-bind (quant &optional maxdur) value
        (psync pattern quant maxdur))
      (psync pattern value value)))

(define-pbind-special-wrap-key pdurstutter
  (pdurstutter pattern value))

(define-pbind-special-wrap-key pr
  (pr pattern value))

(define-pbind-special-wrap-key ptrace
  (if value
      (if (eq t value)
          (ptrace pattern)
          (ptrace pattern value))
      pattern))

(defmacro define-pbind-special-process-key (key &body body)
  "Define a special key for pbind that alters the pattern in a nonstandard way. These functions are called for each event created by the pbind and must return a list or event if the key should inject values into the event stream, or NIL if it should not."
  (let ((keyname (alexandria:make-keyword key)))
    `(setf (getf *pbind-special-process-keys* ,keyname)
           (lambda (value)
             ,@body))))

(define-pbind-special-process-key inject
  value)

(defmethod next ((pattern pbind-pstream))
  (labels ((pbind-accumulator (pairs)
             (let ((next-cadr (next (cadr pairs))))
               (unless (null next-cadr)
                 (if (position (car pairs) (keys *pbind-special-process-keys*))
                     (let ((result (funcall (getf *pbind-special-process-keys* (car pairs)) next-cadr)))
                       (setf *event* (combine-events *event* result)))
                     (setf (event-value *event* (alexandria:ensure-symbol (car pairs) 'cl-patterns)) next-cadr))
                 (if (not (null (cddr pairs)))
                     (pbind-accumulator (cddr pairs))
                     *event*)))))
    (let ((*event* (make-default-event)))
      (unless (or (null (slot-value pattern 'remaining))
                  (eq :inf (slot-value pattern 'remaining)))
        (setf (event-value *event* :remaining) (slot-value pattern 'remaining)))
      (pbind-accumulator (slot-value pattern 'pairs)))))

(defmethod as-pstream ((item pbind-pstream))
  item)

;;; pmono

(defun pmono (instrument &rest pairs)
  "pmono defines a mono instrument event pstream. It's effectively the same as `pbind' with its :type key set to :mono.

See also: `pbind'"
  (assert (evenp (length pairs)) (pairs))
  (apply #'pbind
         :instrument instrument
         :type :mono
         pairs))

;;; pseq

(defpattern pseq (pattern)
  (list
   (repeats :default :inf)
   (offset :default 0) ;; FIX: add tests for this
   (current-repeats-remaining :state t))
  "pseq yields values from LIST in the same order they were provided, repeating the whole list REPEATS times. OFFSET is the offset to index into the list.

Example:

;; (next-n (pseq '(5 6 7) 2) 7)
;; => (5 6 7 5 6 7 NIL)
;;
;; (next-upto-n (pseq '(5 6 7) 2 1))
;; => (6 7 5 6 7 5)

See also: `pser'")

(defmethod as-pstream ((pattern pseq))
  (with-slots (repeats list offset) pattern
    (make-instance 'pseq-pstream
                   :list (next list)
                   :repeats (as-pstream repeats)
                   :offset (pattern-as-pstream offset))))

(defmethod next ((pseq pseq-pstream))
  (with-slots (number list offset) pseq
    (when (and (plusp number)
               (= 0 (mod number (length list))))
      (decf-remaining pseq 'current-repeats-remaining))
    (when (remainingp pseq)
      (nth-wrap (+ (or (next offset) 0) number) list))))

;;; pser

(defpattern pser (pattern)
  (list
   (length :default :inf)
   ;; FIX: add offset and tests for it
   (current-repeats-remaining :state t)
   (current-index :state t))
  "pser yields values from LIST in the same order they were provided, returning a total of LENGTH values.

Example:

;; (next-n (pser '(5 6 7) 2) 3)
;; => (5 6 NIL)

See also: `pseq'")

(defmethod as-pstream ((pattern pser))
  (with-slots (list length) pattern
    (make-instance 'pser-pstream
                   :list (next list)
                   :length (as-pstream length))))

(defmethod next ((pattern pser-pstream))
  (with-slots (list current-index) pattern
    (alexandria:when-let ((remaining (remainingp pattern 'length)))
      (decf-remaining pattern 'current-repeats-remaining)
      (when (eq :reset remaining)
        (setf current-index 0))
      (prog1
          (nth (mod current-index (length list))
               list)
        (incf current-index)))))

;;; pk

(defpattern pk (pattern)
  (key
   (default :default 1))
  "pk returns the value of KEY in the current *event* context, returning DEFAULT if that value is nil.

Example:

;; (next-n (pbind :foo (pseq '(1 2 3)) :bar (pk :foo)) 3)
;; => ((EVENT :FOO 1 :BAR 1) (EVENT :FOO 2 :BAR 2) (EVENT :FOO 3 :BAR 3))

See also: `event-value', `*event*'")

(defmethod as-pstream ((pattern pk))
  (with-slots (key default) pattern
    (make-instance 'pk-pstream
                   :key key
                   :default default)))

(defmethod next ((pk pk-pstream))
  (with-slots (key default) pk
    (or (event-value *event* key)
        (if (string= :number key)
            (slot-value pk 'number)
            default))))

;;; prand

(defpattern prand (pattern)
  (list
   (length :default :inf)
   (current-repeats-remaining :state t))
  "prand returns a random value from LIST, returning a total of LENGTH values.

Example: (next-n (prand '(1 2 3) 5) 6) ;=> (3 2 2 1 1 NIL)

See also: `pxrand', `pwrand', `pwxrand'")

(defmethod as-pstream ((pattern prand))
  (with-slots (list length) pattern
    (make-instance 'prand-pstream
                   :list (next list)
                   :length (as-pstream length))))

(defmethod next ((pattern prand-pstream))
  (when (remainingp pattern 'length)
    (decf-remaining pattern 'current-repeats-remaining)
    (alexandria:random-elt (slot-value pattern 'list))))

;;; pxrand

(defpattern pxrand (pattern)
  (list
   (length :default :inf)
   (last-result :state t :initform nil)
   (current-repeats-remaining :state t))
  "pxrand returns a random value from LIST that is not equal to the last result, returning a total of LENGTH values.

See also: `prand', `pwrand', `pwxrand'"
  (assert (> (length (remove-duplicates list)) 1) (list)))

(defmethod as-pstream ((pattern pxrand))
  (with-slots (list length) pattern
    (make-instance 'pxrand-pstream
                   :list (next list)
                   :length (as-pstream length))))

(defmethod next ((pattern pxrand-pstream))
  (with-slots (list last-result) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (let ((res (alexandria:random-elt list)))
        (loop :while (eql res last-result)
           :do (setf res (alexandria:random-elt list)))
        (setf last-result res)
        res))))

;;; pwrand

(defpattern pwrand (pattern)
  (list
   (weights :default (make-list (length list) :initial-element 1))
   (length :default :inf)
   (current-repeats-remaining :state t))
  "pwrand returns a random element from LIST weighted by respective values from WEIGHTS, for a total of LENGTH values.

See also: `prand', `pxrand', `pwxrand'")

(defmethod as-pstream ((pattern pwrand))
  (with-slots (list weights length) pattern
    (make-instance 'pwrand-pstream
                   :list (next list)
                   :weights (next weights)
                   :length (as-pstream length))))

(defmethod next ((pattern pwrand-pstream))
  (with-slots (list weights) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (let* ((cweights (cumulative-list (normalized-sum weights)))
             (num (random 1.0)))
        (nth (index-of-greater-than num cweights) list)))))

;;; pwxrand

(defpattern pwxrand (pattern)
  (list
   (weights :default (make-list (length list) :initial-element 1))
   (length :default :inf)
   (current-repeats-remaining :state t))
  "pwxrand returns a random element from LIST weighted by respective values from WEIGHTS, for a total of LENGTH values, never repeating the same value twice in a row."
  (assert (> (length (remove-duplicates list)) 1) (list)))

(defmethod as-pstream ((pattern pwxrand))
  (with-slots (list weights length) pattern
    (make-instance 'pwxrand-pstream
                   :list list
                   :weights weights
                   :length (as-pstream length))))

(defmethod next ((pattern pwxrand-pstream))
  (with-slots (list weights) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (labels ((get-next ()
                 (let* ((cweights (cumulative-list (normalized-sum weights)))
                        (num (random 1.0))
                        (res (nth (index-of-greater-than num cweights) list)))
                   (when (not (null (slot-value pattern 'history)))
                     (loop :while (eql res (pstream-nth -1 pattern))
                        :do (setf res (get-next))))
                   res)))
        (get-next)))))

;;; pfunc
;; NOTE: This implementation doesn't provide the event as an argument to the function like the SuperCollider implementation does.
;; Instead, access the event using the special variable *event*.

(defpattern pfunc (pattern)
  (func)
  "pfunc returns the result of the provided function FUNC."
  (assert (typep func 'function) (func)))

(defmethod as-pstream ((pattern pfunc))
  (with-slots (func) pattern
    (make-instance 'pfunc-pstream
                   :func func)))

(defmethod next ((pattern pfunc-pstream))
  (funcall (slot-value pattern 'func)))

;;; pr

(defpattern pr (pattern)
  (pattern
   (repeats :default :inf)
   (current-value :state t :initform nil)
   (current-repeats-remaining :state t))
  "pr yields a value from PATTERN REPEATS times before moving on to the next value from PATTERN.

See also: `pstutter', `pdurstutter', `parp'")

(defmethod as-pstream ((pattern pr))
  (with-slots (pattern repeats) pattern
    (make-instance 'pr-pstream
                   :pattern (as-pstream pattern)
                   :repeats (pattern-as-pstream repeats))))

(defmethod next ((pr pr-pstream))
  (with-slots (pattern repeats current-value current-repeats-remaining) pr
    (loop :while (or (not (slot-boundp pr 'current-repeats-remaining))
                     (and (not (null current-repeats-remaining))
                          (not (null current-value))
                          (not (value-remaining-p current-repeats-remaining))))
       :do
       (setf current-value (next pattern))
       (when current-value
         (setf current-repeats-remaining
               (if (typep repeats 'function)
                   (let ((fle (function-lambda-expression repeats)))
                     (if fle
                         (if (= (length (cadr fle)) 0)
                             (funcall repeats)
                             (funcall repeats current-value))
                         (handler-case
                             (funcall repeats current-value)
                           #+sbcl (sb-int:simple-program-error (e) ;; FIX: need to add stuff for other implementations or generalize it somehow.
                                    (declare (ignore e))
                                    (funcall repeats)))))
                   (next repeats)))))
    (when (value-remaining-p current-repeats-remaining)
      (decf-remaining pr 'current-repeats-remaining)
      current-value)))

;;; pdef
;; NOTE: the pattern in a pdef will loop when played on a clock.
;; this can be prevented by doing (setf (slot-value YOUR-PDEF 'loop-p) nil)
;; if the pattern in a pdef is redefined, it switches between the current and next loops by default.
;; not fully implemented yet (FIX): if you want the pdef to switch at a time other than between loops, set the 'quant or 'condition slots.
;; if you want the pdef to stop after its current loop, set it to nil like so: (pdef KEY nil)

;; (pdef-ref KEY) returns the pdef's plist which holds the pattern, pstream, task, etc.
;; (pdef-ref-get KEY :task) returns the task associated with (pdef KEY).
;; (pdef-ref-set KEY :pattern PAT) sets the pattern for (pdef KEY) to PAT.

;; FIX: need 'reset' method

(defun pdef-ref-get (pdef-key key)
  "Get PDEF-KEY's KEY value from its plist."
  (getf (pdef-ref pdef-key) (alexandria:make-keyword key)))

(defun pdef-ref-set (pdef-key key pattern)
  "Set PDEF-KEY's KEY in its plist to PATTERN."
  (pdef-ref pdef-key (plist-set (pdef-ref pdef-key) (alexandria:make-keyword key) pattern)))

(defpattern pdef (pattern) ;; FIX: should this call set-parents on its PATTERN?
  ((key :reader pdef-key)
   (current-pstream :state t)
   (loop-p :initform t :accessor loop-p))
  "pdef defines a named pattern, with KEY being the name of the pattern and PATTERN the pattern itself. Named patterns are stored in a global dictionary by name and can be referred back to by calling `pdef' without supplying PATTERN. The global dictionary also keeps track of the pdef's pstream when `play' is called on it. Additionally, if a pdef is currently being played, and is redefined, the changes won't be audible until PATTERN ends (pdefs loop by default)."
  (defun pdef (key &optional (pattern nil pattern-supplied-p))
    (when (or (not (null pattern))
              pattern-supplied-p)
      (pdef-ref-set key :pattern pattern))
    (make-instance 'pdef
                   :key key)))

(create-global-dictionary pdef)

(defmethod pdef-pattern ((object pdef))
  (pdef-ref-get (pdef-key object) :pattern))

(defmethod quant ((object pdef))
  (quant (pdef-pattern object)))

;; (defmethod quant ((object null))
;;   (list 1))

(defmethod as-pstream ((pattern pdef))
  (with-slots (key) pattern
    (make-instance 'pdef-pstream
                   :key key
                   :current-pstream (as-pstream (pdef-pattern pattern)))))

(defmethod next ((pattern pdef-pstream))
  (next (slot-value pattern 'current-pstream)))

;;; plazy

(defpattern plazy (pattern)
  (func
   (current-pstream :state t :initform nil))
  "plazy funcalls FUNC which should return a pattern, which is then yielded from until its end, at which point FUNC is re-evaluated to generate the next pattern.")

(defmethod as-pstream ((plazy plazy))
  (with-slots (func) plazy
    (make-instance 'plazy-pstream
                   :func func)))

(defmethod next ((pattern plazy-pstream))
  (with-slots (current-pstream func) pattern
    (let ((nv (next current-pstream)))
      (loop :repeat 5
         :while (or (null current-pstream)
                    (null nv))
         :do
         (setf current-pstream (as-pstream (funcall func)))
         (setf nv (next current-pstream)))
      nv)))

;;; plazyn

(defpattern plazyn (pattern)
  (func
   (repeats :default :inf)
   (current-pstream :state t :initform nil)
   (current-repeats-remaining :state t :initform nil))
  "plazyn funcalls FUNC which should return a pattern, which is then yielded from until its end, at which point FUNC is re-evaluated to generate the next pattern. The pattern is generated a total of REPEATS times.")

(defmethod as-pstream ((pattern plazyn))
  (with-slots (func repeats) pattern
    (make-instance 'plazyn-pstream
                   :func func
                   :repeats (as-pstream repeats))))

(defmethod next ((pattern plazyn-pstream))
  (with-slots (func repeats current-pstream current-repeats-remaining) pattern
    (labels ((maybe-funcall ()
               (when (remainingp pattern)
                 (setf current-pstream (as-pstream (funcall func)))
                 (decf-remaining pattern 'current-repeats-remaining))))
      (when (null current-repeats-remaining)
        (setf current-repeats-remaining (next repeats)))
      (when (null current-pstream)
        (maybe-funcall))
      (let ((nv (next current-pstream)))
        (if (null nv)
            (progn
              (maybe-funcall)
              (next current-pstream))
            nv)))))

;;; pshift
;; shift a pattern N forward or backward, wrapping around

(defun pshift (pattern shift &optional (max-yield *max-pattern-yield-length*)) ;; FIX: don't use pseq internally, and make it possible for 'shift' to be a pattern
  (pseq (alexandria:rotate (next-upto-n pattern max-yield) shift)))

;;; pn

(defpattern pn (pattern)
  (pattern
   (repeats :default :inf)
   (current-repeats-remaining :state t)
   (current-pstream :state t :initform nil))
  "pn embeds the full PATTERN into the pstream REPEATS times.")

(defmethod as-pstream ((pn pn)) ;; need this so that PATTERN won't be automatically converted to a pstream when the pn is.
  (with-slots (pattern repeats) pn
    (make-instance 'pn-pstream
                   :pattern pattern
                   :repeats (as-pstream repeats))))

(defmethod next ((pn pn-pstream))
  (with-slots (pattern current-pstream) pn
    (alexandria:when-let ((rem (remainingp pn)))
      (when (eq :reset rem)
        (setf current-pstream (as-pstream pattern)))
      (let ((nv (next current-pstream)))
        (loop :while (and (null nv) rem) :do
           (decf-remaining pn 'current-repeats-remaining)
           (setf rem (remainingp pn))
           (setf current-pstream (as-pstream pattern))
           (setf nv (next current-pstream)))
        (when rem
          nv)))))

;;; pshuf

(defpattern pshuf (pattern)
  (list
   (repeats :default :inf)
   (shuffled-list :state t)
   (current-repeats-remaining :state t))
  "pshuf shuffles LIST, then yields each item from the shuffled list, repeating the list REPEATS times.

Example:

;; (next-upto-n (pshuf '(1 2 3) 2))
;; => (3 1 2 3 1 2)

See also: `prand'")

(defmethod as-pstream ((pattern pshuf))
  (with-slots (list repeats) pattern
    (let ((list (typecase list
                  (pattern (next-upto-n list))
                  (function (funcall list))
                  (list list))))
      (make-instance 'pshuf-pstream
                     :list (next list)
                     :repeats (as-pstream repeats)))))

(defmethod next ((pattern pshuf-pstream))
  (with-slots (list number shuffled-list) pattern
    (when (and (= 0 (mod number (length list)))
               (plusp number))
      (decf-remaining pattern 'current-repeats-remaining))
    (alexandria:when-let ((rem (remainingp pattern)))
      (when (eq :reset rem)
        (setf shuffled-list (alexandria:shuffle (copy-list list)))) ;; alexandria:shuffle destructively modifies the list, so we use copy-list in case the user provided a quoted list as input.
      (nth (mod number (length shuffled-list))
           shuffled-list))))

;;; pwhite

(defpattern pwhite (pattern)
  ((lo :default 0)
   (hi :default 1)
   (length :default :inf)
   (current-repeats-remaining :state t))
  "pwhite yields LENGTH random numbers between LO and HI.")

(defmethod as-pstream ((pattern pwhite))
  (with-slots (lo hi length) pattern
    (make-instance 'pwhite-pstream
                   :lo (pattern-as-pstream lo)
                   :hi (pattern-as-pstream hi)
                   :length (as-pstream length))))

(defmethod next ((pattern pwhite-pstream))
  (with-slots (lo hi) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (alexandria:when-let ((nlo (next lo))
                            (nhi (next hi)))
        (random-range nlo nhi)))))

;;; pbrown

(defpattern pbrown (pattern)
  ((lo :default 0)
   (hi :default 1)
   (step :default 0.125)
   (length :default :inf)
   (current-repeats-remaining :state t)
   (current-value :state t :initform nil))
  "pbrown implements brownian motion, yielding LENGTH values between LO and HI, each value a maximum of STEP away from the previous value.")

(defmethod as-pstream ((pattern pbrown))
  (with-slots (lo hi step length) pattern
    (make-instance 'pbrown-pstream
                   :lo (pattern-as-pstream lo)
                   :hi (pattern-as-pstream hi)
                   :step (pattern-as-pstream step)
                   :length (as-pstream length))))

(defmethod next ((pattern pbrown-pstream))
  (when (remainingp pattern 'length)
    (decf-remaining pattern 'current-repeats-remaining)
    (with-slots (lo hi step current-value) pattern
      (alexandria:when-let ((nlo (next lo))
                            (nhi (next hi))
                            (nstep (next step)))
        (when (null current-value)
          (setf current-value (random-range nlo nhi)))
        (incf current-value (random-range (* -1 nstep) nstep))
        (setf current-value (alexandria:clamp current-value nlo nhi))))))

;;; pexprand

(defpattern pexprand (pattern)
  ((lo :default 0.0001)
   (hi :default 1)
   (length :default :inf)
   (current-repeats-remaining :state t))
  "pexprand yields LENGTH exponentially-distributed random numbers between LO and HI.")

(defmethod as-pstream ((pattern pexprand))
  (with-slots (lo hi length) pattern
    (make-instance 'pexprand-pstream
                   :lo (pattern-as-pstream lo)
                   :hi (pattern-as-pstream hi)
                   :length (as-pstream length))))

(defmethod next ((pattern pexprand-pstream))
  (with-slots (lo hi) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (alexandria:when-let ((nlo (next lo))
                            (nhi (next hi)))
        (exponential-random-range nlo nhi)))))

;;; pseries

(defpattern pseries (pattern)
  ((start :default 0)
   (step :default 1)
   (length :default :inf)
   (current-repeats-remaining :state t)
   (current-value :state t :initform nil))
  "pseries yields START, and then each subsequent value is the previous value plus STEP, for a total of LENGTH values yielded.")

(defmethod as-pstream ((pattern pseries))
  (with-slots (start step length) pattern
    (let ((s (next start)))
      (make-instance 'pseries-pstream
                     :start s
                     :step (pattern-as-pstream step)
                     :length (as-pstream length)
                     :current-value s))))

(defmethod next ((pattern pseries-pstream))
  (with-slots (step current-value) pattern
    (when (and (remainingp pattern 'length)
               current-value)
      (decf-remaining pattern 'current-repeats-remaining)
      (let ((nxt (next step)))
        (prog1
            current-value
          (if (numberp nxt)
              (incf current-value nxt) ;; FIX: current-value should be CURRENT value, not the next one! also write tests for this!
              (setf current-value nil)))))))

;;; pgeom

(defpattern pgeom (pattern)
  ((start :default 1)
   (grow :default 2)
   (length :default :inf)
   (current-repeats-remaining :state t)
   (current-value :state t :initform nil))
  "pgeom yields START, and then each subsequent value is the previous value times GROW, for a total of LENGTH values yielded.")

(defmethod as-pstream ((pattern pgeom))
  (with-slots (start grow length) pattern
    (let ((s (next start)))
      (make-instance 'pgeom-pstream
                     :start s
                     :grow (pattern-as-pstream grow)
                     :length (as-pstream length)
                     :current-value s))))

(defmethod next ((pattern pgeom-pstream))
  (with-slots (grow current-value) pattern
    (when (remainingp pattern 'length)
      (decf-remaining pattern 'current-repeats-remaining)
      (if (= 0 (slot-value pattern 'number))
          current-value
          (alexandria:when-let ((n (next grow)))
            (setf current-value (* current-value n)))))))

;;; ptrace

(defpattern ptrace (pattern)
  (pattern
   (key :default nil)
   (stream :default t)
   (prefix :default ""))
  "ptrace prints to STREAM the PREFIX and then the value of KEY for each event yielded by PATTERN, or the whole event or value if KEY is not provided. ptrace yields everything from the source PATTERN unaffected.")

(defmethod as-pstream ((ptrace ptrace))
  (with-slots (pattern key stream prefix) ptrace
    (make-instance 'ptrace-pstream
                   :pattern (as-pstream pattern)
                   :key (pattern-as-pstream key)
                   :stream stream
                   :prefix (pattern-as-pstream prefix))))

(defmethod next ((ptrace ptrace-pstream))
  (with-slots (pattern key stream prefix) ptrace
    (let* ((n (next pattern))
           (result (if (and (not (null key))
                            (not (null n)))
                       (event-value n key)
                       n)))
      (format stream "~a~a~%" prefix result)
      n)))

;;; ppatlace

(defpattern ppatlace (pattern)
  (list
   (repeats :default 1)
   (current-repeats-remaining :state t))
  "ppatlace yields each value from LIST in sequence. If the value is a pattern, one value is yielded from that pattern before moving on to the next item in LIST. The second time around the LIST, the second value yielded from each pattern in LIST will be yielded instead. If one of the patterns embedded in LIST ends sooner than the others, it is simply removed and the ppatlace continues to yield from the rest of the LIST. The entire LIST is yielded through a total of REPEATS times.")

(defmethod as-pstream ((pattern ppatlace))
  (with-slots (repeats list) pattern
    (make-instance 'ppatlace-pstream
                   :list (mapcar #'pattern-as-pstream list)
                   :repeats (as-pstream repeats))))

(defmethod next ((pattern ppatlace-pstream))
  (with-slots (number list) pattern
    (when (and (not (= number 0))
               (= 0 (mod number (length list))))
      (decf-remaining pattern 'current-repeats-remaining))
    (when (if (plusp number)
              (and (not (null (pstream-nth -1 pattern)))
                   (remainingp pattern))
              (remainingp pattern))
      (let* ((mod (mod number (length list)))
             (result (next (nth mod list))))
        (if (not (null result))
            result
            (progn
              (setf list (remove-if (constantly t) list :start mod :end (1+ mod)))
              (when (plusp (length list))
                (next pattern))))))))

;;; pnary

(defpattern pnary (pattern)
  (operator
   (patterns :initarg :patterns))
  "pnary yields the result of applying OPERATOR to each value yielded by each pattern in PATTERNS."
  (defun pnary (operator &rest patterns)
    (set-parents
     (make-instance 'pnary
                    :operator operator
                    :patterns patterns))))

(defmethod as-pstream ((pattern pnary))
  (with-slots (operator patterns) pattern
    (make-instance 'pnary-pstream
                   :operator (pattern-as-pstream operator)
                   :patterns (mapcar #'pattern-as-pstream patterns))))

(defmethod next ((pattern pnary-pstream))
  (with-slots (operator patterns) pattern
    (let ((op (if (typep operator 'pstream)
                  (next operator)
                  operator))
          (nexts (mapcar #'next patterns)))
      (unless (or (position nil nexts)
                  (null op))
        (apply op nexts)))))

(defun p+ (&rest numbers)
  "p+ adds NUMBERS, where NUMBERS can be any object that responds to the `next' method. This function is simply a shortcut for (apply #'pnary #'+ numbers)."
  (apply #'pnary #'+ numbers))

(defun p- (&rest numbers)
  "p- subtracts NUMBERS, where NUMBERS can be any object that responds to the `next' method. This function is simply a shortcut for (apply #'pnary #'- numbers)."
  (apply #'pnary #'- numbers))

(defun p* (&rest numbers)
  "p* multiplies NUMBERS, where NUMBERS can be any object that responds to the `next' method. This function is simply a shortcut for (apply #'pnary #'* numbers)."
  (apply #'pnary #'* numbers))

(defun p/ (&rest numbers)
  "p/ divides NUMBERS, where NUMBERS can be any object that responds to the `next' method. This function is simply a shortcut for (apply #'pnary #'/ numbers)."
  (apply #'pnary #'/ numbers))

;;; pslide

(defpattern pslide (pattern)
  (list
   (repeats :default 1)
   (len :default 3)
   (step :default 1)
   (start :default 0)
   (wrap-at-end :default t)
   (current-repeats-remaining :state t)
   (current-repeats :state t :initform nil)
   (remaining-current-segment :state t :initform nil)
   (current-value :state t :initform nil))
  "pslide slides across sections LIST. REPEATS is the total number of sections to output, LEN the length of the section. STEP the number to increment the start index by after each section, and START is the initial index that the first section starts from. WRAP-AT-END, when true, means that an index outside of the list will wrap around. When false, indexes outside of the list will return nils.

Example: (next-upto-n (pslide (list 0 1 2 3 4 5 6) 3 3 2 1 t)) ;=> (1 2 3 3 4 5 5 6 0)

See also: `pscratch'")

(defmethod as-pstream ((pattern pslide))
  (with-slots (list repeats len step start wrap-at-end) pattern
    (make-instance 'pslide-pstream
                   :list (next list)
                   :repeats (pattern-as-pstream repeats)
                   :len (pattern-as-pstream len)
                   :step (pattern-as-pstream step)
                   :start (next start)
                   :wrap-at-end (next wrap-at-end)
                   :current-repeats 0
                   :remaining-current-segment len
                   :current-value start)))

(defmethod next ((pattern pslide-pstream))
  (with-slots (list repeats len step start wrap-at-end current-repeats-remaining current-repeats remaining-current-segment current-value) pattern
    (labels ((get-next ()
               (if (and (not wrap-at-end)
                        (minusp current-value))
                   nil
                   (funcall (if wrap-at-end #'nth-wrap #'nth) current-value list))))
      (when (not (slot-boundp pattern 'current-repeats-remaining))
        (setf current-repeats-remaining (next repeats)))
      (when (value-remaining-p current-repeats-remaining)
        (if (value-remaining-p remaining-current-segment)
            (prog1
                (get-next)
              (decf-remaining pattern 'remaining-current-segment)
              (incf current-value))
            (progn
              (decf-remaining pattern 'current-repeats-remaining)
              (setf remaining-current-segment (next len))
              (incf current-repeats)
              (setf current-value (+ start (* step current-repeats)))
              (next pattern)))))))

;;; phistory
;; basically uses pstream-nth to refer to history

;; (pscratch (pseries 0 1) (pseq (list 0 (pseq (list 1 1 1 -3) :inf))))

(defpattern phistory (pattern)
  (pattern
   step-pattern)
  "phistory refers back to PATTERN's history, yielding the value at the index provided by STEP-PATTERN. Note that PATTERN is still advanced once per event, and if STEP-PATTERN yields a number pointing to an event in PATTERN that hasn't been yielded yet (i.e. if PATTERN has only advanced once but STEP-PATTERN yields 3 for its output), it will return nil.

Example: (next-n (phistory (pseries) (pseq '(0 2 1))) 3) ;=> (0 NIL 1)

See also: `pfuture', `pscratch'")

(defmethod as-pstream ((phistory phistory))
  (with-slots (pattern step-pattern) phistory
    (make-instance 'phistory-pstream
                   :pattern (as-pstream pattern)
                   :step-pattern (as-pstream step-pattern))))

(defmethod next ((pstream phistory-pstream))
  (with-slots (pattern step-pattern) pstream
    (alexandria:when-let ((next-step (next step-pattern)))
      (next pattern)
      (handler-case (pstream-nth next-step pattern)
        (pstream-out-of-range ()
          nil)))))

;;; pfuture (FIX)
;; like phistory, but immediately slurps the whole pstream and then allows you to index from its history instead of advancing the source pattern one at a time as normal
;; phistory is kept around because some (time-based) patterns may need to be advanced normally rather than all at once (though it might be kind of a bad idea to try to use phistory, pfuture, or pscratch on those kinds of patterns)
;; FIX: maybe deprecate this and just integrate its functionality into phistory somehow?
;; FIX: use `pstream-nth-future' to get the values for this instead of slurping the whole pstream right away.

(defpattern pfuture (phistory)
  (pattern
   step-pattern)
  "pfuture gets the first *max-pattern-yield-length* outputs from PATTERN, and then uses STEP-PATTERN to index that history.

See also: `phistory', `pscratch'")

;; (defun pfuture (pattern step-pattern)
;;   (make-instance 'pfuture
;;                  :pattern pattern
;;                  :step-pattern step-pattern))

(defmethod as-pstream ((pfuture pfuture))
  (with-slots (pattern step-pattern) pfuture
    (let ((source-pstream (as-pstream pattern)))
      (next-upto-n source-pstream)
      (make-instance 'pfuture-pstream
                     :pattern source-pstream
                     :step-pattern (as-pstream step-pattern)))))

;;; pscratch
;;
;; NOTE: pscratch's mechanism seems to be slightly different:
;; supercollider:
;; > Pscratch(Pseries(0, 1), Pseq([1, 1, 1, -3], inf)).asStream.nextN(12)
;; [ 0, 1, 2, 0, 1, 2, 3, 0, 1, 2, 3, 0 ]
;;
;; lisp:
;; > (next-n (pscratch (pseries 0 1) (pseq (list 1 1 1 -3) :inf)) 12)
;; (1 2 3 0 1 2 3 0 1 2 3 0)
;; FIX: document this in sc-differences.org

(defpattern pscratch (pattern)
  (pattern
   step-pattern
   (current-index :state t :initform 0))
  "pscratch \"scratches\" across the values yielded by a pstream. PATTERN is the source pattern, and STEP-PATTERN determines the increment of the index into the pstream history.

Example: (next-upto-n (pscratch (pseries) (pseq '(0 1 1 -1 2)))) ;=> (0 1 2 1 3)

See also: `phistory', `pfuture'")

(defmethod as-pstream ((pscratch pscratch))
  (with-slots (pattern step-pattern) pscratch
    (make-instance 'pscratch-pstream
                   :pattern (as-pstream pattern)
                   :step-pattern (pattern-as-pstream step-pattern))))

(defmethod next ((pscratch pscratch-pstream))
  (with-slots (pattern step-pattern current-index) pscratch
    (alexandria:when-let ((nxt (next step-pattern)))
      (incf current-index nxt) ;; FIX: should we clamp this so negative indexes don't happen?
      (pstream-nth-future current-index pattern))))

;;; pif

(defpattern pif (pattern)
  (condition
   true
   false)
  "pif acts as an if statement for patterns. CONDITION is evaluated for each step, and if it's non-nil, the value of TRUE will be yielded, otherwise the value of FALSE will be. Note that TRUE and FALSE can be patterns, and if they are, they are only advanced in their respective cases, not for every step. Also note that pif will continue to advance even if CONDITION yields nil; pif only yields nil if TRUE or FALSE do.

Example: (next-n (pif (pseq '(t t nil nil nil)) (pseq '(1 2)) (pseq '(3 nil 4))) 5) ;=> (1 2 3 NIL 4)")

(defmethod as-pstream ((pif pif))
  (with-slots (condition true false) pif
    (make-instance 'pif-pstream
                   :condition (pattern-as-pstream condition)
                   :true (pattern-as-pstream true)
                   :false (pattern-as-pstream false))))

(defmethod next ((pif pif-pstream))
  (with-slots (condition true false) pif
    (if (next condition)
        (next true)
        (next false))))

;;; parp

(defpattern parp (pattern)
  (pattern
   arpeggiator
   (current-pattern-event :state t :initform nil)
   (current-arpeggiator-stream :state t :initform nil))
  "parp is an \"arpeggiator\"; each event yielded by PATTERN is bound to *event* and then the entirety of the ARPEGGIATOR pattern is yielded.

Example: (next-n (parp (pbind :foo (pseq '(1 2 3))) (pbind :bar (pseq '(4 5 6)))) 9) ;=>
((EVENT :FOO 1 :BAR 4) (EVENT :FOO 1 :BAR 5) (EVENT :FOO 1 :BAR 6)
 (EVENT :FOO 2 :BAR 4) (EVENT :FOO 2 :BAR 5) (EVENT :FOO 2 :BAR 6)
 (EVENT :FOO 3 :BAR 4) (EVENT :FOO 3 :BAR 5) (EVENT :FOO 3 :BAR 6))")

(defmethod as-pstream ((parp parp))
  (with-slots (pattern arpeggiator) parp
    (let ((pstr (as-pstream pattern)))
      (make-instance 'parp-pstream
                     :pattern pstr
                     :arpeggiator arpeggiator
                     :current-pattern-event (next pstr)
                     :current-arpeggiator-stream (as-pstream arpeggiator)))))

(defmethod next ((parp parp-pstream))
  (with-slots (pattern arpeggiator current-pattern-event current-arpeggiator-stream) parp
    (unless (null current-pattern-event)
      (let ((nxt (let ((*event* (combine-events current-pattern-event)))
                   (next current-arpeggiator-stream))))
        (if (null nxt)
            (progn
              (setf current-pattern-event (next pattern)
                    current-arpeggiator-stream (as-pstream arpeggiator))
              (next parp))
            nxt)))))

;;; pfin

(defpattern pfin (pattern)
  (pattern
   count)
  "pfin yields up to COUNT outputs from PATTERN.

Example: (next-n (pfin (pseq '(1 2 3) :inf) 3) 5) ;=> (1 2 3 NIL NIL)

See also: `pfindur'")

(defmethod as-pstream ((pfin pfin))
  (with-slots (count pattern) pfin
    (make-instance 'pfin-pstream
                   :pattern (as-pstream pattern)
                   :count (next count))))

(defmethod next ((pfin pfin-pstream))
  (with-slots (pattern count number) pfin
    (when (< number count)
      (next pattern))))

;;; pfindur

(defpattern pfindur (pattern)
  (pattern
   dur
   (tolerance :default 0)
   (current-elapsed :state t :initform 0))
  "pfindur yields events from PATTERN until their total duration is within TOLERANCE of DUR, or greater than DUR.

Example: (next-n (pfindur (pbind :dur 1 :foo (pseries)) 2) 3) ;=> ((EVENT :DUR 1 :FOO 0) (EVENT :DUR 1 :FOO 1) NIL)

See also: `pfin', `psync'")

(defmethod as-pstream ((pfindur pfindur))
  (with-slots (pattern dur tolerance) pfindur
    (make-instance 'pfindur-pstream
                   :pattern (as-pstream pattern)
                   :dur (next dur)
                   :tolerance (next tolerance))))

(defmethod next ((pfindur pfindur-pstream)) ;; FIX: make this affect the dur AND delta properly.
  (with-slots (pattern dur tolerance current-elapsed) pfindur
    (alexandria:when-let ((n-event (next pattern)))
      (when (< (if (= 0 tolerance)
                   current-elapsed
                   (round-up current-elapsed tolerance))
               dur)
        (let ((new-elapsed (+ (event-value n-event :delta) current-elapsed)))
          (prog1
              (if (> (if (= 0 tolerance)
                         new-elapsed
                         (round-up new-elapsed tolerance))
                     dur)
                  (combine-events n-event (event :dur (- dur current-elapsed)))
                  n-event)
            (incf current-elapsed (event-value n-event :delta))))))))

;;; psync

(defpattern psync (pattern)
  (pattern
   quant
   (maxdur :default nil)
   (tolerance :default 0.001))
  "psync yields events from PATTERN until their total duration is within TOLERANCE of MAXDUR, cutting off any events that would extend past MAXDUR. If PATTERN ends before MAXDUR, a rest is added to the pstream to round its duration up to the nearest multiple of QUANT.

Example:

;; (next-upto-n (psync (pbind :dur (pseq '(5) 1)) 4 16))
;; => ((EVENT :DUR 5) (EVENT :TYPE :REST :DUR 3))
;;
;; (next-upto-n (psync (pbind :dur (pseq '(5) 5)) 4 16))
;; => ((EVENT :DUR 5) (EVENT :DUR 5) (EVENT :DUR 5) (EVENT :DUR 5 :DELTA 1))

See also: `pfindur'")

(defmethod as-pstream ((psync psync))
  (with-slots (pattern quant maxdur tolerance) psync
    (make-instance 'psync-pstream
                   :pattern (as-pstream pattern)
                   :quant (next quant)
                   :maxdur (next maxdur)
                   :tolerance (next tolerance))))

(defmethod next ((psync psync-pstream)) ;; FIX: implement tolerance
  (with-slots (pattern quant maxdur tolerance history) psync
    (let* ((n-event (next pattern))
           (elapsed-dur (reduce #'+ (mapcar #'event-value (remove-if #'null history) (alexandria:circular-list :delta))))
           (delta (- (round-up elapsed-dur quant) elapsed-dur)))
      (if (null n-event)
          (when (plusp delta)
            (event :type :rest :dur delta))
          (when (or (null maxdur)
                    (not (>= elapsed-dur maxdur)))
            (if (and (not (null maxdur))
                     (> (+ elapsed-dur (event-value n-event :dur)) maxdur))
                (combine-events n-event (event :delta (- maxdur elapsed-dur)))
                n-event))))))

;;; pstutter

(defpattern pstutter (pattern)
  (pattern
   n
   (current-value :state t :initform nil)
   (current-repeats-remaining :state t :initform 0))
  "pstutter yields each output from PATTERN N times before moving on to the next output from PATTERN.

Example:

;; (next-n (pstutter (pseries) (pseq '(3 2 1 0 2) 1)) 9)
;; => (0 0 0 1 1 2 4 4 NIL)

See also: `pr', `pdurstutter'")

(defmethod as-pstream ((pstutter pstutter))
  (with-slots (n pattern) pstutter
    (make-instance 'pstutter-pstream
                   :pattern (as-pstream pattern)
                   :n (pattern-as-pstream n))))

(defmethod next ((pattern pstutter-pstream))
  (with-slots (n current-value current-repeats-remaining) pattern
    (loop :while (and (not (null current-repeats-remaining))
                      (= 0 current-repeats-remaining))
       :do
       (setf current-value (next (slot-value pattern 'pattern)))
       (setf current-repeats-remaining (next n)))
    (when (not (null current-repeats-remaining))
      (decf-remaining pattern 'current-repeats-remaining)
      current-value)))

;;; pdurstutter

(defpattern pdurstutter (pattern)
  (pattern
   n
   (current-value :state t :initform nil)
   (current-repeats-remaining :state t :initform 0))
  "pdurstutter yields each output from PATTERN N times, dividing it by N. If the output from PATTERN is an event, its dur is divided; if it's a number, the number itself is divided instead of being yielded directly.

Example:

;; (next-n (pdurstutter (pseq '(1 2 3 4 5)) (pseq '(3 2 1 0 2))) 9)
;; => (1/3 1/3 1/3 1 1 3 5/2 5/2 NIL)
;;
;; (next-n (pdurstutter (pbind :dur (pseq '(1 2 3 4 5))) (pseq '(3 2 1 0 2))) 9)
;; => ((EVENT :DUR 1/3) (EVENT :DUR 1/3) (EVENT :DUR 1/3) (EVENT :DUR 1) (EVENT :DUR 1) (EVENT :DUR 3) (EVENT :DUR 5/2) (EVENT :DUR 5/2) NIL)

See also: `pr', `pstutter'")

(defmethod as-pstream ((pdurstutter pdurstutter))
  (with-slots (pattern n) pdurstutter
    (make-instance 'pdurstutter-pstream
                   :pattern (as-pstream pattern)
                   :n (pattern-as-pstream n))))

(defmethod next ((pattern pdurstutter-pstream))
  (with-slots (n current-value current-repeats-remaining) pattern
    (loop :while (and (not (null current-repeats-remaining))
                      (= 0 current-repeats-remaining))
       :do
       (setf current-repeats-remaining (next n))
       (let ((e (next (slot-value pattern 'pattern))))
         (when (and (not (null current-repeats-remaining))
                    (not (eq 0 current-repeats-remaining)))
           (setf current-value (ctypecase e
                                 (event (combine-events e (event :dur (/ (event-value e :dur) current-repeats-remaining))))
                                 (number (/ e current-repeats-remaining))
                                 (null nil))))))
    (when (not (null current-repeats-remaining))
      (decf-remaining pattern 'current-repeats-remaining)
      current-value)))

;;; pbeats

(defpattern pbeats (pattern)
  ()
  "pbeats yields the number of beats elapsed since its embedding in the pstream.

Example: (next-n (pbind :dur (pseq '(1 2 3)) :foo (pbeats)) 3) ;=> ((EVENT :DUR 1 :FOO 0) (EVENT :DUR 2 :FOO 1) (EVENT :DUR 3 :FOO 3))

See also: `beats-elapsed', `prun'")

(defmethod next ((pbeats pbeats-pstream))
  (beats-elapsed (parent-pbind pbeats)))

;;; ptime

(defpattern ptime (pattern)
  ((last-beat-checked :state t :initform nil)
   (tempo-at-beat :state t :initform nil)
   (elapsed-time :state t :initform 0))
  "ptime yields the number of seconds elapsed since its embedding in the pstream.

Note: May give inaccurate results if the clock's tempo changes occur more frequently than events in the parent pbind.

Example:

;; (setf (tempo *clock*) 1) ;; 60 BPM
;; (next-n (pbind :dur 1 :time (ptime)) 2)
;; => ((EVENT :DUR 1 :TIME 0) (EVENT :DUR 1 :TIME 1.0))

See also: `pbeats', `beats-elapsed', `prun'")

(defmethod next ((ptime ptime-pstream)) ;; FIX: take into account the previous tempo if it has been changed since the last-beat-checked.
  (with-slots (last-beat-checked tempo-at-beat elapsed-time) ptime
    (with-slots (tempo) *clock*
      (let ((beats-elapsed (beats-elapsed (parent-pbind ptime))))
        (prog1
            (incf elapsed-time (if (null last-beat-checked)
                                   0
                                   (dur-time (- beats-elapsed last-beat-checked) tempo)))
          (setf last-beat-checked beats-elapsed
                tempo-at-beat tempo))))))

;;; psinosc (FIX)

;; (defpattern psinosc (pattern)
;;   ((freq :default 1)
;;    (phase :default 0)
;;    (mul :default 1)
;;    (add :default 0)
;;    (last-beat-tracked :state t :initform nil)
;;    (current-phase :state t :initform 0)))

;; (defun psinosc (&optional (freq 1) (phase 0) (mul 1) (add 0))
;;   (make-instance 'psinosc
;;                  :freq freq
;;                  :phase phase
;;                  :mul mul
;;                  :add add))

;; (defmethod as-pstream ((psinosc psinosc))
;;   (with-slots (freq phase mul add) psinosc
;;     (make-instance 'psinosc-pstream
;;                    :freq freq
;;                    :phase phase
;;                    :mul mul
;;                    :add add)))

;; (defmethod next ((pattern psinosc-pstream))
;;   (with-slots (freq phase mul add last-beat-tracked current-phase) pattern
;;     (progn
;;       (when last-beat-tracked
;;         (incf current-phase (- (slot-value *clock* 'beats) last-beat-tracked)))
;;       (prog1
;;           (+ (next add) (* (next mul) (sin (+ current-phase phase))))
;;         (setf last-beat-tracked (slot-value *clock* 'beats))))))

;;; pindex

(defpattern pindex (pattern)
  (list-pat
   index-pat
   (wrap-p :default nil))
  "pindex uses INDEX-PAT to index into the list returned by LIST-PAT. WRAP-P is whether indexes that are out of range will be wrapped (if t) or will simply return nil (default).

Example:

;; (next-n (pindex (list 99 98 97) (pseq (list 0 1 2 3))) 4)
;; => (99 98 97 NIL)
;;
;; (next-upto-n (pindex (list 99 98 97) (pseries 0 1 6) t))
;; => (99 98 97 99 98 97)

See also: `pswitch'")

(defmethod as-pstream ((pindex pindex))
  (with-slots (list-pat index-pat wrap-p) pindex
    (make-instance 'pindex-pstream
                   :list-pat (pattern-as-pstream list-pat)
                   :index-pat (pattern-as-pstream index-pat)
                   :wrap-p wrap-p)))

(defmethod next ((pindex pindex-pstream))
  (with-slots (list-pat index-pat wrap-p) pindex
    (let ((list (next list-pat))
          (idx (next index-pat)))
      (when idx
        (funcall (if wrap-p 'nth-wrap 'nth) idx list)))))

;;; prun

(defpattern prun (pattern)
  (pattern
   (dur :default 1)
   (dur-history :state t))
  "prun runs a value pattern at a constant rate in the background, independent of when `next' is called on its pstream. PATTERN is the source value pattern, and DUR is the duration in beats of the values yielded by PATTERN.

Example: (next-upto-n (pbind :foo (pseq '(1 2 3 4 5)) :bar (prun (pseq '(4 5 6 7 8)) (pseq '(1 2 0.5 0.5 1))))) ;=> ((EVENT :FOO 1 :BAR 4) (EVENT :FOO 2 :BAR 5) (EVENT :FOO 3 :BAR 5) (EVENT :FOO 4 :BAR 6) (EVENT :FOO 5 :BAR 8))

See also: `beats-elapsed', `pbeats'")

(defmethod as-pstream ((prun prun))
  (with-slots (pattern dur) prun
    (make-instance 'prun-pstream
                   :pattern (as-pstream pattern)
                   :dur (pattern-as-pstream dur)
                   :dur-history nil)))

(defmethod next ((prun prun-pstream))
  (with-slots (pattern dur dur-history) prun
    (flet ((ok ()
             (not (position nil dur-history))))
      (let ((beats (beats-elapsed (parent-pbind prun)))
            (cdur (reduce #'+ dur-history)))
        (loop :while (and (ok) (<= cdur beats))
           :do
           (let ((nxt (next dur)))
             (alexandria:appendf dur-history (list nxt))
             (when nxt
               (incf cdur nxt))))
        (when (ok)
          (let* ((clist (cumulative-list dur-history))
                 (idx (or (index-of-greater-than beats clist) 0)))
            (pstream-nth-future idx pattern)))))))

;;; psym

(defpattern psym (pattern)
  (pattern
   ;; (dict :default nil) ;; FIX: implement this
   (current-pstream :state t :initform nil))
  "Use a pattern of symbols to embed `pdef's. PATTERN is the source pattern that yields symbols naming the pdef to embed.

Example:

;; (pdef :foo (pseq '(1 2 3) 1))
;;
;; (pdef :bar (pseq '(4 5 6) 1))
;;
;; (next-upto-n (psym (pseq '(:foo :bar) 1)))
;;
;; ;=> (1 2 3 4 5 6)

See also: `pdef'" ;; FIX: also ppar, once it's implemented
  )

(defmethod as-pstream ((psym psym))
  (with-slots (pattern) psym
    (make-instance 'psym-pstream
                   :pattern (as-pstream pattern))))

(defmethod next ((psym psym-pstream)) ;; FIX: process lists as parallel patterns when ppar is implemented
  (with-slots (pattern current-pstream) psym
    (let ((n (next current-pstream)))
      (if n
          n
          (let ((next-pdef (next pattern)))
            (unless (null next-pdef)
              (setf current-pstream (as-pstream (pdef next-pdef)))
              (next psym)))))))

;;; pchain

(defpattern pchain (pattern)
  (patterns)
  "Combine multiple patterns into one event stream.

Example:

;; (next-n (pchain (pbind :foo (pseq '(1 2 3))) (pbind :bar (pseq '(7 8 9) 1))) 4)
;;
;; ;=> ((EVENT :FOO 1 :BAR 7) (EVENT :FOO 2 :BAR 8) (EVENT :FOO 3 :BAR 9) NIL)

See also: `pbind''s :inject key"
  (defun pchain (&rest patterns)
    (set-parents
     (make-instance 'pchain
                    :patterns patterns))))

(defmethod as-pstream ((pchain pchain))
  (with-slots (patterns) pchain
    (make-instance 'pchain-pstream
                   :patterns (loop :for pattern :in patterns
                                :collect (as-pstream pattern)))))

(defmethod next ((pchain pchain-pstream))
  (with-slots (patterns) pchain
    (let ((c-event (make-default-event)))
      (loop :for pattern :in patterns
         :do (setf c-event (combine-events c-event (let ((*event* c-event))
                                                     (next pattern)))))
      c-event)))

;;; pdiff

(defpattern pdiff (pattern)
  (pattern)
  "Output the difference between successive outputs of PATTERN.

Example:

;; (next-n (pdiff (pseq '(3 1 4 3) 1)) 4)
;;
;; ;=> (-2 3 -1 NIL)")

(defmethod next ((pdiff pdiff-pstream))
  (with-slots (pattern) pdiff
    (when (null (slot-value pattern 'history))
      (next pattern))
    (alexandria:when-let ((last (pstream-nth -1 pattern))
                          (next (next pattern)))
      (- next last))))

;;; pdrop

(defpattern pdrop (pattern)
  (pattern
   (n :default 0))
  "Drop the first N outputs from PATTERN and yield the rest.

Example:

;; (next-n (pdrop (pseq '(1 2 3 4) 1) 2) 4)
;;
;; ;=> (3 4 NIL NIL)")

(defmethod as-pstream ((pdrop pdrop))
  (with-slots (pattern n) pdrop
    (make-instance 'pdrop-pstream
                   :pattern (as-pstream pattern)
                   :n n)))

(defmethod next ((pdrop pdrop-pstream))
  (with-slots (pattern n) pdrop
    (when (null (slot-value pattern 'history))
      (loop :repeat n
         :do (next pattern)))
    (next pattern)))
