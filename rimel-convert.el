;;; rimel-convert.el --- Convert code string at point via rime -*- lexical-binding: t; -*-

;; Author: jixiuf
;; URL: https://github.com/jixiuf/rimel
;; Version: 0.1.1
;; Keywords: convenience, Chinese, input-method, rime

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Convert the code string before point (e.g. pinyin) to Chinese via
;; rime, and toggle punctuation at point between half-width and
;; full-width.  Autoloaded on demand through the command autoloads; it
;; drives rime directly through `liberime-process-key' and the
;; composition loop of rimel.el, so the composition never consults
;; `rimel-disable-predicates'.

;;; Code:

(require 'cl-lib)
(require 'rimel)

;;;###autoload
(defcustom rimel-convert-valid-chars "a-z'"
  "Characters allowed in a code string, as regexp character-class contents.
Used by `rimel-convert-string-at-point' to find the code string
before point.  The default covers pinyin (including the apostrophe
syllable separator) and wubi."
  :type 'string
  :group 'rimel)

;;; Punctuation conversion

(defcustom rimel-punctuation-dict
  '(("'" "‘" "’")
    ("\"" "“" "”")
    ("_" "——")
    ("^" "…")
    ("]" "】")
    ("[" "【")
    ("@" "◎")
    ("?" "？")
    (">" "》")
    ("=" "＝")
    ("<" "《")
    (";" "；")
    (":" "：")
    ("/" "、")
    ("." "。")
    ("-" "－")
    ("," "，")
    ("+" "＋")
    ("*" "×")
    (")" "）")
    ("(" "（")
    ("&" "※")
    ("%" "％")
    ("$" "￥")
    ("#" "＃")
    ("!" "！")
    ("`" "・")
    ("~" "～")
    ("}" "』")
    ("|" "÷")
    ("{" "『"))
  "Punctuation table: each row is (HALF-WIDTH FULL-WIDTH...).
Rows with two full-width strings represent paired punctuation
\(open and close forms), see `rimel-punctuation-translate'."
  :type '(repeat (cons (string :tag "Half-width")
                       (choice :tag "Full-width"
                               (list :tag "Single" string)
                               (list :tag "Paired" (string :tag "Open")
                                     (string :tag "Close")))))
  :group 'rimel)

(defvar-local rimel--punctuation-pair-status '(("\"" nil) ("'" nil))
  "Toggle state of paired punctuation, used by `rimel-punctuation-translate'.

Buffer-local so quote alternation does not leak across buffers.
Entries are created on demand for custom paired rows in
`rimel-punctuation-dict'.")

(defun rimel--punctuation-position (string)
  "Return the position of STRING in its `rimel-punctuation-dict' row.
Position 0 means half-width, greater means full-width.  Return nil
when STRING is not a known punctuation."
  (let ((row (cl-some (lambda (x) (when (member string x) x))
                      rimel-punctuation-dict)))
    (cl-position string row :test #'equal)))

(defun rimel--punctuation-proper-full (row)
  "Return the proper full-width punctuation from dict ROW.
For paired rows (e.g. quotes), alternate between the open and close
forms using `rimel--punctuation-pair-status'.  The alist is rebuilt
rather than mutated in place, so custom rows missing from the status
list work and the buffer-local value never shares structure with the
default."
  (let* ((str (car row))
         (punc (cdr row))
         (entry (assoc str rimel--punctuation-pair-status))
         ;; Missing entries (custom paired rows) start open, matching
         ;; the truthy (nil) initial state of built-in entries.
         (switch-p (if entry (cdr entry) t)))
    (if (= (safe-length punc) 1)
        (car punc)
      (setq rimel--punctuation-pair-status
            (cons (cons str (not switch-p))
                  (assoc-delete-all str rimel--punctuation-pair-status)))
      (if switch-p
          (car punc)
        (nth 1 punc)))))

(defun rimel--char-before-string (num)
  "Return the character NUM positions before point as a string, or nil."
  (let ((pos (- (point) num)))
    (when (and (> pos 0) (char-before pos))
      (char-to-string (char-before pos)))))

(defun rimel--char-after-string (num)
  "Return the character NUM positions after point as a string, or nil."
  (let ((pos (+ (point) num)))
    (when (char-after pos)
      (char-to-string (char-after pos)))))

(defun rimel--count-puncts-backward (puncs)
  "Return the number of consecutive characters from PUNCS before point."
  (let ((n 0))
    (while (member (rimel--char-before-string n) puncs)
      (cl-incf n))
    n))

(defun rimel--count-puncts-forward (puncs)
  "Return the number of consecutive characters from PUNCS after point."
  (let ((n 0))
    (while (member (rimel--char-after-string n) puncs)
      (cl-incf n))
    n))

(defun rimel--translate-span (span style)
  "Translate SPAN between half-width and full-width per STYLE.
STYLE is `full-width' or `half-width'.  Each character is looked up
in `rimel-punctuation-dict', using the first matching row only, so a
custom row overriding a built-in entry is not applied twice."
  (let ((result nil))
    (dolist (punct (split-string span ""))
      (if-let* ((row (cl-some (lambda (r) (when (member punct r) r))
                              rimel-punctuation-dict))
                (pos (cl-position punct row :test #'equal)))
          (push (if (eq style 'full-width)
                    (if (= pos 0)
                        (rimel--punctuation-proper-full row)
                      punct)
                  (if (= pos 0) punct (car row)))
                result)
        ;; Non-punctuation characters pass through unchanged.
        (push punct result)))
    (string-join (reverse result))))

;;;###autoload
(defun rimel-punctuation-translate (&optional style)
  "Convert punctuation around point between half-width and full-width.
With punctuation on both sides of point, convert symmetrically (the
same number before and after point) so paired punctuation converts
together.  With no punctuation after point, convert only one character
before point; repeat the command to convert further characters.
STYLE is `full-width' or `half-width'; when nil, ask interactively."
  (interactive)
  (let* ((puncs (flatten-tree rimel-punctuation-dict))
         (style (or style
                    (intern (completing-read
                             "Convert punctuation at point to: "
                             '("full-width" "half-width")))))
         (before (rimel--count-puncts-backward puncs))
         (after (rimel--count-puncts-forward puncs))
         (n (if (> after 0) (min before after) (min before 1)))
         (n-right (min n after)))
    (when (> n 0)
      (let ((span (buffer-substring (- (point) n) (+ (point) n-right))))
        (delete-char n-right)
        (delete-char (- 0 n))
        (insert (rimel--translate-span span style))
        (backward-char n-right)))
    (when (and (called-interactively-p 'interactive) (= n 0))
      (message "Rimel: no punctuation at point to convert."))))

;;;###autoload
(defun rimel-punctuation-translate-at-point ()
  "Toggle the punctuation before point between half-width and full-width.
Return non-nil when a conversion happened."
  (interactive)
  (let ((pos (rimel--punctuation-position
              (or (rimel--char-before-string 0) ""))))
    (cond
     ((eq pos 0) (rimel-punctuation-translate 'full-width) t)
     ((numberp pos) (rimel-punctuation-translate 'half-width) t)
     (t nil))))

;;; Convert string at point

(defun rimel--activate-rimel ()
  "Activate the rimel input method unless it is already active."
  (unless (equal input-method-function #'rimel-input-method)
    (activate-input-method "rimel")))

(defun rimel--find-entered-at-point ()
  "Find a valid code string at point, from the region or the line prefix.
Return a list (ENTERED DELETE-COUNT): ENTERED is the code string with
spaces removed, DELETE-COUNT the number of buffer characters it spans.
Return nil when no code string is found."
  (let* ((case-fold-search nil)
         (regexp (format "[%s]+ *$" rimel-convert-valid-chars))
         (string (if mark-active
                     (buffer-substring-no-properties
                      (region-beginning) (region-end))
                   (buffer-substring (point) (line-beginning-position)))))
    (when (string-match regexp string)
      (let* ((entered (match-string 0 string))
             ;; A leading quote or hyphen is usually a string delimiter
             ;; in programming modes; strip it from the match.
             (entered (replace-regexp-in-string "^[-']" "" entered))
             (delete-count (length entered))
             (entered (replace-regexp-in-string " +" "" entered)))
        (when (> (length entered) 0)
          (list entered delete-count))))))

(defun rimel--delete-region-or-chars (&optional num)
  "Delete the matched code span, or NUM characters before point.
When the region is active, delete only its trailing NUM characters
\(the span `rimel--find-entered-at-point' matched) and deactivate the
mark, so non-code prefix text in the region is preserved.  Otherwise
Return the position where converted text should be inserted (the
start of the deleted span)."
  (if mark-active
      (let ((insert-pos (- (region-end) (or num 0))))
        (when (and (numberp num) (> num 0))
          (delete-region insert-pos (region-end)))
        (deactivate-mark)
        insert-pos)
    (when (and (numberp num) (> num 0))
      (delete-char (- 0 num))
      (point))))

(defun rimel--feed-entered-into-rime (entered)
  "Feed ENTERED into rime and run the interactive composition loop.
Return the committed characters as a list, or nil."
  (liberime-clear-composition)
  (let ((commit nil))
    (cl-dolist (ch (string-to-list entered))
      (liberime-process-key ch)
      (when (setq commit (rimel--get-commit))
        (cl-return)))
    (if commit
        (string-to-list commit)
      (rimel--composition-loop))))

(defun rimel--entered-convertible-p (entered)
  "Return non-nil when rime has candidates for ENTERED."
  (liberime-clear-composition)
  (dolist (ch (string-to-list entered))
    (liberime-process-key ch))
  (let ((candidates (alist-get 'candidates
                               (alist-get 'menu (liberime-get-context)))))
    (liberime-clear-composition)
    (and candidates (> (length candidates) 0))))

(defun rimel--full-width-punctuation-in-region (beg end)
  "Convert half-width punctuation in [BEG END) to full width.
Paired punctuation (e.g. quotes) alternates between open and close
forms via `rimel--punctuation-proper-full'.  Full-width punctuation
is left unchanged."
  (save-excursion
    (goto-char beg)
    (let ((regexp (regexp-opt (mapcar #'car rimel-punctuation-dict))))
      (while (re-search-forward regexp end t)
        (let* ((punct (match-string 0))
               (full (rimel--punctuation-proper-full
                      (assoc punct rimel-punctuation-dict))))
          (replace-match full t t)
          ;; Keep the search bound in sync with the length change.
          (setq end (+ end (- (length full) (length punct)))))))))

(defun rimel--convert-region-segments ()
  "Convert each rime-convertible code segment in the active region.
Segments are converted one after another; segments without rime
candidates (e.g. non-pinyin words) are skipped unchanged.  Half-width
punctuation in the region is converted to full width afterwards.  Point
ends up right after the last converted segment.  Return non-nil when at
least one segment was converted."
  (let* ((beg (region-beginning))
         (end (region-end))
         (regexp (format "[%s]+" rimel-convert-valid-chars))
         (count 0)
         (last-insert-pos nil))
    (goto-char beg)
    (catch 'done
      (while t
        (unless (re-search-forward regexp end t)
          (throw 'done nil))
        (let* ((seg-beg (match-beginning 0))
               (seg-end (match-end 0))
               (entered (buffer-substring-no-properties seg-beg seg-end))
               (seg-len (- seg-end seg-beg)))
          (when (rimel--entered-convertible-p entered)
            (delete-region seg-beg seg-end)
            (when-let* ((result (rimel--feed-entered-into-rime entered)))
              (insert (apply #'string result))
              (setq last-insert-pos (point)))
            (setq count (1+ count)))
          ;; Keep the region end in sync with the length change.
          (setq end (+ end (- (point) seg-beg) (- seg-len))))))
    (when (> count 0)
      (let ((last-marker (when last-insert-pos
                           (copy-marker last-insert-pos))))
        (rimel--full-width-punctuation-in-region beg end)
        (deactivate-mark)
        (when last-marker
          (goto-char last-marker))))
    (> count 0)))

(defun rimel--feed-entered-at-point-into-rimel ()
  "Delete the code string at point and convert it via rime.
Return non-nil when a code string was found."
  (when-let* ((entered-info (rimel--find-entered-at-point))
              (entered (nth 0 entered-info)))
    (let ((insert-pos (rimel--delete-region-or-chars (nth 1 entered-info))))
      ;; Position at the start of the deleted span, so the candidate
      ;; display and the inserted result stay in place even when the
      ;; region was selected backwards (point before mark).
      (goto-char insert-pos)
      (when-let* ((result (rimel--feed-entered-into-rime entered)))
        (insert (apply #'string result))))
    t))

;;;###autoload
(defun rimel-convert-string-at-point ()
  "Convert the code string or punctuation before point.
When the character before point is a known punctuation (see
`rimel-punctuation-dict'), toggle it between half-width and full-width.

Otherwise delete the code string before point (e.g. pinyin, or in the
active region) and let rime convert it to Chinese interactively.
Predicates in `rimel-disable-predicates' are ignored during the
conversion, since rime is driven directly.

Note: unlike pyim's `pyim-convert-string-at-point', dictionary
management triggers (adding or removing personal words) are not
supported, as rime manages its user dictionary itself.

With an active region, every code segment in the region is converted
in turn; segments without rime candidates are skipped."
  (interactive)
  (rimel--activate-rimel)
  (or (and (not mark-active)          ; punctuation toggle only without a region
           (rimel-punctuation-translate-at-point))
      (if mark-active
          (rimel--convert-region-segments)
        (rimel--feed-entered-at-point-into-rimel))
      (message "Rimel: no code string or punctuation at point to convert.")))


(provide 'rimel-convert)
;;; rimel-convert.el ends here
