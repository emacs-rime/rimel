;;; rimel-regexp-avy.el --- Rime-aware Avy character jumps  -*- lexical-binding: t; -*-

;; Author: jixiuf
;; URL: https://github.com/jixiuf/rimel
;; Version: 0.1.2
;; Package-Requires: ((emacs "29.4") (rimel-regexp) (liberime "0.0.11"))
;; Keywords: convenience, matching

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Optional companion to `rimel-regexp': expands Rime codes in Avy character
;; jumps, so typing `ni' can jump to `你' or another visible candidate.  Avy
;; is a soft dependency, loaded only when `rimel-regexp-avy-mode' is enabled.
;;
;;   (require 'rimel-regexp-avy)
;;   (rimel-regexp-avy-mode 1)

;;; Code:

(require 'rimel-regexp)

(declare-function avy-jump "avy" (regexp &rest props))
(declare-function avy-with "avy" (cmd &rest body))
(declare-function avy-process "avy" (candidates &optional overlay-fn))
(declare-function avy--read-candidates "avy" (finder))

;; Avy command symbols are passed to `avy-with' and read as variables
;; before Avy is loaded; declare them so the byte compiler does not
;; complain about free variables.  They are bound by Avy at runtime.
(defvar avy-goto-char)
(defvar avy-goto-char-in-line)
(defvar avy-goto-char-2)
(defvar avy-goto-char-timer)
(defvar avy-all-windows)
(defvar avy--old-cands)

(defun rimel-regexp-avy--load ()
  "Load Avy for `rimel-regexp-avy-mode' commands."
  (unless (featurep 'avy)
    (require 'avy)))

(defun rimel-regexp-avy--input-regexp (input)
  "Build an Avy regexp from INPUT."
  (rimel-regexp-build-regexp-string input t))

;;;###autoload
(defun rimel-regexp-avy-goto-char (char &optional arg)
  "Jump to CHAR or a Rime candidate for its code.

ARG reverses the value of `avy-all-windows'.  Requires Avy."
  (interactive (list (read-char "char: " t)
                     current-prefix-arg))
  (rimel-regexp-avy--load)
  (avy-with avy-goto-char
    (avy-jump
     (rimel-regexp-avy--input-regexp
      (string (if (= char 13) ?\n char)))
     :window-flip arg)))

;;;###autoload
(defun rimel-regexp-avy-goto-char-in-line (char)
  "Jump within the current line to CHAR or a Rime candidate for its code.

Requires Avy."
  (interactive (list (read-char "char: " t)))
  (rimel-regexp-avy--load)
  (avy-with avy-goto-char
    (avy-jump
     (rimel-regexp-avy--input-regexp (string char))
     :beg (line-beginning-position)
     :end (line-end-position))))

;;;###autoload
(defun rimel-regexp-avy-goto-char-2
    (char1 char2 &optional arg beg end)
  "Jump to CHAR1 CHAR2 or a Rime candidate for their combined code.

ARG reverses `avy-all-windows'.  BEG and END limit the search range.
Requires Avy."
  (interactive (list (read-char "char 1: " t)
                     (read-char "char 2: " t)
                     current-prefix-arg))
  (rimel-regexp-avy--load)
  (avy-with avy-goto-char-2
    (avy-jump
     (rimel-regexp-avy--input-regexp
      (string (if (= char1 13) ?\n char1)
              (if (= char2 13) ?\n char2)))
     :window-flip arg
     :beg beg
     :end end)))

;;;###autoload
(defun rimel-regexp-avy-goto-char-timer (&optional arg)
  "Read a Rime code and jump to one of its visible candidates.

ARG reverses the value of `avy-all-windows'.  Requires Avy."
  (interactive "P")
  (rimel-regexp-avy--load)
  (let ((avy-all-windows (if arg
                             (not avy-all-windows)
                           avy-all-windows)))
    (avy-with avy-goto-char-timer
      (setq avy--old-cands
            (avy--read-candidates #'rimel-regexp-avy--input-regexp))
      (avy-process avy--old-cands))))

(defvar rimel-regexp-avy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap avy-goto-char]
                #'rimel-regexp-avy-goto-char)
    (define-key map [remap avy-goto-char-in-line]
                #'rimel-regexp-avy-goto-char-in-line)
    (define-key map [remap avy-goto-char-2]
                #'rimel-regexp-avy-goto-char-2)
    (define-key map [remap avy-goto-char-timer]
                #'rimel-regexp-avy-goto-char-timer)
    map)
  "Keymap for `rimel-regexp-avy-mode'.")

;;;###autoload
(define-minor-mode rimel-regexp-avy-mode
  "Use Rime codes with Avy character commands.

Avy is an optional dependency; enabling this mode loads it.  The ordinary
Avy commands (`avy-goto-char', `avy-goto-char-in-line', `avy-goto-char-2',
`avy-goto-char-timer') are remapped to their Rime-aware variants."
  :global t
  :group 'rimel-regexp
  :keymap rimel-regexp-avy-mode-map
  (when rimel-regexp-avy-mode
    (rimel-regexp-avy--load)))

(provide 'rimel-regexp-avy)

;;; rimel-regexp-avy.el ends here
