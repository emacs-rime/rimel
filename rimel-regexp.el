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

(defcustom rimel-regexp-code-predicate nil
  "Predicate deciding whether a code is worth a Rime lookup.

When non-nil, it is called with one argument, a lower-case code
with apostrophes removed, and should return non-nil only for
codes which may expand to useful candidates.  A rejected code is
expanded to its literal text without touching Rime, so English
words cost nothing.

Install `rimel-regexp-pinyin-code-p' for full-pinyin schemas.
Leave this nil for shape-based or double-pinyin schemas, whose
codes must always be looked up."
  :type '(choice (const :tag "Always look up" nil)
                 (function :tag "Predicate"))
  :group 'rimel-regexp)

(defcustom rimel-regexp-max-recursion-depth 2
  "Maximum recursive prefix-expansion levels per code.

The recursive group covers text which no whole-code candidate
matches; each level costs one extra Rime lookup for the remaining
code.  Recursion is skipped entirely whenever a full candidate
already consumes the code.  Zero disables recursive expansion."
  :type 'integer
  :group 'rimel-regexp)

(defconst rimel-regexp-pinyin-syllables
  (concat
   "a ai an ang ao e ei en eng er o ou "
   "ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu "
   "pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu "
   "ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu "
   "fa fan fang fei fen feng fo fou fu "
   "da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo "
   "ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo "
   "na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nue nv nve "
   "la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve "
   "ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo "
   "ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo "
   "ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo "
   "ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun "
   "qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun "
   "xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun "
   "zha zhai zhan zhang zhao zhe zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo "
   "cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo "
   "sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo "
   "ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo "
   "za zai zan zang zao ze zei zen zeng zi zong zou zu zuan zui zun zuo "
   "ca cai can cang cao ce cen ceng ci cong cou cu cuan cui cun cuo "
   "sa sai san sang sao se sen seng si song sou su suan sui sun suo "
   "ya yai yan yang yao ye yi yin ying yo yong you yu yuan yue yun "
   "wa wai wan wang wei wen weng wo wu")
  "Space-separated standard Mandarin pinyin syllables, used by
`rimel-regexp-pinyin-code-p'.")

(defconst rimel-regexp--pinyin-syllable-table
  (let ((table (make-hash-table :test #'equal)))
    (dolist (syllable (split-string rimel-regexp-pinyin-syllables))
      (puthash syllable t table))
    table)
  "Hash set of `rimel-regexp-pinyin-syllables'.")

(defconst rimel-regexp--pinyin-initial-table
  (let ((table (make-hash-table :test #'equal)))
    (dolist (syllable (split-string rimel-regexp-pinyin-syllables))
      (puthash (substring syllable 0 1) t table))
    table)
  "Hash set of letters which begin a pinyin syllable.

A single letter of a code is accepted as the abbreviation of one
syllable when it is in this set.  The letters i and u never begin
a syllable and are therefore rejected on their own.")

(defun rimel-regexp--pinyin-accepted-p (code)
  "Return non-nil when CODE segments into standard pinyin syllables.

CODE must contain only lower-case letters.  Every segment must be
a full syllable or a single abbreviation letter.  A code longer
than four letters must be covered by multi-letter syllables for
at least half of its length plus one, which rejects English
words made of short segments such as `searchforward', `hello'
and `xhtml'.  Words built from longer syllable runs (buffer ->
bu f f er) still pass; the isearch literal fast path keeps them
zero-cost anyway."
  (let* ((len (length code))
         ;; covered[end] is the maximum number of letters a valid
         ;; segmentation of the first END letters covers with
         ;; multi-letter syllables, or -1 when unreachable.
         (covered (make-vector (1+ len) -1)))
    (aset covered 0 0)
    (dotimes (start len)
      (when (>= (aref covered start) 0)
        ;; Syllables are at most six letters long (zhuang, chuang).
        (let ((end-max (min len (+ start 6)))
              (sub-end (1+ start)))
          (while (<= sub-end end-max)
            (let* ((sub (substring code start sub-end))
                   (base (aref covered start))
                   (gain
                    (cond
                     ((and (>= (length sub) 2)
                           (gethash sub rimel-regexp--pinyin-syllable-table))
                      (length sub))
                     ((and (= sub-end (1+ start))
                           (gethash sub rimel-regexp--pinyin-initial-table))
                      0))))
              (when gain
                (let ((total (+ base gain)))
                  (when (> total (aref covered sub-end))
                    (aset covered sub-end total)))))
            (setq sub-end (1+ sub-end))))))
    (and (>= (aref covered len) 0)
         (or (<= len 4)
             (>= (aref covered len) (/ (1+ len) 2))))))

(defun rimel-regexp-pinyin-code-p (code)
  "Return non-nil when CODE is a plausible standard-pinyin code.

Accepts full-syllable segmentations (nihao -> ni hao), initial
abbreviations (sj -> s j), and mixes of both (nisj -> ni s j).
Codes of at most four letters are accepted whenever they
segment at all; longer codes must be at least half covered by
full syllables, which rejects English words such as `buffer',
`searchforward' and `xhtml' while keeping real abbreviations
like `sj'.  Single-letter codes are accepted only for letters
which begin a pinyin syllable (i and u are not syllable
initials).

Intended as a `rimel-regexp-code-predicate' for full-pinyin
schemas; do not install it for shape-based or double-pinyin
schemas, whose codes are not standard pinyin."
  (let ((len (length code)))
    (and (> len 0)
         (rimel-regexp--pinyin-accepted-p code))))

(defconst rimel-regexp--code-pattern "[a-z][a-z']*"
  "Regexp matching a Rime code embedded in a search string.")

(defconst rimel-regexp--advised-functions
  '(orderless-regexp evil-ex-search-full-pattern))

(defconst rimel-regexp--unset (make-symbol "unset"))

(defvar rimel-regexp--candidate-cache (make-hash-table :test #'equal)
  "Cache candidate queries and their generated regexps.")

(defvar rimel-regexp--saved-isearch-search-fun-function nil)

(defvar rimel-regexp--search-session nil
  "Persistent Rime session shared by all candidate lookups.

Created on demand by the first lookup which actually reaches Rime, so
searches served entirely from the candidate cache pay no session setup
at all.  A persistent session means liberime's session setup and schema
switch are paid once per schema instead of once per search: in one
measurement the per-search cost dropped from ~140ms to ~0.5ms.  The
default session is never touched: each search clears the composition
first, and the schema selected on this session is independent of the
input method session.")

(defvar rimel-regexp--search-session-schema nil
  "Schema currently selected on `rimel-regexp--search-session'.")

(defvar rimel-regexp--search-session-schema-pending nil
  "Schema still to be selected on `rimel-regexp--search-session'.

`liberime-search' switches the schema - and Switcher::SetActiveSchema
persists var/previously_selected_schema to user.yaml - every time a
schema is passed explicitly, which costs far more than the lookup
itself.  Only the first lookup after a session (re)creation passes the
configured schema so that it is selected once; later lookups pass nil
and reuse the schema the session already has.")

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

(defun rimel-regexp--reset-search-session ()
  "Destroy the persistent search session, if any."
  (when rimel-regexp--search-session
    (ignore-errors
      (liberime-session-destroy rimel-regexp--search-session)))
  (setq rimel-regexp--search-session nil
        rimel-regexp--search-session-schema nil
        rimel-regexp--search-session-schema-pending nil))

(defun rimel-regexp--session-for-query ()
  "Return the persistent search session, creating it on demand.

The session is (re)created when it does not exist yet or when the
wanted schema changed (for example because `rimel-regexp-schema-id' or
the default session's schema changed), so cached lookups never pay for
session setup or schema switches."
  (let ((wanted (rimel-regexp--schema-id)))
    (unless (and rimel-regexp--search-session
                 (equal wanted rimel-regexp--search-session-schema))
      (rimel-regexp--reset-search-session)
      (setq rimel-regexp--search-session (liberime-session-create)
            rimel-regexp--search-session-schema wanted
            rimel-regexp--search-session-schema-pending wanted))
    rimel-regexp--search-session))

(defun rimel-regexp--schema-for-query ()
  "Return the schema argument for one `liberime-search' call.

Only the first lookup after a session (re)creation passes a schema: it
is selected on the session once, and later lookups pass nil so that
liberime does not switch the schema (and persist user.yaml) again."
  (prog1 rimel-regexp--search-session-schema-pending
    (setq rimel-regexp--search-session-schema-pending nil)))

(defun rimel-regexp--search-query (code)
  "Return candidate expansion data for Rime code CODE.

The search never touches the default session: all lookups share the
persistent session from `rimel-regexp--session-for-query', so an
ongoing composition in the default session is left untouched and its
schema is unchanged.  The result is an internal plist describing how
candidates consume CODE:

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
  `:schema-id'       The schema the session actually used (and
                     `:schema-name', `:is-ascii-mode', `:is-full-shape',
                     `:is-simplified', `:is-traditional', `:is-ascii-punct'
                     and `:is-disabled'), as reported by liberime-search.

The schema comes from `rimel-regexp-schema-id'; nil means the schema
of the default session.

All candidate strings are normalized (properties stripped, empty strings
and duplicates removed) by `rimel-regexp--normalize-candidates'."
  (condition-case _err
      (rimel-regexp--search-query-1 code)
    ;; The persistent session can die across `liberime-deploy' or
    ;; `liberime-finalize'; recreate it once and retry.
    (error
     (rimel-regexp--reset-search-session)
     (rimel-regexp--search-query-1 code))))

(defun rimel-regexp--search-query-1 (code)
  "Worker of `rimel-regexp--search-query'; see there for the plist docs."
  ;; The session must be resolved first: it decides whether this lookup is
  ;; the one which selects the configured schema.
  (let* ((session (rimel-regexp--session-for-query))
         (schema (rimel-regexp--schema-for-query))
         (result (liberime-search code
                                  (rimel-regexp--candidate-limit)
                                  nil
                                  schema
                                  t
                                  session))
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
long according to `rimel-regexp-max-code-length', rejected by
`rimel-regexp-code-predicate', or has no expansions."
  (let ((code (replace-regexp-in-string "'" "" str t t)))
    (when (and (not (string-empty-p code))
               (let ((case-fold-search nil))
                 (string-match-p "\\`[a-z']+\\'" str))
               (or (<= rimel-regexp-max-code-length 0)
                   (<= (length code) rimel-regexp-max-code-length))
               (or (null rimel-regexp-code-predicate)
                   (funcall rimel-regexp-code-predicate code)))
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

(defun rimel-regexp--code-regexp (code &optional depth)
  "Return a regexp matching CODE or any of its Rime expansions.

The regexp is the alternation of a base group and an optional
recursive group.  The base group covers the literal CODE and the
candidates that consume it completely (`:full'), prefixed by any
automatically committed text (`:commit').  The recursive group is
built only when nothing consumes the whole code (`:full' empty):
it takes the shortest-prefix candidates (`:prefix'), optionally
prefixed by `:commit', and appends the expansion of
`rimel-regexp--code-regexp' on `:remainder', down to
`rimel-regexp-max-recursion-depth' levels.  For example, the
expansion of `nihaoshijie' includes the shortest-prefix candidate
for `ni' followed by the expansion of `haoshijie', so a phrase
spanning those code boundaries matches through the recursive path
as well as directly through `:full'.

DEPTH is the current recursion level.  Cached regexps are stored
only for top-level calls; deeper calls recompute (cheap elisp)
and, when they do meet a cached entry from depth zero, that
regexp is a superset of what their own depth would generate and
therefore safe to use."
  (setq depth (or depth 0))
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
                     (not full)
                     (< depth rimel-regexp-max-recursion-depth)
                     (concat
                      (regexp-opt
                       (if commit
                           (mapcar (lambda (candidate)
                                     (concat commit candidate))
                                   prefix)
                         prefix))
                      (rimel-regexp--code-regexp remainder (1+ depth)))))
               (regexp (if recursive
                           (format "\\(?:%s\\|%s\\)" base recursive)
                         base)))
          ;; Cache top-level regexps only: a regexp built at a deeper
          ;; recursion level depends on DEPTH, which the query plist does
          ;; not record.  Deeper calls recompute; if they meet a cached
          ;; entry from depth zero, that regexp is a superset of their
          ;; own and therefore safe to use.
          (when (and query (zerop depth))
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

All lookups share the persistent session from
`rimel-regexp--session-for-query'; session setup and schema switches
are paid once per schema instead of once per build."
  (let* ((tokens (vconcat (rimel-regexp--tokenize str)))
         (count (length tokens))
         pieces)
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
    (mapconcat #'identity (nreverse pieces) "")))

(defun rimel-regexp-filter-args (args)
  "Replace the first string in ARGS with its Rime-aware regexp."
  (cons (rimel-regexp-build-regexp-string (car args)) (cdr args)))

(defun rimel-regexp--isearch-search-function ()
  "Return an isearch function which expands Rime codes lazily.

The literal pattern is always tried first; Rime expansion only
runs when the literal pattern does not match, or when isearch is
repeating the current search (this-command
`isearch-repeat-forward'/'isearch-repeat-backward').  Searching
for an English word which occurs in the buffer therefore never
reaches Rime, while a pinyin code - which usually does not occur
literally - still expands on the first keystroke.  Repeating a
search escalates to the expansion even when the literal pattern
matched, so Chinese candidates stay reachable when the pattern
also occurs as literal text."
  (let ((base (or rimel-regexp--saved-isearch-search-fun-function
                  #'isearch-search-fun-default)))
    (if isearch-regexp-function
        ;; Preserve word and symbol isearch semantics.
        (funcall base)
      (let ((literal (not isearch-regexp)))
        (lambda (string &optional bound noerror count)
          (or (and (not (memq this-command
                              '(isearch-repeat-forward
                                isearch-repeat-backward)))
                   ;; Literal fast path: the original pattern, searched
                   ;; with the caller's regexp settings.  Four arguments
                   ;; match the calling convention of
                   ;; `isearch-search-string'.
                   (funcall (isearch-search-fun-default)
                            string bound noerror count))
              ;; Expansion path: the transformed string is always a
              ;; regexp, even for an ordinary literal isearch, so search
              ;; it with `isearch-search-fun-default' directly.  Chaining
              ;; the saved provider would re-apply its own pattern
              ;; conversion (e.g. helixel's PCRE converter) to an
              ;; already-expanded elisp regexp and corrupt it.
              (let ((isearch-regexp t)
                    (isearch-regexp-function nil))
                (funcall (isearch-search-fun-default)
                         (rimel-regexp-build-regexp-string string literal)
                         bound noerror count))))))))

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
  (rimel-regexp--reset-search-session)
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
