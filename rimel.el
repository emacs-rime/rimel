;;; rimel.el --- A lightweight Rime input method -*- lexical-binding: t; -*-

;; Author: jixiuf
;; URL: https://github.com/jixiuf/rimel
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.4") (liberime "0.0.7"))
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

;; Rimel is a lightweight Chinese input method for Emacs based on liberime.
;; It directly uses Emacs' built-in `input-method-function' interface with
;; a read-event loop (similar to quail), providing a native Emacs experience.
;;
;; Features:
;; - Candidate display in input prompt
;; - Inline preedit overlay at cursor
;; - Pagination support
;; - Enter key for raw English commit
;; - Number keys / space for candidate selection
;;
;; Usage:
;;   (require 'rimel)
;;   (set-input-method "rimel")

;;; Code:

(require 'cl-lib)
(require 'liberime)

;; Suppress byte-compiler warnings for C dynamic module functions
(declare-function liberime-process-key "ext:liberime-core")
(declare-function liberime-get-context "ext:liberime-core")
(declare-function liberime-get-commit "ext:liberime-core")
(declare-function liberime-get-input "ext:liberime-core")
(declare-function liberime-clear-composition "ext:liberime-core")
(declare-function liberime-select-candidate "ext:liberime-core")
(declare-function posframe-show "ext:posframe")
(declare-function posframe-hide "ext:posframe")
(declare-function quail-keyboard-translate "quail")


;;; Customization

(defgroup rimel nil
  "Lightweight Rime input method for Emacs."
  :group 'leim
  :prefix "rimel-")

(defcustom rimel-schema nil
  "Rime schema ID to use (e.g., \"luna_pinyin_simp\").
When nil, use the default schema configured in Rime."
  :type '(choice (const :tag "Default" nil) string)
  :group 'rimel)

(defcustom rimel-show-candidate
  (or (require 'posframe nil t) 'prompt)
  "How to display candidates.
nil - don't display candidates
`prompt'   - display as the active input prompt
`posframe'  - display in a child frame near cursor (requires posframe package)"
  :type '(choice (const :tag "No display" nil)
                 (const :tag "Prompt" prompt)
                 (const :tag "Posframe" posframe))
  :group 'rimel)

(defcustom rimel-inline-preedit 'candidate
  "Control the inline preedit overlay at cursor position.
Set to t to show the raw preedit string (e.g. pinyin).
Set to \='candidate to show the commit-text-preview.
Set to nil to disable cursor overlay entirely.

This only controls the overlay at point.  To control whether
the preedit appears in the candidate window (echo-area or
posframe), see `rimel-candidate-show-preedit'."
  :type '(choice (const :tag "Inline candidate" candidate)
                 (const :tag "Inline preedit" t)
                 (const :tag "Disable inline preedit" nil))
  :group 'rimel)

(defcustom rimel-candidate-show-preedit t
  "When non-nil, show the current preedit string in the candidate window.
This affects both echo-area and posframe candidate displays.
Set to nil to hide preedit from the candidate box (only
candidates and page info will be shown).

This is independent of `rimel-inline-preedit', which controls
the overlay at the cursor position."
  :type 'boolean
  :group 'rimel)

(defcustom rimel-candidate-comment-format "%s(%s)"
  "Format string for displaying candidate comments.
The string must contain exactly two `%s' specifiers: the first
for the candidate text, the second for the comment (e.g., a
frequency indicator).  Set to nil to hide comments completely.

Examples:
  \"%s(%s)\" → candidate(comment)
  \"%s%s\"   → candidatecomment
  \"%s %s\"  → candidate comment
  \"%s[%s]\" → candidate[comment]"
  :type '(choice
          (const :tag "Parentheses: candidate(comment)" "%s(%s)")
          (const :tag "No separator: candidatecomment" "%s%s")
          (const :tag "Space: candidate comment" "%s %s")
          (const :tag "Brackets: candidate[comment]" "%s[%s]")
          (const :tag "Hide comments" nil)
          (string :tag "Custom format"))
  :group 'rimel)

(defcustom rimel-keymap
  '(("<home>"        . "<home>"                   )
    ("<left>"        . "<left>"                   )
    ("<escape>"      . "<escape>"                 )
    ("<return>"      . "<return>"                 )
    ("C-m"           . "<return>"                 )
    ("C-g"           . "<escape>"                 )
    ("M-<backspace>" . "<backspace><backspace>"   ) ; for shuangpin user
    ("<backspace>"   . "<backspace>"              )
    (?\C-?           . "<backspace>"              )
    (?\s             . "<space>"                  )
    ("<right>"       . "<right>"                  )
    ("<up>"          . "<up>"                     )
    ("<down>"        . "<down>"                   )
    ("C-p"           . "<up>"                     )
    ("C-n"           . "<down>"                   )
    ("<prior>"       . "<prior>"                  )
    ("<next>"        . "<next>"                   )
    ("C-b"           . "<prior>"                  )
    ("C-f"           . "<next>"                   )
    ("C-k"           . "S-<delete>"               )
    ("<end>"         . "<end>"                    )
    ("C-a"           . "<home>"                   )
    ("C-e"           . "<end>"                    )
    ("<tab>"         . "<tab>"                    ))
  "Keymap for custom keybindings in Rimel.
Both KEY and VALUE must be strings in the format returned by
\\[describe-key] (=describe-key').  This matches the format used
for saving keyboard macros (see =edmacro-mode').
Note: VALUE can be a sequence, but KEY cannot.

Examples:
    \"H-<left>\"
    \"M-RET\"
    \"C-M-<return>\""
  :type '(repeat (cons (sexp :tag "Emacs key")
                       (string :tag "Rime key")))
  :group 'rimel)

(defcustom rimel-disable-predicates nil
  "List of predicate functions for auto-switching to English.
Each function takes no arguments and returns non-nil to disable
Chinese input (pass through the key as-is).  If ANY predicate
returns non-nil, Chinese input is skipped for that key.

The variable `rimel--current-input-key' holds the key being
processed, available for predicates that need it.

Built-in predicates:
  `rimel-predicate-prog-in-code-p'
  `rimel-predicate-after-alphabet-char-p'
  `rimel-predicate-after-ascii-char-p'
  `rimel-predicate-current-uppercase-letter-p'
  `rimel-predicate-evil-mode-p'
  `rimel-predicate-org-in-src-block-p'
  `rimel-predicate-org-latex-mode-p'
  `rimel-predicate-tex-math-or-command-p'

You can also use predicates from emacs-rime (rime-predicate-*)
or pyim (pyim-probe-*) if those packages are loaded.

Example:
  (setq rimel-disable-predicates
        \\='(rimel-predicate-prog-in-code-p
          rimel-predicate-after-alphabet-char-p
          rimel-predicate-current-uppercase-letter-p))"
  :type '(repeat function)
  :group 'rimel)

(defface rimel-preedit-face
  '((t (:inherit font-lock-builtin-face)))
  "Face for the inline preedit string."
  :group 'rimel)

(defface rimel-highlight-face
  '((t (:inherit highlight)))
  "Face for the highlighted candidate."
  :group 'rimel)

(defcustom rimel-posframe-style 'vertical
  "Candidate layout style in posframe.
`vertical'   - one candidate per line
`horizontal' - all candidates in one line"
  :type '(choice (const :tag "Vertical" vertical)
                 (const :tag "Horizontal" horizontal))
  :group 'rimel)

(defcustom rimel-posframe-min-width 20
  "Minimum width of the posframe."
  :type 'integer
  :group 'rimel)

(defface rimel-posframe-face
  '((t (:inherit default)))
  "Face for the posframe body text."
  :group 'rimel)

(defface rimel-posframe-border-face
  '((t (:inherit border)))
  "Face for the posframe border."
  :group 'rimel)

(defcustom rimel-posframe-properties
  nil
  "Properties for posframe.
See =posframe-show= for supported values."
  :type '(plist)
  :group 'rimel)

;;; Internal variables

(defvar rimel--preedit-overlay nil
  "Overlay for displaying preedit at cursor.")

(defvar rimel--current-input-key nil
  "The key currently being processed by `rimel-input-method'.
Available for use by predicate functions in `rimel-disable-predicates'.")

(defvar rimel--posframe-buffer " *rimel-posframe*"
  "Buffer name for posframe candidate display.")


;;; Activation / Deactivation

;;;###autoload
(defun rimel-activate (_name)
  "Activate rimel input method.
Called by Emacs when user selects the \"rimel\" input method.
_NAME is the input method name (unused)."
  (unless (liberime-workable-p)
    (liberime-load))
  (when (and rimel-schema
             (liberime-workable-p)
             (not (string= rimel-schema liberime-current-schema)))
    (liberime-try-select-schema rimel-schema))
  (setq-local input-method-function #'rimel-input-method)
  (setq-local deactivate-current-input-method-function #'rimel-deactivate))

(defun rimel-deactivate ()
  "Deactivate rimel input method."
  (rimel--clear-state)
  (kill-local-variable 'input-method-function)
  (kill-local-variable 'deactivate-current-input-method-function))

;;; Preedit overlay

(defun rimel--show-preedit (preedit)
  "Display PREEDIT string as overlay at point."
  (rimel--clear-preedit)
  (when (and preedit (not (string-equal preedit "")))
    (let* ((pos (if (bobp)  (point) (1- (point))))
           (surrounding-face (plist-get (text-properties-at pos) 'face))
           ;; When there is text after point, after-string inherits
           ;; surrounding face automatically -- only use rimel-preedit-face
           ;; to avoid :height stacking.
           ;; At eol, after-string does NOT inherit, so merge surrounding-face.
           (face (if (and surrounding-face (eolp))
                     (cons 'rimel-preedit-face surrounding-face)
                   'rimel-preedit-face))
           (ov (make-overlay (point) (point) nil t t)))
      (overlay-put ov 'rimel t)
      (overlay-put ov 'after-string (propertize preedit 'face face))
      (setq rimel--preedit-overlay ov))))

(defun rimel--clear-preedit ()
  "Remove preedit overlay."
  (when (overlayp rimel--preedit-overlay)
    (delete-overlay rimel--preedit-overlay)
    (setq rimel--preedit-overlay nil)))

;;; Candidate display

(defun rimel--format-candidates (context &optional separator show-preedit)
  "Format CONTEXT into a candidate display string.
SEPARATOR is placed between candidates (default single space).
When SHOW-PREEDIT is non-nil, include the preedit string."
  (let* ((composition (alist-get 'composition context))
         (preedit (alist-get 'preedit composition))
         (menu (alist-get 'menu context))
         (candidates (alist-get 'candidates menu))
         (highlighted (or (alist-get 'highlighted-candidate-index menu) 0))
         (page-no (or (alist-get 'page-no menu) 0))
         (last-page-p (alist-get 'last-page-p menu))
         (sep (or separator " ")))
    (if (and candidates (not (null candidates)))
      (let ((parts '())
            (idx 0)
            (candidates-list candidates)
            (highlight-idx highlighted))
        ;; Preedit (only for prompt, posframe has overlay)
        (when (and show-preedit preedit)
          (push (format "[%s]" preedit) parts))
        ;; Candidates
        (dolist (cand candidates-list)
          (let* ((label-str (format "%d." (1+ idx)))
                (comment (get-text-property 0 :comment cand))
                (text (if (and comment rimel-candidate-comment-format)
                          (format rimel-candidate-comment-format cand comment)
                        cand))
                (item (format "%s%s" label-str text)))
            (push (if (eql idx highlight-idx)
                      (propertize item 'face 'rimel-highlight-face)
                    item)
                  parts))
          (setq idx (1+ idx)))
        ;; Page indicator
        (push (format "(%d%s)" (1+ (or page-no 0))
                      (if last-page-p "" "+"))
              parts)
        (string-join (nreverse parts) sep))
        ;; 无候选词：仅在未启用 inline preedit 时显示输入内容，避免重复
        (when (and (not rimel-inline-preedit)
                 preedit
                 (not (string-empty-p preedit)))
        (format "[%s]" preedit)))))

(defun rimel--show-candidates (context)
  "Display candidates from CONTEXT using the configured method.
Return a prompt string for `read-event', or nil when candidates
are displayed externally (e.g., via posframe)."
  (pcase rimel-show-candidate
    ('posframe (rimel--posframe-show context))
    ('prompt (rimel--prompt-show context))))

(defun rimel--hide-candidates ()
  "Hide the candidate display."
  (pcase rimel-show-candidate
    ('posframe (rimel--posframe-hide))
    ('prompt nil)))

;; Prompt backend

(defun rimel--prompt-show (context)
  "Return candidates from CONTEXT for use as an input prompt."
  (rimel--format-candidates
   context " " (eq rimel-inline-preedit 'candidate)))

;; Posframe backend
(defun rimel--at-screen-bottom-p ()
  "At screen bottom or not."
  (let* ((current-line (count-screen-lines (window-start) (point)))
         (window-height (window-body-height)))
    (>= current-line (- window-height 1))))

(defun rimel--posframe-show (context)
  "Display candidates from CONTEXT in a posframe near cursor.
Return nil on success (candidates shown in child frame), or a
prompt string for `read-event' when posframe is unavailable (TUI)."
  (if (not (require 'posframe nil t))
      (rimel--prompt-show context)
    (let* ((sep (if (eq rimel-posframe-style 'vertical) "\n" " "))
           (content (rimel--format-candidates
                     context sep rimel-candidate-show-preedit)))
      (if (not content)
          (rimel--posframe-hide)
        (apply #'posframe-show
         rimel--posframe-buffer
         :string content
         :x-pixel-offset 2
         ;; for TUI emacs
         :y-pixel-offset (if (rimel--at-screen-bottom-p) -3 1)
         :position (point)
         :background-color (face-background 'rimel-posframe-face nil t)
         :foreground-color (face-foreground 'rimel-posframe-face nil t)
         :border-width 1
         :border-color (face-background 'rimel-posframe-border-face nil t)
         :min-width rimel-posframe-min-width
         :timeout nil
         rimel-posframe-properties)
        nil))))

(defun rimel--posframe-hide ()
  "Hide the posframe candidate display."
  (when (require 'posframe nil t)
    (posframe-hide rimel--posframe-buffer)))

;;; State management

(defun rimel--clear-state ()
  "Clear all composition state."
  (ignore-errors (liberime-clear-composition))
  (rimel--clear-preedit)
  (rimel--hide-candidates))

(defun rimel--keyboard-translate (char)
  "If quail is loaded, translate CHAR via `quail-keyboard-translate'.
Otherwise return CHAR unchanged."
  (if (and (featurep 'quail) (integerp char))
      (quail-keyboard-translate char)
    char))

;;; Core input method

(defun rimel--composable-key-p (key)
  "Return non-nil if KEY should start a rime composition.
Includes lowercase letters and common Chinese punctuation marks."
  (and (integerp key)
       (or (and (>= key ?a) (<= key ?z))
           (memq key '(?+ ?= ?- ?_ ?\( ?\) ?* ?& ?^ ?% ?$ ?# ?@ ?! ?` ?~
                          ?\[ ?\]  ?{  ?}  ?\\  ?|
                          ?\: ?\; ?\'  ?\"
                          ?, ?. ?<  ?>   ?\? ?/
                          ?\,  ?。 ?…  ?—  ?·  ?～  ?、)))))

(defun rimel--get-commit ()
  "Get committed text from rime, or nil."
  (let ((commit (liberime-get-commit)))
    (when (and commit (not (string-equal commit "")))
      commit)))


(defun rimel-input-method (key)
  "Process KEY through rimel input method.
This function serves as `input-method-function'."
  (setq rimel--current-input-key key)
  (let ((k (rimel--keyboard-translate key)))
    ;; form quail-input-method
    (if (or (and (or buffer-read-only
                     (and (get-char-property (point) 'read-only)
                          (get-char-property (point) 'front-sticky)))
                 (not (or inhibit-read-only
                          (get-char-property (point) 'inhibit-read-only))))
            (not (rimel--composable-key-p k))
            (not (rimel--should-enable-p))
            ;; When an overriding keymap is active (e.g., `set-transient-map'
            ;; used by spatial-window, avy, etc.), pass the key through if
            ;; it has a binding there.  This matches quail's behavior per
            ;; Emacs bug#68338.
            (and overriding-terminal-local-map
                 (lookup-key overriding-terminal-local-map (vector key)))
            overriding-local-map)
        (list key)
      ;; Start composition
      (liberime-clear-composition)
      (liberime-process-key k)
      ;; Check immediate commit (e.g., rime auto-select)
      (let ((commit (rimel--get-commit)))
        (if commit
            (string-to-list commit)
          ;; Enter composition loop
          (rimel--composition-loop))))))

(defun rimel--update-display ()
  "Update preedit overlay and candidate display from current rime state.
Return a prompt string when the candidate backend uses the active
input prompt."
  (let ((ctx (liberime-get-context)))
    (cond
     ((eq rimel-inline-preedit 'candidate)
      (rimel--show-preedit (alist-get 'commit-text-preview ctx)))
     ((eq rimel-inline-preedit t)
      (rimel--show-preedit (alist-get 'preedit (alist-get 'composition ctx)))))
    (rimel--show-candidates ctx)))

(defun rimel--check-commit ()
  "Return committed text if any."
  (let ((commit (rimel--get-commit)))
    (when commit
      (when-let* ((input (liberime-get-input)))
        (setq unread-command-events
              (append (string-to-list input) unread-command-events)))
      commit)))

(defun rimel--feed-key-and-check (key)
  "Send KEY to rime.  Return committed text if any."
  (liberime-process-key key)
  (rimel--check-commit))

(defun rimel--get-key (pair)
  "Get key from PAIR for `liberime-process-keys'."
  (let ((key (car pair)))
    (cond
     ((numberp key)
      (car (listify-key-sequence (vector key))))
     ((symbolp key)
      (car (listify-key-sequence (vector key))))
     ((stringp key)
      (car (listify-key-sequence (kbd key)))))))

(defun rimel--composition-loop ()
  "Main composition loop.  Read events until composition finishes.
Return list of characters to insert, or nil."
  (let ((result nil)
        (continue t)
        (prompt nil)
        (echo-keystrokes 0))
    (unwind-protect
        (progn
          (setq prompt (rimel--update-display))
          ;; Event loop
          (while (and continue (not (string-empty-p (liberime-get-input))))
            (let* ((event (read-event prompt))
                   (translated (rimel--keyboard-translate event)))
              (cond
               ;; Key mapping via rimel-keymap
               ((when-let* ((pair (cl-find event rimel-keymap
                                            :key #'rimel--get-key
                                            :test #'equal))
                            (rime-keycode (cdr pair)))
                  (liberime-process-keys (kbd rime-keycode))
                  (if-let* ((commit (rimel--check-commit)))
                      (setq result commit continue nil)
                    (setq prompt (rimel--update-display)))
                  t))

               ;; Character key — pass directly to rime.
               ;; Rime handles everything natively: composition continuation,
               ;; candidate selection by digits, symbol patterns, etc.
               ((integerp translated)
                (if-let* ((commit (rimel--feed-key-and-check translated)))
                    (setq result commit continue nil)
                  ;; Rime handled the key — update display, continue composing
                  (setq prompt (rimel--update-display))
                  t))

               ;; Unhandled event - exit composition, push event back
               (t
                (liberime-clear-composition)
                (setq continue nil)
                (setq unread-command-events
                      (if (characterp event)
                          (cons event unread-command-events)
                        (nconc (listify-key-sequence (vector event))
                               unread-command-events))))))))
      ;; Cleanup (unwind-protect)
      (rimel--clear-preedit)
      (rimel--hide-candidates))
    ;; Return result
    (when (and result (not (string-equal result "")))
      (string-to-list result))))

;;; Predicates — context-based auto English switching

(defun rimel--should-enable-p ()
  "Return non-nil if Chinese input should be active.
Checks `rimel-disable-predicates'; if any returns non-nil,
Chinese input is disabled for the current key."
  (not (seq-find #'funcall rimel-disable-predicates)))

(defun rimel-predicate-prog-in-code-p ()
  "Return non-nil when cursor is in code (not string/comment).
Only active in `prog-mode' derived buffers."
  (and (derived-mode-p 'prog-mode 'conf-mode)
       (let ((ppss (syntax-ppss)))
         (not (or (nth 3 ppss)    ; in string
                  (nth 4 ppss)))))) ; in comment

(defun rimel-predicate-after-alphabet-char-p ()
  "Return non-nil when the char before point is a Latin letter.
Useful for continuing English words without switching."
  (and (not (bobp))
       (let ((ch (char-before)))
         (and ch
              (or (and (>= ch ?a) (<= ch ?z))
                  (and (>= ch ?A) (<= ch ?Z)))))))

(defun rimel-predicate-after-ascii-char-p ()
  "Return non-nil when the char before point is an ASCII char.
Broader than `rimel-predicate-after-alphabet-char-p' — includes
digits and punctuation."
  (and (not (bobp))
       (let ((ch (char-before)))
         (and ch (>= ch #x21) (<= ch #x7e)))))

(defun rimel-predicate-current-uppercase-letter-p ()
  "Return non-nil when the current input key is an uppercase letter."
  (and rimel--current-input-key
       (integerp rimel--current-input-key)
       (>= rimel--current-input-key ?A)
       (<= rimel--current-input-key ?Z)))

(declare-function evil-normal-state-p "ext:evil-states")
(declare-function evil-visual-state-p "ext:evil-states")
(declare-function evil-motion-state-p "ext:evil-states")
(declare-function evil-operator-state-p "ext:evil-states")

(defun rimel-predicate-evil-mode-p ()
  "Return non-nil in evil normal, visual, motion or operator state.
Returns nil if evil is not loaded or in insert/emacs state."
  (and (fboundp 'evil-normal-state-p)
       (or (evil-normal-state-p)
           (evil-visual-state-p)
           (evil-motion-state-p)
           (evil-operator-state-p))))

(declare-function org-in-src-block-p "ext:org")

(defun rimel-predicate-org-in-src-block-p ()
  "Return non-nil when point is inside an Org source block."
  (and (derived-mode-p 'org-mode)
       (fboundp 'org-in-src-block-p)
       (org-in-src-block-p)))

(declare-function org-inside-LaTeX-fragment-p "ext:org")
(declare-function org-inside-latex-macro-p "ext:org")

(defun rimel-predicate-org-latex-mode-p ()
  "Return non-nil when point is in an Org LaTeX fragment or macro."
  (and (derived-mode-p 'org-mode)
       (or (and (fboundp 'org-inside-LaTeX-fragment-p)
                (org-inside-LaTeX-fragment-p))
           (and (fboundp 'org-inside-latex-macro-p)
                (org-inside-latex-macro-p)))))

(declare-function texmathp "ext:texmathp")

(defun rimel-predicate-tex-math-or-command-p ()
  "Return non-nil in a TeX math environment or after a TeX command.
Supports AUCTeX's `texmathp' if available, otherwise falls back
to detecting $ and \\ prefixes."
  (when (derived-mode-p 'tex-mode 'latex-mode 'TeX-mode 'LaTeX-mode)
    (or (and (fboundp 'texmathp) (texmathp))
        ;; Fallback: check for $ or \ before point
        (and (not (bobp))
             (let ((ch (char-before)))
               (or (eq ch ?$) (eq ch ?\\)))))))

(defmacro rimel-predicate-after-digit-punct-p (&rest punct-chars)
  "Return a predicate function that disables Chinese input after a digit.
When the returned predicate returns non-nil, the key is passed
through directly (as an ASCII character) instead of being
processed by Rime.  That allows typing decimal points (3.14) or
time (12:34) without leaving Chinese mode.

Optional PUNCT-CHARS are the characters to check for; defaults
to (?. ?:).

Usage:
  ;; Default: pass-through ?. and ?: after a digit
  (add-to-list \='rimel-disable-predicates
               (rimel-predicate-after-digit-punct-p))
  ;; Custom chars, e.g. also allow hyphen after digit
  (add-to-list \='rimel-disable-predicates
               (rimel-predicate-after-digit-punct-p ?. ?: ?-))"
  (let ((chars (or punct-chars '(?. ?:))))
    `(lambda ()
       ,(format "Predicate: pass-through %s after a digit."
                (mapconcat (lambda (c) (string c)) chars ", "))
       (and rimel--current-input-key
            (integerp rimel--current-input-key)
            (memq rimel--current-input-key ',chars)
            (not (bobp))
            (let ((prev (char-before)))
              (and prev (>= prev ?0) (<= prev ?9)))))))

;;;###autoload (autoload 'rimel-select-schema "rimel" "Select a rime schema interactive." t)
(defalias 'rimel-select-schema #'liberime-select-schema-interactive)

;;;###autoload (autoload 'rimel-deploy "rimel" "Deploy liberime to affect config file change." t)
(defalias 'rimel-deploy #'liberime-deploy)

;;;###autoload (autoload 'rimel-sync "rimel" "Sync rime user data." t)
(defalias 'rimel-sync #'liberime-sync)

;;; Registration

;;;###autoload
(register-input-method "rimel" "Chinese" #'rimel-activate
                       (if (char-displayable-p 12563) (char-to-string 12563) "中")
                       "Rimel - Rime input method via liberime")

(provide 'rimel)

;;; rimel.el ends here
