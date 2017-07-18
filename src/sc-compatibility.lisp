;;; sc-compatibility.lisp - SuperCollider-compatible versions of cl-patterns patterns

(in-package :cl-patterns/sc-compat)

;;; punop

(defun punop (operator pattern)
  (pnary operator pattern))

;;; pbinop

(defun pbinop (operator pattern-a pattern-b)
  (pnary operator pattern-a pattern-b))

;;; pnaryop

(defun pnaryop (operator pattern arglist)
  (apply #'pnary operator pattern arglist))

;;; ptime

(defun ptime ()
  (cl-patterns::pbeats))