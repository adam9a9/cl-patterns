(defpackage #:cl-patterns/tests
  (:use :cl
        :cl-patterns
        :fiveam))

(in-package #:cl-patterns/tests)

(def-suite cl-patterns-tests
    :description "cl-patterns tests suite.")

(in-suite cl-patterns-tests)

;;; utility

(test round-up
  "Test the `round-up' function"
  (is (= 2.04
         (cl-patterns::round-up 2.03 0.02))
      "round-up gives correct results for positive numbers")
  (is (= -2.02
         (cl-patterns::round-up -2.03 0.02))
      "round-up gives correct results for negative numbers"))

;;; patterns

(test embedding
  "Test embedding patterns in patterns"
  (is (equal
       (list 0 1 2 3 4 5 nil)
       (next-n (pseq (list 0 (pseq (list 1 (pseq (list 2 3) 1) 4) 1) 5) 1) 7))
      "Stacked pseqs give correct results"))

(test remaining-key
  "Test the remaining key in patterns and pstreams"
  (is (= 5
         (length (next-upto-n (pbind :remaining 5 :foo 1))))
      ":remaining key functions properly when specified in pbind")
  (is (= 5
         (length (next-upto-n (let ((pat (pseq '(1 2 3) :inf)))
                                (setf (slot-value pat 'cl-patterns::remaining) 5)
                                pat))))
      "remaining slot functions properly when setf"))

(test number-key
  "Test the number key in patterns and pstreams"
  (is (equal (list 0 1 2 3 4 5 6 7)
             (let ((pstr (as-pstream (pbind :foo 1))))
               (loop :for i :upto 7
                  :collect (slot-value pstr 'cl-patterns::number)
                  :do (next pstr))))
      "number slot functions properly for patterns")
  (is (equal (list 0 1 2 3 4 5 6 7)
             (let ((pstr (as-pstream (pbind :foo (pk :number)))))
               (mapcar (lambda (e) (event-value e :foo)) (next-upto-n pstr 8))))
      "pstream's number can be accessed by pk"))

(test pbind
  "Test pbind functionality"
  (is (equal (list :foo :bar :baz)
             (cl-patterns::keys (next (pbind :foo 1 :bar 2 :baz (pseq '(1 2 3) 1)))))
      "pbind returns events that only have the keys specified")
  (is (= 3
         (length (next-upto-n (pbind :foo 1 :bar 2 :baz (pseq '(1 2 3) 1)))))
      "pbind returns the correct number of events")
  (is (= 77
         (let ((*max-pattern-yield-length* 77))
           (length (next-upto-n (pbind :foo 1 :bar 2)))))
      "pbind returns the correct number of events"))

(test parent ;; FIX: make sure all patterns are given parents
  "Test whether patterns have the correct parent information"
  (is-true (let ((pb (pbind :foo (pseq '(1 2 3)))))
             (eq (cl-patterns::parent-pattern (getf (slot-value pb 'cl-patterns::pairs) :foo))
                 pb))
           "pbind subpatterns have correct parents for pseq")
  (is-true (let ((pb (pbind :foo (pfunc (lambda () (random 5))))))
             (eq (cl-patterns::parent-pattern (getf (slot-value pb 'cl-patterns::pairs) :foo))
                 pb))
           "pbind subpatterns have correct parents for pfunc"))

;; parent-pbind (FIX)

(test t-pstream
  "Test functionality of non-patterns as pstreams"
  (is (= 1
         (length (next-upto-n 69)))
      "Numbers coerced to pstreams only return one value")
  (is (= 1
         (length (next-upto-n (lambda () (random 420)))))
      "Functions coerced to pstreams only return one value")
  (is (= 3
         (length (next-upto-n (pseq '(1 2 3) 1))))
      "Patterns return the correct number of values when their parameters are values coerced to pstreams")
  (is (= 5
         (let ((*max-pattern-yield-length* 5))
           (length (next-upto-n (pfunc (lambda () (random 64)))))))
      "A function used as an argument for pfunc returns the correct number of values"))

(test remainingp ;; FIX: test this for all patterns that use it.
  "Test the behavior of the `remainingp' function"
  (is (equal (list 1 2 3)
             (next-upto-n (pseq '(1 2 3) 1)))
      "pseq returns the correct number of results")
  (is (= 64
         (let ((*max-pattern-yield-length* 64))
           (length (next-upto-n (pseq '(1 2 3) :inf)))))
      "pseq returns the correct number of results when `next-upto-n' is called with its REPEATS as :inf")
  (is (= 64
         (let ((*max-pattern-yield-length* 64))
           (length (next-upto-n (pseq '(1 2 3) (pseq '(1) :inf))))))
      "pseq returns the correct number of results when its REPEATS is a pattern")
  (is (= 3
         (let ((*max-pattern-yield-length* 64))
           (length (next-upto-n (pseq '(1 2 3) (pseq '(1 0) :inf))))))
      "pseq returns the correct number of results when its REPEATS is a pattern"))

(test pseq
  "Test pseq"
  (is (null
       (next-upto-n (pseq '(1 2 3) 0)))
      "pseq returns 0 results when REPEATS is 0")
  (is (equal
       (list 1 2 3 1 2 3 nil nil)
       (next-n (pseq (list 1 2 3) 2) 8))
      "pseq returns correct results when REPEATS is provided")
  (is (equal
       (list 1 2 3 1 2 3 nil)
       (next-n (pseq (lambda () (list 1 2 3)) 2) 7))
      "pseq returns correct results when LIST is a function")
  (is (string= "" ;; FIX: this should be done for other patterns as well.
               (let* ((s (make-string-output-stream))
                      (*standard-output* s))
                 (as-pstream (pseq '(1 2 3) (lambda () (print 3))))
                 (get-output-stream-string s)))
      "pseq's REPEATS argument is not evaluated until `next' is called")
  (is (equal (list 1 2 3 1 2 3 1 2 3 1 2 3 NIL) ;; FIX: do this for other patterns as well.
             (let* ((foo 1)
                    (bar (as-pstream (pseq '(1 2 3) (pfunc (lambda () foo))))))
               (next-n bar 10) ;=> (1 2 3 1 2 3 1 2 3 1)
               (setf foo 0)
               (next-n bar 3) ;=> (2 3 NIL)
               (slot-value bar 'cl-patterns::history) ;=> (1 2 3 1 2 3 1 2 3 1 2 3 NIL)
               ))
      "pseq returns correct results when its REPEATS is used as a gate"))

(test pser
  "Test pser"
  (is (equal
       (list 1 2 3 nil nil nil)
       (next-n (pser (list 1 2 3) 3) 6))
      "pser correctly returns three results when its LENGTH is specified")
  (is (equal
       (list 1 2 3 1 2 1 1 2 3 1 2 1)
       (next-upto-n (pser '(1 2 3) (pseq '(3 2 1 3 2 1 0) :inf))))
      "pser returns the correct results when its LENGTH is a pattern"))

(test pk
  "Test pk"
  (is (equal
       (list 3)
       (gete (next-n (pbind :foo (pseq '(3) 1) :bar (pk :foo)) 1) :bar))
      "pk returns correct results")
  (is (equal
       (list 1 2 3 nil)
       (gete (next-n (pbind :foo (pseq '(1 2 3) 1) :bar (pk :foo)) 4) :bar))
      "pk returns correct results")
  (is (equal
       (list 2 2 2 nil)
       (gete (next-n (pbind :foo (pseq '(1 2 3) 1) :bar (pk :baz 2)) 4) :bar))
      "pk returns correct results when a default is provided and its KEY is not in the source"))

(test prand
  "Test prand"
  (is (not (member nil (mapcar (lambda (x) (member x '(1 2 3))) (next-upto-n (prand '(1 2 3) :inf)))))
      "prand does not produce any values other than the ones provided")
  (is (= 3
         (length (next-upto-n (prand '(1 2 3) 3))))
      "prand returns the correct number of results"))

;; pxrand (FIX)

;; pwxrand (FIX)

(test pfunc
  "Test pfunc"
  (is (= 9
         (length (next-upto-n (pfunc (lambda () (random 9))) 9)))
      "pfunc returns the correct number of results")
  (is (= 4
         (next (pfunc (lambda () (+ 2 2)))))
      "pfunc returns correct results"))

(test pr
  "Test pr"
  (is (equal (list 1 1 2 2 3 3 nil)
             (next-n (pr (pseq '(1 2 3) 1) 2) 7))
      "pr returns correct results when its REPEATS is a number")
  (is (equal (list 1 1 2 2 2 3 3 nil)
             (next-n (pr (pseq '(1 2 3) 1) (lambda (e) (if (= e 2) 3 2))) 8))
      "pr returns correct results when its REPEATS is a function")
  (is (equal (list 1 1 2 2 3 3 nil nil)
             (next-n (pr (pseq '(1 2 3) 1) (lambda () 2)) 8))
      "pr returns correct results when its REPEATS is a function that doesn't accept arguments")
  (is (equal (list 3 3 3 3 3 3 3 3 3 3)
             (next-n (pr 3) 10))
      "pr returns correct results when its REPEATS is :inf")
  (is (equal (list 1 1 2 nil)
             (next-n (pr (pseq '(1 2 3) 1) (pseq '(2 1 0) 1)) 4))
      "pr skips elements when REPEATS is 0"))

;; pdef (FIX)

(test plazy
  "Test plazy"
  (is (equal (list 1 2 3 1 2 3 1)
             (next-n (plazy (lambda () (pseq '(1 2 3)))) 7))
      "plazy returns correct results")
  (is (null (next-upto-n (plazy (lambda () nil))))
      "plazy returns correct results when its function returns nil"))

(test plazyn
  "Test plazyn"
  (is (null (next-upto-n (plazyn (lambda () (pseq '(1 2 3))) 0)))
      "plazyn returns 0 results if REPEATS is 0")
  (is (equal '(1 2 3 1 2 3)
             (next-upto-n (plazyn (lambda () (pseq '(1 2 3) 1)) 2)))
      "plazyn returns correct results"))

;; pcycles (FIX)

;; pshift (FIX)

(test pn
  "Test pn"
  (is (equal
       (list 1 nil nil)
       (next-n (pn 1 1) 3))
      "pn returns correct results when its source pattern is a value")
  (is (equal
       (list 3 3 3 nil)
       (next-n (pn 3 3) 4))
      "pn returns correct results when its source pattern is a value")
  (is (equal
       (list 1 2 3 1 2 3 1 2 3 nil nil nil)
       (next-n (pn (pseq '(1 2 3) 1) 3) 12))
      "pn returns correct results when its source pattern is a pattern")
  (is (null (next (pn (pseq '(1 2 3) 0) 1)))
      "pn does not hang when its source pattern returns no values"))

(test pshuf
  "Test pshuf"
  (is (= 5
         (length (next-upto-n (pshuf '(1 2 3 4 5) 1) 32)))
      "pshuf returns the correct number of results when REPEATS is specified")
  (is (= 10
         (length (next-upto-n (pshuf '(1 2 3 4 5) 2) 32)))
      "pshuf returns the correct number of results when REPEATS is specified")
  (is (equal
       (list 1 2 3 4 5)
       (next-upto-n (pseq '(1 2 3 4 5) 1))) ;; this list must be quoted and must be the same as one of the ones used in the pshuf test above.
      "pshuf does not destructively modify its input list"))

(test pwhite
  "Test pwhite"
  (is (block :pwhite-test
        (loop :for i :in (next-upto-n (pwhite 0 1 :inf))
           :if (not (integerp i))
           :do (return-from :pwhite-test nil))
        t)
      "pwhite returns integers when its LO and HI are integers")
  (is (block :pwhite-test
        (loop :for i :in (next-upto-n (pwhite 0.0 1 :inf))
           :if (not (floatp i))
           :do (return-from :pwhite-test nil))
        t)
      "pwhite returns floats when its LO is a float")
  (is (block :pwhite-test
        (loop :for i :in (next-upto-n (pwhite 0 1.0 :inf))
           :if (not (floatp i))
           :do (return-from :pwhite-test nil))
        t)
      "pwhite returns floats when its HI is a float")
  (is (block :pwhite-test
        (loop :for i :in (next-upto-n (pwhite -10 -1 :inf))
           :if (or (not (>= i -10))
                   (not (<= i -1)))
           :do (return-from :pwhite-test nil))
        t)
      "pwhite returns correct results")
  (is (= 7
         (length (next-upto-n (pwhite 0 1 7))))
      "pwhite returns the correct number of results"))

;; pbrown (FIX)

;; pexprand (FIX)

(test pseries
  "Test pseries"
  (is (equal (alexandria:iota 64)
             (next-n (pseries 0 1 :inf) 64))
      "pseries returns correct results")
  (is (equal (list 0 1 1 0 -1 -2)
             (next-upto-n (pseries 0 (pseq '(1 0 -1 -1 -1) 1) :inf)))
      "pseries returns correct results when its STEP is a pattern"))

(test pgeom
  "Test pgeom"
  (is (equal (list 1 2 4 8 16 32 64 128)
             (next-n (pgeom 1 2 :inf) 8))
      "pgeom returns correct results")
  (is (equal (list 1 1 2 6 3.0 2.1)
             (next-upto-n (pgeom 1 (pseq '(1 2 3 0.5 0.7) 1) :inf)))
      "pgeom returns correct results when its GROW is a pattern"))

;; ptrace (FIX)

(test ppatlace
  "Test ppatlace"
  (is (equal (list 1 4 2 5 3 6 7 8 nil)
             (next-n (ppatlace (list (pseq (list 1 2 3) 1) (pseq (list 4 5 6 7 8) 1)) :inf) 9))
      "ppatlace returns correct results when its REPEATS is inf")
  (is (equal (list 1 4 2 5 nil nil nil nil nil)
             (next-n (ppatlace (list (pseq (list 1 2 3)) (pseq (list 4 5 6 7 8))) 2) 9))
      "ppatlace returns correct results when its REPEATS is a number"))

(test pnary
  "Test pnary"
  (is (equal (list 3 4 5)
             (next-upto-n (pnary #'+ (pseq '(1 2 3) 1) 2)))
      "pnary returns correct results with pattern and number as arguments")
  (is (equal (list 4 5 6)
             (next-upto-n (pnary #'+ (pseq '(1 2 3) 1) 2 1)))
      "pnary returns correct results with pattern and two numbers as arguments")
  (is (equal (list 3 0)
             (next-upto-n (pnary (pseq (list #'+ #'-)) 2 (pseq '(1 2) 1))))
      "pnary returns correct results when its operator is a pattern"))

(test pslide
  "Test pslide"
  (is (equal (next-n (pslide (list 1 2 3 4 5) :inf 3 1 0) 13)
             (list 1 2 3 2 3 4 3 4 5 4 5 1 5)))
  (is (equal (next-n (pslide (list 1 2 3 4 5) 2 3 1 0) 13)
             (list 1 2 3 2 3 4 nil nil nil nil nil nil nil)))
  (is (equal (next-n (pslide (list 1 2 3 4 5) :inf 3 1 0 nil) 13)
             (list 1 2 3 2 3 4 3 4 5 4 5 nil 5)))
  (is (equal (next-n (pslide (list 1 2 3 4 5) :inf 3 -1 0 nil) 13)
             (list 1 2 3 nil 1 2 nil nil 1 nil nil nil nil)))
  (is (equal (next-n (pslide (list 1 2 3 4 5) :inf 3 -1 0) 13)
             (list 1 2 3 5 1 2 4 5 1 3 4 5 2)))
  (is (equal (next-n (pslide (list 1 2 3 4 5) :inf 3 -1 1) 13)
             (list 2 3 4 1 2 3 5 1 2 4 5 1 3))))

(test phistory
  "Test phistory"
  (is (equal (list 0 nil 1)
             (next-n (phistory (pseries) (pseq '(0 2 1))) 3))
      "phistory returns correct results, including when outputs that haven't occurred yet are accessed"))

;; pfuture (FIX)

(test pscratch
  "Test pscratch"
  (is (equal (list 1 2 3 0 1 2 3 0 1 2 3 0)
             (next-n (pscratch (pseries 0 1) (pseq (list 1 1 1 -3) :inf)) 12))
      "pscratch returns correct results when using patterns as source and step"))

(test pif
  "Test pif"
  (is (equal (list 1 2 4 5 3 nil 6)
             (next-n (pif (pseq (list t t nil nil t t nil) 1)
                          (pseq (list 1 2 3) 1)
                          (pseq (list 4 5 6) 1))
                     7))
      "pif returns correct results")
  (is (equal (list 1 2 3 nil 4)
             (next-n (pif (pseq '(t t nil nil nil))
                          (pseq '(1 2))
                          (pseq '(3 nil 4)))
                     5))
      "pif returns correct results"))

;; ptracker (FIX)

;; parp (FIX)

(test pfin
  "Test pfin"
  (is (= 3
         (length (next-upto-n (pfin (pseq '(1 2 3) :inf) 3))))
      "pfin correctly limits its source pattern when COUNT is a number")
  (is (= 3
         (length (next-upto-n (pfin (pseq '(1 2 3) :inf) (pseq '(3))))))
      "pfin correctly limits its source pattern when COUNT is a pattern"))

(test pfindur
  "Test pfindur"
  (is (= 5
         (reduce #'+ (gete (next-upto-n (pfindur (pbind :dur (pwhite 0.0 1.0)) 5)) :dur)))
      "pfindur patterns have a correct total duration"))

(test pstutter
  "Test pstutter"
  (is (equal (list 1 1 1 2 2 2 3 3 3)
             (next-upto-n (pstutter 3 (pseq '(1 2 3) 1))))
      "pstutter returns correct results")
  (is (equal (list 2 3 3)
             (next-upto-n (pstutter (pseq '(0 1 2) 1) (pseq '(1 2 3) 1))))
      "pstutter returns correct results when its N is a pattern, and when N is 0"))

(test pdurstutter
  "Test pdurstutter"
  (is (equal (list 2 3/2 3/2)
             (next-upto-n (pdurstutter (pseq '(1 2 3) 1) (pseq '(0 1 2) 1))))
      "pdurstutter returns correct results for value patterns")
  (is (equal (list 1 1/2 1/2) ;; FIX: correct this when events can be compared
             (gete (next-upto-n (pdurstutter (pbind :foo (pseries)) (pseq '(0 1 2) 1))) :dur))
      "pdurstutter returns correct results for event patterns when its N is a pattern, and when N is 0"))

(test pbeats
  "Test pbeats"
  (is (equal (list 0.0 0.25 0.5 0.75 1.0 1.25)
             (let ((pstr (as-pstream (pbind :foo (pbeats) :dur 0.25))))
               (loop :for i :upto 5
                  :collect (event-value (next pstr) :foo))))
      "pbeats returns correct results"))

;; psinosc (FIX)

(test pindex
  "Test pindex"
  (is (equal
       (list 3 2 1 3 2 1 nil)
       (next-n (pindex (list 3 2 1 0) (pseq (list 0 1 2) 1) 2) 7))
      "pindex returns correct results")
  (is (equal (list 99 98 97 99 99 98 97 99 nil)
             (next-n (pindex (list 99 98 97) (pseries 0 1 4) 2 t) 9))
      "pindex returns correct results when its WRAP-P is t"))

;; pbjorklund (FIX)

(test prun
  "Test prun"
  (is-true (every #'event-equal
                  (list (event :foo 1 :bar 4) (event :foo 2 :bar 5) (event :foo 3 :bar 5) (event :foo 4 :bar 6) (event :foo 5 :bar 8))
                  (next-upto-n (pbind :foo (pseq '(1 2 3 4 5) 1) :bar (prun (pseq (list 4 5 6 7 8) 1) (pseq (list 1 2 0.5 0.5 1) 1))))) ;; FIX: if the list is quoted instead of generated, it creates garbage..
           "prun returns correct results"))

;;; conversions (FIX: add more)

(test conversions
  "Test unit conversion functions"
  (is (=
       0.5
       (db-amp (amp-db 0.5)))
      "db-to-amp conversion is equivalent to amp-to-db conversion"))

;;; events (FIX: add more)

(test events
  "Test events"
  (is (=
       1
       (event-value (event :dur 0 :sustain 1) :sustain))
      "event returns the correct sustain when sustain is provided and dur is 0")
  (is (=
       0.8
       (event-value (event) :sustain))
      "event returns the correct default value for sustain")
  (is (=
       0.5
       (event-value (event :dur 0 :legato 0.5) :legato))
      "event returns the correct legato when legato is provided and dur is 0")
  (is (=
       0.8
       (event-value (event) :legato))
      "event returns the correct default value for legato")
  (is (=
       1
       (event-value (event) :dur))
      "event returns the correct default value for dur")
  (is (eq
       :default
       (event-value (event) :instrument))
      "event returns the correct default value for instrument")
  (is (= (amp-db 0.125)
         (event-value (event :amp 0.125) :db))
      "event correctly converts amp to db")
  (is (= (db-amp -7)
         (event-value (event :db -7) :amp))
      "event correctly converts db to amp"))

;;; clock (FIX)

;;; tsubseq

;; (let* ((pb (pbind :dur 1/3)))
;;   (is (= 2/3 (reduce #'+ (gete (tsubseq pb 1 1.5) :dur))))
;;   (is (= 2/3 (reduce #'+ (gete (tsubseq (as-pstream pb) 1 1.5) :dur))))
;;   (is (= 2/3 (reduce #'+ (gete (tsubseq (next-n pb 15) 1 1.5) :dur)))))

;; (let* ((pb (pbind :dur 1/3)))
;;   (is (= 0.25 (reduce #'+ (gete (tsubseq* pb 1.25 1.5) :dur))))
;;   (is (= 0.25 (reduce #'+ (gete (tsubseq* (as-pstream pb) 1.25 1.5) :dur))))
;;   (is (= 0.25 (reduce #'+ (gete (tsubseq* (next-n pb 15) 1.25 1.5) :dur)))))
