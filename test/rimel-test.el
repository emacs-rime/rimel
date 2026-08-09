;;; rimel-test.el --- Tests for rimel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -L test -l ert -l test/rimel-test.el -f rimel-test-run

;;; Code:

(require 'ert)
(require 'cl-lib)

(declare-function liberime-clear-composition "liberime-core")

;; -----------------------------------------------------------------------
;; Mock liberime — stub out the C dynamic module for pure Elisp testing
;; -----------------------------------------------------------------------

(defvar rimel-test--rime-input ""
  "Simulated rime input buffer.")

(defvar rimel-test--rime-committed nil
  "Simulated committed text, or nil.")

(defvar rimel-test--rime-candidates nil
  "Simulated candidate list for the current page.")

(defvar rimel-test--rime-highlighted 0
  "Simulated highlighted candidate index.")

(defvar rimel-test--rime-page 0
  "Simulated page number.")

(defvar rimel-test--rime-last-page t
  "Simulated last-page flag.")

(defvar rimel-test--rime-preedit nil
  "Simulated preedit string.")

(defvar rimel-test--rime-commit-preview nil
  "Simulated commit-text-preview.")

(defvar rimel-test--rime-schema nil
  "Last schema selected.")

(defvar rimel-test--rime-schema-select-count 0
  "Number of schema selection attempts.")

(defvar rimel-test--process-key-hook nil
  "Hook called with (key mask) on each process-key call.
Can be set in tests to simulate rime behavior.")

(defun rimel-test--reset-rime ()
  "Reset all mock rime state."
  (setq rimel-test--rime-input ""
        rimel-test--rime-committed nil
        rimel-test--rime-candidates nil
        rimel-test--rime-highlighted 0
        rimel-test--rime-page 0
        rimel-test--rime-last-page t
        rimel-test--rime-preedit nil
        rimel-test--rime-commit-preview nil
        rimel-test--rime-schema nil
        rimel-test--rime-schema-select-count 0
        liberime-current-schema nil
        rimel-test--process-key-hook nil))

;; Provide the liberime feature so (require 'liberime) succeeds
(unless (featurep 'liberime)
  (defun liberime-process-key (key &optional mask)
    "Mock: append KEY to input buffer, simulate candidate selection."
    (cond
     ;; Digit key in candidate list — select candidate
     ((and (integerp key) (>= key ?1) (<= key ?9)
           rimel-test--rime-candidates
           (> (length rimel-test--rime-candidates) 0))
      (let ((idx (- key ?1)))
        (when (< idx (length rimel-test--rime-candidates))
          (setq rimel-test--rime-committed
                (nth idx rimel-test--rime-candidates))
          (liberime-clear-composition))))
     ;; Letter key — append to input buffer
     ((and (integerp key) (>= key ?a) (<= key ?z))
      (setq rimel-test--rime-input
            (concat rimel-test--rime-input (char-to-string key)))))
    (when rimel-test--process-key-hook
      (funcall rimel-test--process-key-hook key (or mask 0)))
    t)

  (defun liberime-get-context ()
    "Mock: return a simulated context alist."
    (when (or rimel-test--rime-candidates
              rimel-test--rime-preedit)
      `((composition . ((preedit . ,rimel-test--rime-preedit)))
        (commit-text-preview . ,rimel-test--rime-commit-preview)
        (menu . ((candidates . ,rimel-test--rime-candidates)
                 (highlighted-candidate-index . ,rimel-test--rime-highlighted)
                 (page-no . ,rimel-test--rime-page)
                 (last-page-p . ,rimel-test--rime-last-page))))))

  (defun liberime-get-commit ()
    "Mock: return and clear committed text."
    (prog1 rimel-test--rime-committed
      (setq rimel-test--rime-committed nil)))

  (defun liberime-get-input ()
    "Mock: return the current input buffer."
    rimel-test--rime-input)

  (defun liberime-clear-composition ()
    "Mock: clear input buffer."
    (setq rimel-test--rime-input ""
          rimel-test--rime-preedit nil
          rimel-test--rime-commit-preview nil
          rimel-test--rime-candidates nil))

  (defun liberime-select-candidate (idx)
    "Mock: select candidate at IDX."
    (when (and rimel-test--rime-candidates
               (< idx (length rimel-test--rime-candidates)))
      (setq rimel-test--rime-committed
            (nth idx rimel-test--rime-candidates))
      (liberime-clear-composition)))

  (defun liberime-workable-p ()
    "Mock: always workable."
    t)

  (defun liberime-load ()
    "Mock: no-op."
    nil)

  (defun liberime-try-select-schema (schema)
    "Mock: record selected schema."
    (cl-incf rimel-test--rime-schema-select-count)
    (setq rimel-test--rime-schema schema
          liberime-current-schema schema))

  (defun liberime-select-schema-interactive ()
    "Mock: no-op."
    (interactive)
    nil)

  (defun liberime-deploy ()
    "Mock: no-op."
    (interactive)
    nil)

  (defun liberime-sync ()
    "Mock: sync rime user data."
    (interactive)
    nil)

  (defun liberime-process-keys (keys)
    "Mock: simulate key processing."
    (let ((keyseq (cond
                   ((stringp keys) (kbd keys))
                   ((vectorp keys) keys)
                   ((listp keys) keys)
                   (t (kbd keys)))))
      (mapc (lambda (k)
              (when (and (integerp k) (>= k ?a) (<= k ?z))
                (setq rimel-test--rime-input
                      (concat rimel-test--rime-input (char-to-string k)))))
            (if (vectorp keyseq) keyseq (list keyseq))))
    t)

  (provide 'liberime))

(setq load-prefer-newer t)
(require 'rimel)

;; -----------------------------------------------------------------------
;; Test runner
;; -----------------------------------------------------------------------

(defun rimel-test-run ()
  "Run all rimel ERT tests and exit with appropriate status."
  (ert-run-tests-batch-and-exit "rimel-test-*"))

;; -----------------------------------------------------------------------
;; Test: composable-key-p
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-composable-key-lowercase ()
  "Lowercase letters should be composable."
  (should (rimel--composable-key-p ?a))                    ; a
  (should (rimel--composable-key-p ?z))                    ; z
  (should (rimel--composable-key-p ?m)))                   ; m

(ert-deftest rimel-test-composable-key-uppercase ()
  "Uppercase letters should not be composable."
  (should-not (rimel--composable-key-p ?A))                ; A
  (should-not (rimel--composable-key-p ?Z)))               ; Z

(ert-deftest rimel-test-composable-key-digits ()
  "Digits should not be composable."
  (should-not (rimel--composable-key-p ?0))                ; 0
  (should-not (rimel--composable-key-p ?9)))               ; 9

(ert-deftest rimel-test-composable-key-punctuation ()
  "Chinese punctuation should be composable."
  (should (rimel--composable-key-p ?,))                    ; comma
  (should (rimel--composable-key-p ?.))                    ; period
  (should (rimel--composable-key-p ?/))                    ; slash
  (should (rimel--composable-key-p ?\\))                   ; backslash
  (should (rimel--composable-key-p ?\[))                   ; left bracket
  (should (rimel--composable-key-p ?\]))                   ; right bracket
  (should (rimel--composable-key-p ?~)))                   ; tilde

(ert-deftest rimel-test-composable-key-non-composable ()
  "Control keys and symbols should not be composable."
  (should-not (rimel--composable-key-p ?\t))               ; tab
  (should-not (rimel--composable-key-p ?\r))               ; return
  (should-not (rimel--composable-key-p ?\C-a))             ; C-a
  (should-not (rimel--composable-key-p nil)))              ; nil

;; -----------------------------------------------------------------------
;; Test: format-candidates
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-format-candidates-basic ()
  "Test basic candidate formatting."
  (let ((ctx '((composition . ((preedit . "ni")))
               (menu . ((candidates . ("你" "妮" "尼" "泥" "逆"))
                        (highlighted-candidate-index . 0)
                        (page-no . 0)
                        (last-page-p . nil))))))
    (let ((result (rimel--format-candidates ctx)))
      (should (stringp result))                            ; returns string
      (should (string-match-p "1\\.你" result))            ; first candidate
      (should (string-match-p "2\\.妮" result))            ; second candidate
      (should (string-match-p "(1\\+)" result)))))          ; page indicator (not last)

(ert-deftest rimel-test-format-candidates-last-page ()
  "Test candidate formatting on the last page."
  (let ((ctx '((composition . ((preedit . "ni")))
               (menu . ((candidates . ("你"))
                        (highlighted-candidate-index . 0)
                        (page-no . 2)
                        (last-page-p . t))))))
    (let ((result (rimel--format-candidates ctx)))
      (should (string-match-p "(3)" result)))))            ; page 3, last page

(ert-deftest rimel-test-format-candidates-with-preedit ()
  "Test candidate formatting with preedit display."
  (let ((ctx '((composition . ((preedit . "ni")))
               (menu . ((candidates . ("你"))
                        (highlighted-candidate-index . 0)
                        (page-no . 0)
                        (last-page-p . t))))))
    (let ((result (rimel--format-candidates ctx " " t)))
      (should (string-match-p "\\[ni\\]" result)))))       ; preedit shown

(ert-deftest rimel-test-format-candidates-nil ()
  "Test formatting returns nil when no candidates."
  (should-not (rimel--format-candidates nil))              ; nil context
  (should-not (rimel--format-candidates                    ; no candidates
               '((menu . ((candidates . nil)))))))

(ert-deftest rimel-test-format-candidates-vertical-separator ()
  "Test candidate formatting with vertical (newline) separator."
  (let ((ctx '((composition . ((preedit . "ni")))
               (menu . ((candidates . ("你" "妮"))
                        (highlighted-candidate-index . 0)
                        (page-no . 0)
                        (last-page-p . t))))))
    (let ((result (rimel--format-candidates ctx "\n")))
      (should (string-match-p "\n" result)))))             ; newline separator used

;; -----------------------------------------------------------------------
;; Test: format-candidates with candidate comment
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-format-candidates-comment ()
  "Test that candidate comments are displayed."
  (let* ((cand (propertize "你" :comment "nǐ"))
         (ctx `((composition . ((preedit . "ni")))
                (menu . ((candidates . (,cand))
                         (highlighted-candidate-index . 0)
                         (page-no . 0)
                         (last-page-p . t))))))
    (let ((result (rimel--format-candidates ctx)))
      (should (string-match-p "你(nǐ)" result)))))         ; comment shown

;; -----------------------------------------------------------------------
;; Test: preedit overlay
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-show-preedit ()
  "Test preedit overlay creation and display."
  (with-temp-buffer
    (insert "hello ")
    (rimel--show-preedit "你好")
    (should (overlayp rimel--preedit-overlay))              ; overlay created
    (should (equal "你好"                                   ; overlay content
                   (let ((as (overlay-get rimel--preedit-overlay 'after-string)))
                     (substring-no-properties as))))
    ;; Clear
    (rimel--clear-preedit)
    (should-not rimel--preedit-overlay)))                   ; overlay removed

(ert-deftest rimel-test-show-preedit-empty ()
  "Test that empty preedit does not create overlay."
  (with-temp-buffer
    (insert "hello ")
    (rimel--show-preedit "")
    (should-not rimel--preedit-overlay)                    ; no overlay for empty
    (rimel--show-preedit nil)
    (should-not rimel--preedit-overlay)))                   ; no overlay for nil

(ert-deftest rimel-test-preedit-face ()
  "Test that preedit overlay uses rimel-preedit-face."
  (with-temp-buffer
    (insert "hello ")
    (rimel--show-preedit "nihao")
    (let* ((as (overlay-get rimel--preedit-overlay 'after-string))
           (face (get-text-property 0 'face as)))
      (should (eq face 'rimel-preedit-face)))              ; preedit face applied
    (rimel--clear-preedit)))

;; -----------------------------------------------------------------------
;; Test: clear-state
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-clear-state ()
  "Test that clear-state resets everything."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (insert "hello ")
    (rimel--show-preedit "test")
    (should (overlayp rimel--preedit-overlay))             ; overlay exists before clear
    (rimel--clear-state)
    (should-not rimel--preedit-overlay)                    ; overlay removed after clear
    (should (string-equal rimel-test--rime-input ""))))     ; rime input cleared

;; -----------------------------------------------------------------------
;; Test: predicates
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-predicate-prog-in-code ()
  "Test prog-in-code predicate."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun foo ()")
    ;; In code — should return non-nil (disable Chinese)
    (should (rimel-predicate-prog-in-code-p))              ; in code region

    ;; In a string — should return nil (enable Chinese)
    (insert "\n  \"")
    (should-not (rimel-predicate-prog-in-code-p))          ; in string

    ;; In a comment — should return nil (enable Chinese)
    (erase-buffer)
    (insert "; comment")
    (should-not (rimel-predicate-prog-in-code-p))))        ; in comment

(ert-deftest rimel-test-predicate-prog-in-code-non-prog ()
  "Test prog-in-code predicate returns nil in non-prog modes."
  (with-temp-buffer
    (fundamental-mode)
    (insert "some text")
    (should-not (rimel-predicate-prog-in-code-p))))        ; non-prog mode

(ert-deftest rimel-test-predicate-after-alphabet ()
  "Test after-alphabet-char predicate."
  (with-temp-buffer
    (insert "hello")
    (should (rimel-predicate-after-alphabet-char-p))       ; after letter
    (insert " ")
    (should-not (rimel-predicate-after-alphabet-char-p))   ; after space
    (insert "123")
    (should-not (rimel-predicate-after-alphabet-char-p))   ; after digit
    (insert "Z")
    (should (rimel-predicate-after-alphabet-char-p))))     ; after uppercase

(ert-deftest rimel-test-predicate-after-ascii ()
  "Test after-ascii-char predicate."
  (with-temp-buffer
    (insert "a")
    (should (rimel-predicate-after-ascii-char-p))          ; after letter
    (insert "1")
    (should (rimel-predicate-after-ascii-char-p))          ; after digit
    (insert ".")
    (should (rimel-predicate-after-ascii-char-p))          ; after punctuation
    (erase-buffer)
    (insert " ")
    (should-not (rimel-predicate-after-ascii-char-p))      ; space is not in range
    (erase-buffer)
    (should-not (rimel-predicate-after-ascii-char-p))))    ; empty buffer

(ert-deftest rimel-test-predicate-uppercase ()
  "Test uppercase-letter predicate."
  (let ((rimel--current-input-key ?A))
    (should (rimel-predicate-current-uppercase-letter-p))) ; uppercase A
  (let ((rimel--current-input-key ?Z))
    (should (rimel-predicate-current-uppercase-letter-p))) ; uppercase Z
  (let ((rimel--current-input-key ?a))
    (should-not (rimel-predicate-current-uppercase-letter-p))) ; lowercase
  (let ((rimel--current-input-key nil))
    (should-not (rimel-predicate-current-uppercase-letter-p)))) ; nil

(ert-deftest rimel-test-predicate-evil-mode ()
  "Test evil-mode predicate when evil is not loaded."
  ;; When evil is not loaded, fboundp returns nil
  (unless (fboundp 'evil-normal-state-p)
    (should-not (rimel-predicate-evil-mode-p))))           ; no evil: nil

;; -----------------------------------------------------------------------
;; Test: should-enable-p
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-should-enable-p ()
  "Test the should-enable-p wrapper."
  (let ((rimel-disable-predicates nil))
    (should (rimel--should-enable-p)))                     ; no predicates: enabled
  (let ((rimel-disable-predicates (list (lambda () nil))))
    (should (rimel--should-enable-p)))                     ; predicate returns nil: enabled
  (let ((rimel-disable-predicates (list (lambda () t))))
    (should-not (rimel--should-enable-p)))                 ; predicate returns t: disabled
  (let ((rimel-disable-predicates
         (list (lambda () nil) (lambda () t))))
    (should-not (rimel--should-enable-p))))                ; any returns t: disabled

;; -----------------------------------------------------------------------
;; Test: get-commit
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-get-commit ()
  "Test get-commit returns committed text."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-committed "你好")
  (should (equal "你好" (rimel--get-commit)))               ; returns commit
  (should-not (rimel--get-commit)))                         ; second call returns nil

(ert-deftest rimel-test-get-commit-empty ()
  "Test get-commit returns nil for empty commit."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-committed "")
  (should-not (rimel--get-commit))                         ; empty string returns nil
  (setq rimel-test--rime-committed nil)
  (should-not (rimel--get-commit)))                        ; nil returns nil

;; -----------------------------------------------------------------------
;; Test: activation and deactivation
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-activate ()
  "Test input method activation."
  (with-temp-buffer
    (rimel-activate "rimel")
    (should (eq input-method-function #'rimel-input-method)) ; function set
    (should (eq deactivate-current-input-method-function
                #'rimel-deactivate))))                      ; deactivate function set

(ert-deftest rimel-test-deactivate ()
  "Test input method deactivation."
  (with-temp-buffer
    (rimel-activate "rimel")
    (rimel-deactivate)
    (should-not (local-variable-p 'input-method-function)))) ; local var removed

(ert-deftest rimel-test-activate-with-schema ()
  "Test activation with a custom schema."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (let ((rimel-schema "luna_pinyin_simp"))
      (rimel-activate "rimel")
      (should (equal "luna_pinyin_simp"                     ; schema selected
                     rimel-test--rime-schema)))))

(ert-deftest rimel-test-activate-selects-schema-once ()
  "Test repeated activation selects the same schema only once."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (let ((rimel-schema "luna_pinyin_simp"))
      (rimel-activate "rimel")
      (rimel-activate "rimel")
      (should (equal "luna_pinyin_simp"
                     rimel-test--rime-schema))
      (should (= 1 rimel-test--rime-schema-select-count)))))

(ert-deftest rimel-test-activate-reselects-changed-schema ()
  "Test activation selects again after `rimel-schema' changes."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (let ((rimel-schema "luna_pinyin_simp"))
      (rimel-activate "rimel")
      (setq rimel-schema "terra_pinyin")
      (rimel-activate "rimel")
      (should (equal "terra_pinyin"
                     rimel-test--rime-schema))
      (should (= 2 rimel-test--rime-schema-select-count)))))

;; -----------------------------------------------------------------------
;; Test: input-method skip conditions
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-input-method-non-composable ()
  "Test that non-composable keys pass through."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (should (equal '(?1) (rimel-input-method ?1)))         ; digit passes through
    (should (equal '(?A) (rimel-input-method ?A)))))       ; uppercase passes through

(ert-deftest rimel-test-input-method-read-only ()
  "Test that keys pass through in read-only buffers."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (setq buffer-read-only t)
    (should (equal '(?a) (rimel-input-method ?a)))))       ; key passes through

(ert-deftest rimel-test-input-method-predicate-disabled ()
  "Test that keys pass through when predicates disable input."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (let ((rimel-disable-predicates (list (lambda () t))))
      (should (equal '(?a) (rimel-input-method ?a))))))    ; predicate disables

;; -----------------------------------------------------------------------
;; Test: input-method immediate commit
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-input-method-immediate-commit ()
  "Test immediate commit (e.g., auto-select by rime)."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    ;; Simulate: rime auto-commits on first key
    (setq rimel-test--process-key-hook
          (lambda (_key _mask)
            (setq rimel-test--rime-committed "，")))
    (let ((result (rimel-input-method ?,)))
      (should (equal '(?，) result)))))                     ; immediate commit

;; -----------------------------------------------------------------------
;; Test: input method registered
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-registered ()
  "Test that rimel is registered as an input method."
  (let ((im (assoc "rimel" input-method-alist)))
    (should im)                                            ; registered
    (should (equal "Chinese" (nth 1 im)))))                ; language is Chinese


;; -----------------------------------------------------------------------
;; Test: rimel-keymap entries
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-keymap-entries ()
  "Test that rimel-keymap has expected entries."
  (should (cl-find "<up>" rimel-keymap :key #'car :test #'equal))       ; up key mapped
  (should (cl-find "<down>" rimel-keymap :key #'car :test #'equal))     ; down key mapped
  (should (cl-find "<left>" rimel-keymap :key #'car :test #'equal))     ; left key mapped
  (should (cl-find "<right>" rimel-keymap :key #'car :test #'equal))    ; right key mapped
  (should (cl-find "<prior>" rimel-keymap :key #'car :test #'equal))    ; prior mapped
  (should (cl-find "<next>" rimel-keymap :key #'car :test #'equal))     ; next mapped
  (should (cl-find "C-p" rimel-keymap :key #'car :test #'equal))       ; C-p mapped
  (should (cl-find "C-n" rimel-keymap :key #'car :test #'equal)))      ; C-n mapped

;; -----------------------------------------------------------------------
;; Test: posframe bottom detection
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-at-screen-bottom ()
  "Test screen bottom detection."
  (with-temp-buffer
    ;; At top of buffer — should not be at bottom
    (insert "line1")
    (goto-char (point-min))
    (should-not (rimel--at-screen-bottom-p))))             ; top is not bottom

;; -----------------------------------------------------------------------
;; Test: show-candidates dispatching
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-show-candidates-prompt ()
  "Test prompt candidate display."
  (rimel-test--reset-rime)
  (let ((rimel-show-candidate 'prompt)
        (displayed nil))
    (cl-letf (((symbol-function 'rimel--prompt-show)
               (lambda (ctx)
                 (setq displayed ctx)
                 "prompt")))
      (let ((ctx '((menu . ((candidates . ("你")))))))
        (should (equal "prompt" (rimel--show-candidates ctx)))
        (should displayed)))))                             ; prompt-show called

(ert-deftest rimel-test-hide-candidates-prompt ()
  "Test prompt candidate hiding."
  (let ((rimel-show-candidate 'prompt))
    ;; Should not error
    (rimel--hide-candidates)))                             ; hide succeeds

;; -----------------------------------------------------------------------
;; Test: faces exist
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-faces-defined ()
  "Test that all custom faces are defined."
  (should (facep 'rimel-preedit-face))                     ; preedit face
  (should (facep 'rimel-highlight-face))                   ; highlight face
  (should (facep 'rimel-posframe-face))                    ; posframe face
  (should (facep 'rimel-posframe-border-face)))            ; posframe border face

;; -----------------------------------------------------------------------
;; Test: aliases
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-command-aliases ()
  "Test that command aliases are defined."
  (should (commandp 'rimel-select-schema))                 ; select-schema
  (should (commandp 'rimel-deploy))                        ; deploy
  (should (commandp 'rimel-sync)))                         ; sync

;; -----------------------------------------------------------------------
;; Test: composition loop with mock events
;; -----------------------------------------------------------------------


(ert-deftest rimel-test-composition-loop-select-candidate ()
  "Test candidate selection by label key in composition loop."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-input "ni"
        rimel-test--rime-preedit "ni"
        rimel-test--rime-candidates '("你" "妮" "尼"))
  (with-temp-buffer
    (cl-letf (((symbol-function 'read-event)
               (lambda (&optional _prompt) ?2)))           ; select 2nd candidate
      (let ((result (rimel--composition-loop)))
        (should (equal '(?妮) result))))))                  ; 2nd candidate selected

(ert-deftest rimel-test-composition-loop-read-event-prompt ()
  "Test that prompt candidates are passed to `read-event'."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-input "ni"
        rimel-test--rime-preedit "ni"
        rimel-test--rime-candidates '("你" "妮" "尼"))
  (let ((rimel-show-candidate 'prompt)
        captured-prompt)
    (with-temp-buffer
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&optional prompt)
                   (setq captured-prompt (substring-no-properties prompt))
                   ?2)))
        (let ((result (rimel--composition-loop)))
          (should (equal '(?妮) result))
          (should (string-match-p "\\[ni\\]" captured-prompt))
          (should (string-match-p "1\\.你" captured-prompt)))))))


(ert-deftest rimel-test-composition-loop-unhandled-key ()
  "Test that unhandled keys exit and push back event."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-input "ni"
        rimel-test--rime-preedit "ni"
        rimel-test--rime-candidates '("你"))
  (with-temp-buffer
    (cl-letf (((symbol-function 'read-event)
               (lambda (&optional _prompt) 'f1)))           ; unhandled non-char key
      (let ((unread-command-events nil))
        (rimel--composition-loop)
        (should (memq 'f1 unread-command-events))))))     ; key pushed back

;; -----------------------------------------------------------------------
;; Test: update-display
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-update-display-inline-candidate ()
  "Test that update-display shows commit-text-preview for inline candidate mode."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-preedit "ni hao"
        rimel-test--rime-commit-preview "你好"
        rimel-test--rime-candidates '("你好"))
  (with-temp-buffer
    (insert "test ")
    (let ((rimel-inline-preedit 'candidate)
          (rimel-show-candidate nil))
      (rimel--update-display)
      (should (overlayp rimel--preedit-overlay))           ; overlay created
      (let ((as (overlay-get rimel--preedit-overlay 'after-string)))
        (should (equal "你好" (substring-no-properties as))))) ; shows preview
    (rimel--clear-preedit)))

(ert-deftest rimel-test-update-display-inline-preedit ()
  "Test that update-display shows preedit for inline preedit mode."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-preedit "ni hao"
        rimel-test--rime-candidates '("你好"))
  (with-temp-buffer
    (insert "test ")
    (let ((rimel-inline-preedit t)
          (rimel-show-candidate nil))
      (rimel--update-display)
      (should (overlayp rimel--preedit-overlay))           ; overlay created
      (let ((as (overlay-get rimel--preedit-overlay 'after-string)))
        (should (equal "ni hao" (substring-no-properties as))))) ; shows preedit
    (rimel--clear-preedit)))

(ert-deftest rimel-test-update-display-no-inline ()
  "Test that update-display skips overlay when inline disabled."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-preedit "ni"
        rimel-test--rime-candidates '("你"))
  (with-temp-buffer
    (insert "test ")
    (let ((rimel-inline-preedit nil)
          (rimel-show-candidate nil))
      (rimel--update-display)
      (should-not rimel--preedit-overlay))))               ; no overlay

;; -----------------------------------------------------------------------
;; Test: convert-string-at-point
;; -----------------------------------------------------------------------

(ert-deftest rimel-test-find-entered-at-point-basic ()
  "Extract the code string before point."
  (with-temp-buffer
    (insert "nihao")
    (should (equal '("nihao" 5) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-after-text ()
  "Only the trailing code run before point is extracted."
  (with-temp-buffer
    (insert "abc nihao")
    (should (equal '("nihao" 5) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-trailing-space ()
  "Trailing spaces are skipped but counted for deletion."
  (with-temp-buffer
    (insert "nihao ")
    (should (equal '("nihao" 6) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-leading-quote ()
  "A leading quote or hyphen (string delimiter) is left in place."
  (with-temp-buffer
    (insert "'nihao")
    (should (equal '("nihao" 5) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-separator ()
  "Interior apostrophes (syllable separators) are kept."
  (with-temp-buffer
    (insert "ni'hao")
    (should (equal '("ni'hao" 6) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-region ()
  "An active region is used instead of the line prefix."
  (with-temp-buffer
    (transient-mark-mode 1)
    (insert "nihao")
    (push-mark (point-min) t t)
    (should (equal '("nihao" 5) (rimel--find-entered-at-point)))))

(ert-deftest rimel-test-find-entered-at-point-no-match ()
  "Return nil when there is no code string at point."
  (with-temp-buffer
    (insert "123")
    (should-not (rimel--find-entered-at-point)))
  (with-temp-buffer
    (should-not (rimel--find-entered-at-point))))

(ert-deftest rimel-test-should-enable-p-force ()
  "The force flag overrides disable predicates."
  (let ((rimel--force-input-chinese t)
        (rimel-disable-predicates (list (lambda () t))))
    (should (rimel--should-enable-p))))

(ert-deftest rimel-test-clear-state-resets-force-flag ()
  "Clearing state also resets the force-Chinese flag."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (let ((rimel--force-input-chinese t))
      (rimel--clear-state)
      (should-not rimel--force-input-chinese))))

(ert-deftest rimel-test-composition-loop-resets-force-flag ()
  "Exiting the composition loop resets the force-Chinese flag."
  (rimel-test--reset-rime)
  (setq rimel-test--rime-input "ni"
        rimel-test--rime-preedit "ni"
        rimel-test--rime-candidates '("你" "妮"))
  (with-temp-buffer
    (let ((rimel--force-input-chinese t))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&optional _prompt) ?1)))
        (rimel--composition-loop)
        (should-not rimel--force-input-chinese)))))

(ert-deftest rimel-test-convert-string-at-point ()
  "Convert deletes the code string and feeds it back as unread events."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (insert "nihao")
    (let ((unread-command-events nil)
          (rimel--force-input-chinese nil))
      (rimel-convert-string-at-point)
      (should (equal "" (buffer-string)))
      (should (equal '(?n ?i ?h ?a ?o)
                     (mapcar (lambda (e) (if (consp e) (cdr e) e))
                             unread-command-events)))
      (should rimel--force-input-chinese))))

(ert-deftest rimel-test-convert-string-at-point-region ()
  "Convert uses the active region when one exists."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (transient-mark-mode 1)
    (rimel-activate "rimel")
    (insert "nihao")
    (push-mark (point-min) t t)
    (let ((unread-command-events nil)
          (rimel--force-input-chinese nil))
      (rimel-convert-string-at-point)
      (should (equal "" (buffer-string)))
      (should (equal '(?n ?i ?h ?a ?o)
                     (mapcar (lambda (e) (if (consp e) (cdr e) e))
                             unread-command-events))))))

(ert-deftest rimel-test-convert-string-at-point-no-code ()
  "With no code string at point, nothing is deleted or fed."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (insert "123")
    (let ((unread-command-events nil)
          (rimel--force-input-chinese nil))
      (rimel-convert-string-at-point)
      (should (equal "123" (buffer-string)))
      (should-not unread-command-events)
      (should-not rimel--force-input-chinese))))

(ert-deftest rimel-test-convert-string-at-point-activates-im ()
  "The command activates rimel when it is not the current input method."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (insert "ni")
    (let ((unread-command-events nil)
          (rimel--force-input-chinese nil))
      (rimel-convert-string-at-point)
      (should (eq input-method-function #'rimel-input-method)))))

(ert-deftest rimel-test-convert-string-at-point-integration ()
  "Fed events flow through `rimel-input-method' to a commit."
  (rimel-test--reset-rime)
  (with-temp-buffer
    (rimel-activate "rimel")
    (insert "ni")
    ;; Predicates would normally block conversion; the force flag bypasses them.
    (let ((unread-command-events nil)
          (rimel--force-input-chinese nil)
          (rimel-disable-predicates (list (lambda () t))))
      (rimel-convert-string-at-point)
      (setq rimel-test--process-key-hook
            (lambda (_key _mask)
              (when (string= rimel-test--rime-input "ni")
                (setq rimel-test--rime-preedit "ni"
                      rimel-test--rime-candidates '("你")))))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&optional _prompt)
                   ;; Drain fed events, then select the first candidate.
                   (if unread-command-events
                       (let ((e (pop unread-command-events)))
                         (if (consp e) (cdr e) e))
                     ?1))))
        (let* ((first (pop unread-command-events))
               (result (rimel-input-method (if (consp first) (cdr first) first))))
          (should (equal '(?你) result))
          (should-not rimel--force-input-chinese))))))

(provide 'rimel-test)

;;; rimel-test.el ends here
