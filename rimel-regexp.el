;;; rimel-regexp.el --- Search Chinese text with Rime codes  -*- lexical-binding: t; -*-

;; Author: jixiuf
;; URL: https://github.com/emacs-rime/rimel
;; Version: 0.1.2
;; Package-Requires: ((emacs "29.4") (liberime "0.0.11"))
;; Keywords: convenience, i18n, matching

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; `rimel-regexp-mode' expands lower-case Rime codes in searches.  For
;; example, a search for "ni" can match both the literal code and candidates
;; such as "你".  The mode integrates with isearch, `orderless-regexp', and
;; Evil's `evil-ex-search-full-pattern' when those functions are available.
;; Optional Avy integration lives in `rimel-regexp-avy' (see
;; rimel-regexp-avy.el); Avy is loaded lazily when that mode is enabled.
;;
;; Candidate lookup runs in a temporary Rime session via `liberime-search',
;; so an ongoing composition in the default session is never disturbed.  The
;; shortest prefix candidates may be composed recursively, but every
;; generated expansion must consume the complete supplied code.
;;
;; Basic setup:
;;
;;   (require 'rimel-regexp)
;;   (rimel-regexp-mode 1)

;;; Code:

(require 'isearch)
(require 'subr-x)

(declare-function liberime-load "liberime")
(declare-function liberime-workable-p "liberime")
(declare-function liberime-get-status "ext:liberime-core")
(declare-function liberime-search "ext:liberime-core"
                  (string &optional limit index schema-id full-context session))
(declare-function liberime-session-create "ext:liberime-core"
                  (&optional schema-id))
(declare-function liberime-session-destroy "ext:liberime-core" (session))

(defgroup rimel-regexp nil
  "Build regular expressions from Rime candidates."
  :group 'convenience
  :prefix "rimel-regexp-")

(defcustom rimel-regexp-schema-id nil
  "Rime schema used for candidate lookup.

When nil, the schema of the default session is used.  Set this to a schema
ID from `liberime-get-schema-list' (e.g. \"luna_pinyin_simp\") to always
search with a specific schema, independent of the input method currently
active in the default session."
  :type '(choice (const :tag "Default session schema" nil)
                 (string :tag "Schema ID"))
  :group 'rimel-regexp)

(defcustom rimel-regexp-max-code-length 0
  "Maximum Rime code length to expand.

A value less than or equal to zero means no limit.  Set this to the maximum
code length of a shape-based input method to prevent a long English word from
being split and partially converted by Rime."
  :type 'integer
  :group 'rimel-regexp)

(defcustom rimel-regexp-candidate-limit 100
  "Maximum number of Rime candidates examined for one code.

Nil or a non-positive value means no limit.  Keeping this value bounded is
recommended for incremental search because short codes can have thousands of
candidates."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Maximum candidates"))
  :group 'rimel-regexp)

(defcustom rimel-regexp-cache-size 256
  "Maximum number of candidate queries cached.

A non-positive value disables caching.  The whole cache is cleared when this
many entries have accumulated."
  :type 'integer
  :group 'rimel-regexp)

(defcustom rimel-regexp-omit-code-separators t
  "Whether whitespace between adjacent Rime codes may match nothing.

When non-nil, a query such as `ni shijie' can match contiguous Chinese text
such as `你世界'.  The whitespace remains an alternative, so text
which contains the original separator can still match."
  :type 'boolean
  :group 'rimel-regexp)

(defconst rimel-regexp--code-pattern "[a-z][a-z']*"
  "Regexp matching a Rime code embedded in a search string.")

(defconst rimel-regexp--advised-functions
  '(orderless-regexp evil-ex-search-full-pattern))

(defconst rimel-regexp--unset (make-symbol "unset"))

(defvar rimel-regexp--candidate-cache (make-hash-table :test #'equal)
  "Cache candidate queries and their generated regexps.")

(defvar rimel-regexp--saved-isearch-search-fun-function nil)

(defvar rimel-regexp--search-session nil
  "Temporary session reused for all lookups of one expansion.

Bound dynamically around `rimel-regexp-build-regexp-string' when the
string contains several Rime codes, so creating and destroying a
session is paid once instead of once per code.")

(defun rimel-regexp--candidate-limit ()
  "Return the effective candidate limit, or nil for no limit."
  (and rimel-regexp-candidate-limit
       (> rimel-regexp-candidate-limit 0)
       rimel-regexp-candidate-limit))

(defun rimel-regexp--schema-id ()
  "Return the schema used for candidate lookup."
  (or rimel-regexp-schema-id
      (alist-get 'schema_id (liberime-get-status))))

(defun rimel-regexp-clear-cache ()
  "Clear cached Rime candidate queries."
  (interactive)
  (clrhash rimel-regexp--candidate-cache))

(defun rimel-regexp--normalize-candidates (candidates)
  "Return CANDIDATES without empty strings or duplicates."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (candidate candidates)
      (setq candidate (substring-no-properties candidate))
      (unless (or (string-empty-p candidate) (gethash candidate seen))
        (puthash candidate t seen)
        (push candidate result)))
    (nreverse result)))

(defun rimel-regexp--search-query (code)
  "Return candidate expansion data for Rime code CODE.

The search runs in a temporary Rime session created by
`liberime-search', so an ongoing composition in the default session is left
untouched and the schema of the default session is unchanged.  The result is
an internal plist describing how candidates consume CODE:

  `:commit'          Text Rime committed automatically.  Shape-based
                     schemas push out a completed word when the code grows
                     too long, and that word no longer appears in the
                     candidate menu; nil when nothing was committed.
  `:full'            Candidates consuming CODE completely, such as the word
                     candidate of a complete code.
  `:prefix'          Candidates consuming only the shortest non-empty
                     prefix of CODE.  Pinyin schemas offer single-character
                     candidates while later syllables are still being
                     typed, so these consume only part of the code.
  `:remainder'       The code suffix left after the shortest prefix.  It is
                     fed back into `rimel-regexp--code-regexp'
                     recursively to cover cross-boundary text.
  `:remaining-input' The full original input code, used to decide whether
                     `:commit' is trustworthy: a commit followed by
                     residual input and no candidates is only an
                     automatically committed prefix.
  `:schema-id'       The schema the temporary session actually used (and
                     `:schema-name', `:is-ascii-mode', `:is-full-shape',
                     `:is-simplified', `:is-traditional', `:is-ascii-punct'
                     and `:is-disabled'), as reported by liberime-search.

The schema comes from `rimel-regexp-schema-id'; nil means the schema
of the default session.

All candidate strings are normalized (properties stripped, empty strings
and duplicates removed) by `rimel-regexp--normalize-candidates'."
  (let* ((result (liberime-search code
                                  (rimel-regexp--candidate-limit)
                                  nil
                                  rimel-regexp-schema-id
                                  t
                                  rimel-regexp--search-session))
         (commit (plist-get result :commit))
         (full (rimel-regexp--normalize-candidates
                (plist-get result :full)))
         (prefix (rimel-regexp--normalize-candidates
                  (plist-get result :prefix)))
         (remainder (plist-get result :remainder))
         (remaining-input (plist-get result :remaining-input))
         (schema-id (plist-get result :schema-id)))
    ;; A commit followed by unusable residual input can itself be only an
    ;; automatically committed prefix, so do not expose it as a complete
    ;; expansion.
    (when (and commit
               (null full)
               (null prefix)
               remaining-input
               (not (string-empty-p remaining-input)))
      (setq commit nil))
    (and (or commit full prefix)
         ;; :regexp-code and :regexp must exist (nil) in the plist from
         ;; the start: `setf' on a missing `plist-get' key would rebind
         ;; the variable to a fresh list instead of modifying the cached
         ;; plist, silently disabling the regexp cache.
         (list :commit commit
               :full full
               :prefix prefix
               :remainder remainder
               :remaining-input remaining-input
               :schema-id schema-id
               :regexp-code nil
               :regexp nil))))

(defun rimel-regexp--cache-result (key result)
  "Cache RESULT under KEY when caching is enabled, then return RESULT."
  (when (> rimel-regexp-cache-size 0)
    (when (>= (hash-table-count rimel-regexp--candidate-cache)
              rimel-regexp-cache-size)
      (rimel-regexp-clear-cache))
    (puthash key result rimel-regexp--candidate-cache))
  result)

(defun rimel-regexp-load-liberime ()
  "Load and start liberime if necessary."
  (unless (featurep 'liberime-core)
    (require 'liberime))
  (unless (liberime-workable-p)
    (liberime-load)))

(defun rimel-regexp--query-code (str)
  "Return cached candidate expansion data for Rime code STR.

The result is an internal plist produced by
`rimel-regexp--search-query'.  Return nil if STR is invalid, too
long according to `rimel-regexp-max-code-length', or has no expansions."
  (let ((code (replace-regexp-in-string "'" "" str t t)))
    (when (and (not (string-empty-p code))
               (let ((case-fold-search nil))
                 (string-match-p "\\`[a-z']+\\'" str))
               (or (<= rimel-regexp-max-code-length 0)
                   (<= (length code) rimel-regexp-max-code-length)))
      (rimel-regexp-load-liberime)
      (let* ((key (list code
                        (rimel-regexp--candidate-limit)
                        (rimel-regexp--schema-id)))
             (cached (gethash key rimel-regexp--candidate-cache
                              rimel-regexp--unset)))
        (if (not (eq cached rimel-regexp--unset))
            cached
          (rimel-regexp--cache-result
           key
           (rimel-regexp--search-query code)))))))

(defun rimel-regexp-get-candidates-list (str)
  "Return the Rime commit and full-consumption candidates for code STR.

The return value has the form (COMMIT . CANDIDATES).  COMMIT is nil unless
Rime automatically committed a prefix.  For example, possible results are:

  (nil 计算 谋算)
  (计算 与 瓦)

STR must contain only lower-case ASCII letters and apostrophes.  Apostrophes
are removed before the code is sent to Rime.  Candidates which consume only a
prefix of STR are discarded.  Return nil if STR is invalid, too long according
to `rimel-regexp-max-code-length', or has no matches."
  (let* ((query (rimel-regexp--query-code str))
         (commit (plist-get query :commit))
         (full (plist-get query :full))
         (remaining-input (plist-get query :remaining-input)))
    (when (or full
              (and commit
                   (or (null remaining-input)
                       (string-empty-p remaining-input))))
      (cons commit full))))

(defun rimel-regexp--code-regexp (code)
  "Return a regexp matching CODE or any of its Rime expansions.

The regexp is the alternation of a base group and a recursive group.  The
base group covers the literal CODE and the candidates that consume it
completely (`:full'), prefixed by any automatically committed text
(`:commit').  The recursive group takes the shortest-prefix candidates
(`:prefix'), optionally prefixed by `:commit', and appends the expansion of
`rimel-regexp--code-regexp' on `:remainder'.  For example, the expansion
of `nihaoshijie' includes the shortest-prefix candidate for `ni' followed
by the expansion of `haoshijie', so a phrase spanning those code
boundaries matches through the recursive path as well as directly through
`:full'."
  (let* ((query (rimel-regexp--query-code code))
         (cached (and (equal code (plist-get query :regexp-code))
                      (plist-get query :regexp))))
    (or cached
        (let* ((commit (plist-get query :commit))
               (full (plist-get query :full))
               (prefix (plist-get query :prefix))
               (remainder (plist-get query :remainder))
               (remaining-input (plist-get query :remaining-input))
               (converted
                (cond
                 ((and commit full)
                  (mapcar (lambda (candidate)
                            (concat commit candidate))
                          full))
                 (full full)
                 ((and commit
                       (or (null remaining-input)
                           (string-empty-p remaining-input)))
                  (list commit))))
               (base (regexp-opt (cons code converted)))
               (recursive
                (and prefix
                     (concat
                      (regexp-opt
                       (if commit
                           (mapcar (lambda (candidate)
                                     (concat commit candidate))
                                   prefix)
                         prefix))
                      (rimel-regexp--code-regexp remainder))))
               (regexp (if recursive
                           (format "\\(?:%s\\|%s\\)" base recursive)
                         base)))
          (when query
            (setf (plist-get query :regexp-code) code
                  (plist-get query :regexp) regexp))
          regexp))))

(defun rimel-regexp--tokenize (str)
  "Split STR into tagged Rime-code and literal tokens."
  (let ((case-fold-search nil)
        (position 0)
        tokens)
    (while (string-match rimel-regexp--code-pattern str position)
      (let ((beginning (match-beginning 0))
            (end (match-end 0)))
        (when (> beginning position)
          (push (cons 'literal (substring str position beginning)) tokens))
        (push (cons 'code (match-string 0 str)) tokens)
        (setq position end)))
    (when (< position (length str))
      (push (cons 'literal (substring str position)) tokens))
    (nreverse tokens)))

(defun rimel-regexp-build-regexp-string (str &optional literal)
  "Build a regexp from Rime codes embedded in STR.

Lower-case code runs are expanded independently, so every part of
`ni shijie' has one-to-many candidate matching.  When LITERAL is non-nil,
quote non-code parts of STR; this is used for non-regexp isearch.

When STR contains several Rime codes, all lookups share one temporary
session (see `rimel-regexp--search-session') so the session setup cost is
paid once instead of once per code."
  (let* ((tokens (vconcat (rimel-regexp--tokenize str)))
         (count (length tokens))
         (code-count 0)
         (rimel-regexp--search-session nil)
         pieces)
    (dotimes (index count)
      (when (eq (car (aref tokens index)) 'code)
        (setq code-count (1+ code-count))))
    (when (> code-count 1)
      (setq rimel-regexp--search-session (liberime-session-create)))
    (unwind-protect
        (progn
          (dotimes (index count)
            (let* ((token (aref tokens index))
                   (kind (car token))
                   (text (cdr token)))
              (push
               (pcase kind
                 ('code (rimel-regexp--code-regexp text))
                 ('literal
                  (if (and rimel-regexp-omit-code-separators
                           (> index 0)
                           (< index (1- count))
                           (eq (car (aref tokens (1- index))) 'code)
                           (eq (car (aref tokens (1+ index))) 'code)
                           (string-match-p "\\`[[:space:]]+\\'" text))
                      (format "\\(?:%s\\)?" (regexp-quote text))
                    (if literal (regexp-quote text) text))))
               pieces)))
          (mapconcat #'identity (nreverse pieces) ""))
      (when rimel-regexp--search-session
        (liberime-session-destroy rimel-regexp--search-session)))))

(defun rimel-regexp-filter-args (args)
  "Replace the first string in ARGS with its Rime-aware regexp."
  (cons (rimel-regexp-build-regexp-string (car args)) (cdr args)))

(defun rimel-regexp--isearch-search-function ()
  "Return an isearch function which expands Rime codes."
  (let ((base (or rimel-regexp--saved-isearch-search-fun-function
                  #'isearch-search-fun-default)))
    (if isearch-regexp-function
        ;; Preserve word and symbol isearch semantics.
        (funcall base)
      (let ((literal (not isearch-regexp)))
        (lambda (string &optional bound noerror _count)
          ;; The transformed string is always a regexp, even for an ordinary
          ;; literal isearch, so search it with `isearch-search-fun-default'
          ;; directly.  Chaining the saved provider would re-apply its own
          ;; pattern conversion (e.g. helixel's PCRE converter) to an
          ;; already-expanded elisp regexp and corrupt it.  Three arguments
          ;; match the calling convention of `isearch-search-string'.
          (let ((isearch-regexp t)
                (isearch-regexp-function nil))
            (funcall (isearch-search-fun-default)
                     (rimel-regexp-build-regexp-string string literal)
                     bound noerror)))))))

;; helixel integration -------------------------------------------------------
;; None: helixel installs a buffer-local `isearch-search-fun-function' that
;; delegates literal searches to the global provider (see helixel's own
;; `helixel-search--pcre-isearch-search-fun-function'), so the global Rime
;; expansion is picked up automatically.  Keeping helixel knowledge out of
;; this file avoids coupling to helixel internals.

(defun rimel-regexp--update-advices (enable)
  "Add search advices when ENABLE is non-nil, otherwise remove them.

Advices are managed only from `rimel-regexp-mode', so packages such as
`orderless' or `evil-search' must be loaded before the mode is enabled
for their integration to take effect."
  (dolist (function rimel-regexp--advised-functions)
    (when (fboundp function)
      (if enable
          (unless (advice-member-p #'rimel-regexp-filter-args function)
            (advice-add function :filter-args
                        #'rimel-regexp-filter-args))
        (when (advice-member-p #'rimel-regexp-filter-args function)
          (advice-remove function #'rimel-regexp-filter-args))))))

(defun rimel-regexp--install-integrations ()
  "Install integrations for currently loaded packages."
  (rimel-regexp--update-advices t)
  (unless rimel-regexp--saved-isearch-search-fun-function
    ;; Save the global value, not the buffer-local one: the current buffer
    ;; may shadow `isearch-search-fun-function' with a provider such as
    ;; helixel's PCRE converter, whose search function accepts only three
    ;; arguments.  Chaining that as BASE would break the call below.
    (setq rimel-regexp--saved-isearch-search-fun-function
          (default-value 'isearch-search-fun-function)))
  (setq-default isearch-search-fun-function
                #'rimel-regexp--isearch-search-function))

(defun rimel-regexp--remove-integrations ()
  "Remove all integrations installed by this package."
  (rimel-regexp--update-advices nil)
  (when rimel-regexp--saved-isearch-search-fun-function
    ;; Do not overwrite a provider installed by another package while this
    ;; mode was active.
    (when (eq (default-value 'isearch-search-fun-function)
              #'rimel-regexp--isearch-search-function)
      (setq-default isearch-search-fun-function
                    rimel-regexp--saved-isearch-search-fun-function))
    (setq rimel-regexp--saved-isearch-search-fun-function nil)))

;;;###autoload
(define-minor-mode rimel-regexp-mode
  "Globally expand lower-case Rime codes in supported searches."
  :global t
  :group 'rimel-regexp
  (if rimel-regexp-mode
      (progn
        (rimel-regexp-load-liberime)
        (rimel-regexp-clear-cache)
        (rimel-regexp--install-integrations))
    (rimel-regexp--remove-integrations)
    (rimel-regexp-clear-cache)))

;;;###autoload
(defun rimel-regexp-enable ()
  "Enable `rimel-regexp-mode'."
  (rimel-regexp-mode 1))

(with-eval-after-load 'orderless
  (when (bound-and-true-p rimel-regexp-mode)
    (rimel-regexp--update-advices t)))

(with-eval-after-load 'evil-search
  (when (bound-and-true-p rimel-regexp-mode)
    (rimel-regexp--update-advices t)))

(provide 'rimel-regexp)

;;; rimel-regexp.el ends here
