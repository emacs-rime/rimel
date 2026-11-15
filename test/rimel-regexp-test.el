;;; rimel-regexp-test.el --- Tests for rimel-regexp  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -L test -l ert -l test/rimel-regexp-test.el \
;;     -f rimel-regexp-test-run

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'rimel-regexp)

(ert-deftest rimel-regexp-test-search-query-keeps-shortest-prefix-group ()
  (cl-letf (((symbol-function 'liberime-search)
             (lambda (&rest _)
               '(:commit nil
                 :full ("完整")
                 :prefix ("短")
                 :remainder "cdef"
                 :remaining-input "abcdef"
                 :schema-id "test_schema"))))
    (should
     (equal (rimel-regexp--search-query "abcdef")
            '(:commit nil :full ("完整") :prefix ("短")
              :remainder "cdef" :remaining-input "abcdef"
              :schema-id "test_schema"
              :regexp-code nil :regexp nil)))))

(ert-deftest rimel-regexp-test-search-query-discards-properties ()
  (cl-letf (((symbol-function 'liberime-search)
             (lambda (&rest _)
               '(:commit nil
                 :full (#("完整" 0 2 (:comment "x"))
                        "完整"
                        "")
                 :prefix nil
                 :remainder nil
                 :remaining-input "abcdef"))))
    (should
     (equal (rimel-regexp--search-query "abcdef")
            '(:commit nil :full ("完整") :prefix nil
              :remainder nil :remaining-input "abcdef"
              :schema-id nil
              :regexp-code nil :regexp nil)))))

(ert-deftest rimel-regexp-test-search-query-commit-without-residual ()
  (cl-letf (((symbol-function 'liberime-search)
             (lambda (&rest _)
               '(:commit "世界" :full nil :prefix nil
                 :remainder nil :remaining-input ""))))
    (should
     (equal (plist-get (rimel-regexp--search-query "shijie") :commit)
            "世界"))))

(ert-deftest rimel-regexp-test-search-query-commit-with-residual ()
  "A commit followed only by residual input is not a complete expansion."
  (cl-letf (((symbol-function 'liberime-search)
             (lambda (&rest _)
               '(:commit "世" :full nil :prefix nil
                 :remainder "jie" :remaining-input "shijie"))))
    (should (null (rimel-regexp--search-query "shijie")))))

(ert-deftest rimel-regexp-test-search-query-forwards-schema-id ()
  "The configured schema is passed to liberime-search."
  (let ((rimel-regexp-schema-id "luna_pinyin_simp")
        args)
    (cl-letf (((symbol-function 'liberime-search)
               (lambda (&rest a)
                 (setq args a)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id "luna_pinyin_simp"))))
      (rimel-regexp--search-query "ni")
      (should (equal args '("ni" 100 nil "luna_pinyin_simp" t 42))))))

(ert-deftest rimel-regexp-test-build-regexp-reuses-session ()
  "A string with several codes shares one persistent session."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let ((sessions-created 0)
        (sessions-destroyed 0)
        session-args
        built)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema)
                 (setq sessions-created (1+ (or sessions-created 0)))
                 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (session)
                 (setq sessions-destroyed (1+ (or sessions-destroyed 0)))
                 (should (eq session 42))))
              ((symbol-function 'liberime-search)
               (lambda (&rest a)
                 (push (car a) session-args)
                 (should (eq (nth 5 a) 42))
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (setq built (rimel-regexp-build-regexp-string "ni shijie"))
      ;; The session survives the build; reset destroys exactly it.
      (should (eq sessions-created 1))
      (should (eq sessions-destroyed 0))
      (rimel-regexp--reset-search-session)
      (should (eq sessions-destroyed 1))
      (should (equal (nreverse session-args) '("ni" "shijie")))
      (should (stringp built)))))

(ert-deftest rimel-regexp-test-build-regexp-session-persists-across-builds ()
  "Two builds reuse the same persistent session."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let ((sessions-created 0) (sessions-destroyed 0))
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema)
                 (setq sessions-created (1+ (or sessions-created 0)))
                 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (_session)
                 (setq sessions-destroyed (1+ (or sessions-destroyed 0)))))
              ((symbol-function 'liberime-search)
               (lambda (&rest _)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (rimel-regexp-build-regexp-string "ni")
      (rimel-regexp-clear-cache)
      (rimel-regexp-build-regexp-string "ni")
      (should (eq sessions-created 1))
      (should (eq sessions-destroyed 0))
      (rimel-regexp--reset-search-session)
      (should (eq sessions-destroyed 1)))))

(ert-deftest rimel-regexp-test-session-recreated-on-schema-change ()
  "Changing `rimel-regexp-schema-id' recreates the session."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let (sessions-created)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema)
                 (setq sessions-created (1+ (or sessions-created 0)))
                 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (_session) nil))
              ((symbol-function 'liberime-search)
               (lambda (&rest _)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id "test"))))
      (let ((rimel-regexp-schema-id "schema_a"))
        (rimel-regexp--query-code "ni")
        (should (eq sessions-created 1)))
      (let ((rimel-regexp-schema-id "schema_b"))
        (rimel-regexp-clear-cache)
        (rimel-regexp--query-code "ni")
        (should (eq sessions-created 2))))
    (rimel-regexp--reset-search-session)))

(ert-deftest rimel-regexp-test-build-regexp-single-code-shares-session ()
  "A single code which recurses reuses one persistent session."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let ((sessions-created 0)
        (sessions-destroyed 0)
        session-args)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema)
                 (setq sessions-created (1+ (or sessions-created 0)))
                 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (session)
                 (setq sessions-destroyed (1+ (or sessions-destroyed 0)))
                 (should (eq session 42))))
              ((symbol-function 'liberime-search)
               (lambda (code &rest a)
                 (push code session-args)
                 (should (eq (nth 4 a) 42))
                 (if (string= code "nihao")
                     (list :commit nil :full nil :prefix '("你")
                           :remainder "hao" :remaining-input "nihao"
                           :schema-id nil)
                   (list :commit nil :full '("好") :prefix nil
                         :remainder nil :remaining-input "hao"
                         :schema-id nil)))))
      (rimel-regexp-build-regexp-string "nihao")
      (should (equal (nreverse session-args) '("nihao" "hao")))
      (should (eq sessions-created 1))
      (should (eq sessions-destroyed 0))
      (rimel-regexp--reset-search-session)
      (should (eq sessions-destroyed 1)))))

(ert-deftest rimel-regexp-test-build-regexp-plain-text-creates-no-session ()
  "Text without codes, and a build served from the cache, need no session."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let (created)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema) (setq created t) 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (_session) nil))
              ((symbol-function 'liberime-search)
               (lambda (&rest _)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (rimel-regexp-build-regexp-string "你好")
      (should-not created)
      (rimel-regexp-build-regexp-string "ni")
      (should created)
      ;; Everything cached now: a second build must not touch liberime.
      (setq created nil)
      (cl-letf (((symbol-function 'liberime-search)
                 (lambda (&rest _) (error "cached build must not query Rime"))))
        (rimel-regexp-build-regexp-string "ni"))
      (should-not created))
    (rimel-regexp--reset-search-session)))

(ert-deftest rimel-regexp-test-build-regexp-selects-schema-once ()
  "The configured schema is passed to the first lookup only."
  (rimel-regexp-clear-cache)
  (rimel-regexp--reset-search-session)
  (let ((rimel-regexp-schema-id "egret_py")
        calls)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda (&optional _schema) 7))
              ((symbol-function 'liberime-session-destroy)
               (lambda (_session) nil))
              ((symbol-function 'liberime-search)
               (lambda (code &optional _limit _index schema _context session)
                 (push (list code schema session) calls)
                 (if (string= code "nihao")
                     (list :commit nil :full nil :prefix '("你")
                           :remainder "hao" :remaining-input "nihao"
                           :schema-id "egret_py")
                   (list :commit nil :full '("好") :prefix nil
                         :remainder nil :remaining-input "hao"
                         :schema-id "egret_py")))))
      (rimel-regexp-build-regexp-string "nihao")
      (setq calls (nreverse calls))
      (should (equal (mapcar #'car calls) '("nihao" "hao")))
      (should (equal (mapcar #'cadr calls) '("egret_py" nil)))
      (should (equal (mapcar #'caddr calls) '(7 7)))
      (rimel-regexp--reset-search-session))))

(ert-deftest rimel-regexp-test-code-regexp-full-skips-recursion ()
  "A full candidate consumes the code, so no recursive group is built."
  (let ((whole-query
         (list :commit nil :full '("整词") :prefix '("甲" "假")
               :remainder "cd" :remaining-input "abcd"
               :regexp-code nil :regexp nil)))
    (cl-letf (((symbol-function 'rimel-regexp--query-code)
               (lambda (_code) whole-query)))
      (let ((regexp (rimel-regexp--code-regexp "abcd")))
        (should (string-match-p (concat "\\`" regexp "\\'") "整词"))
        (should (string-match-p (concat "\\`" regexp "\\'") "abcd"))
        ;; The prefix group is skipped when a full candidate exists.
        (should-not (string-match-p (concat "\\`" regexp "\\'") "甲"))
        (should (eq regexp (rimel-regexp--code-regexp "abcd")))))))

(ert-deftest rimel-regexp-test-composes-without-prefix-only-match ()
  "Without full candidates the prefix group expands the remainder."
  (let ((whole-query
         (list :commit nil :full nil :prefix '("甲" "假")
               :remainder "cd" :remaining-input "abcd"
               :regexp-code nil :regexp nil))
        (suffix-query
         (list :commit nil :full '("乙") :prefix nil
               :remainder nil :remaining-input "cd"
               :regexp-code nil :regexp nil)))
    (cl-letf (((symbol-function 'rimel-regexp--query-code)
               (lambda (code)
                 (if (string= code "abcd") whole-query suffix-query))))
      (let ((regexp (rimel-regexp--code-regexp "abcd")))
        (should (string-match-p (concat "\\`" regexp "\\'") "甲乙"))
        (should (string-match-p (concat "\\`" regexp "\\'") "abcd"))
        (should-not (string-match-p (concat "\\`" regexp "\\'") "甲"))
        (should (eq regexp (rimel-regexp--code-regexp "abcd")))))))

(ert-deftest rimel-regexp-test-code-regexp-recursion-depth ()
  "Recursive expansion stops at `rimel-regexp-max-recursion-depth'."
  (rimel-regexp-clear-cache)
  (let ((rimel-regexp-max-recursion-depth 2)
        codes)
    (cl-letf (((symbol-function 'rimel-regexp--query-code)
               (lambda (code)
                 (push code codes)
                 (list :commit nil :full nil :prefix '("字")
                       :remainder (substring code 1)
                       :remaining-input code
                       :regexp-code nil :regexp nil))))
      (rimel-regexp--code-regexp "abcd")
      ;; Depth 0 -> 1 -> 2, then `rimel-regexp-max-recursion-depth'
      ;; stops the recursion; only three lookups are made.
      (should (equal (nreverse codes) '("abcd" "bcd" "cd"))))))

(ert-deftest rimel-regexp-test-pinyin-code-p-accepts-pinyin ()
  (dolist (code '("nihao" "shijie" "sj" "ss" "xianjh" "nisj"
                  "a" "e" "lv" "zzzz" "woyaochifan" "nihaoshijie"
                  ;; Known limitation: words segmenting into full pinyin
                  ;; syllables still pass (bu f f er, he l lo).
                  "buffer" "hello"))
    (should (rimel-regexp-pinyin-code-p code))))

(ert-deftest rimel-regexp-test-pinyin-code-p-rejects-english ()
  (dolist (code '("searchforward" "xhtml" "world"
                  "point" "i" "u" "uu"))
    (should-not (rimel-regexp-pinyin-code-p code))))

(ert-deftest rimel-regexp-test-query-code-honors-predicate ()
  "Codes rejected by `rimel-regexp-code-predicate' never reach Rime."
  (rimel-regexp-clear-cache)
  (let ((rimel-regexp-code-predicate (lambda (code) (string= code "ni")))
        calls)
    (cl-letf (((symbol-function 'liberime-search)
               (lambda (&rest a)
                 (push (car a) calls)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (should (rimel-regexp--query-code "ni"))
      (should (null (rimel-regexp--query-code "buffer")))
      (should (equal calls '("ni"))))))

(ert-deftest rimel-regexp-test-build-regexp-uses-literal-for-rejected-code ()
  (rimel-regexp-clear-cache)
  (let ((rimel-regexp-code-predicate (lambda (_code) nil))
        queried)
    (cl-letf (((symbol-function 'liberime-search)
               (lambda (&rest _)
                 (setq queried t)
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (should (equal (rimel-regexp-build-regexp-string "buffer")
                     (regexp-opt (list "buffer"))))
      (should-not queried))))

(ert-deftest rimel-regexp-test-mode-installs-and-removes-integrations ()
  (unwind-protect
      (progn
        (rimel-regexp-mode 1)
        (should (eq (default-value 'isearch-search-fun-function)
                    #'rimel-regexp--isearch-search-function))
        (should rimel-regexp--saved-isearch-search-fun-function))
    (rimel-regexp-mode -1))
  (should (eq (default-value 'isearch-search-fun-function)
              'isearch-search-fun-default))
  (should (null rimel-regexp--saved-isearch-search-fun-function)))

(ert-deftest rimel-regexp-test-filter-args-expands-code ()
  (cl-letf (((symbol-function 'rimel-regexp-build-regexp-string)
             (lambda (str &optional _literal)
               (format "EXPANDED(%s)" str))))
    (should (equal (rimel-regexp-filter-args '("ni" 1 2))
                   '("EXPANDED(ni)" 1 2)))))

(ert-deftest rimel-regexp-test-isearch-literal-first ()
  "isearch tries the literal pattern first; expansion only on miss/repeat."
  (unwind-protect
      (progn
        (rimel-regexp-mode 1)
        (with-temp-buffer
          (insert "alpha beta 你好\nni again\n")
          (goto-char (point-min))
          (let ((fun (funcall (default-value 'isearch-search-fun-function)))
                (isearch-regexp nil)
                (isearch-regexp-function nil)
                (isearch-forward t)
                built)
            (cl-letf (((symbol-function 'rimel-regexp-build-regexp-string)
                       (lambda (str &optional _literal)
                         (setq built t)
                         ;; Simulate a pinyin expansion: "nihao" matches
                         ;; the Chinese text via its "ni" part.
                         (if (string= str "nihao") "ni" (regexp-quote str)))))
              ;; Non-repeat command: literal path wins, no Rime build.
              (let ((this-command 'isearch-forward-regexp))
                (should (funcall fun "alpha"))
                (should-not built))
              ;; Literal miss falls back to expansion.
              (let ((this-command 'isearch-printing-char))
                (should (funcall fun "nihao" nil t))
                (should built))
              ;; Repeating escalates to expansion even on literal hit.
              (setq built nil)
              (goto-char (point-min))
              (let ((this-command 'isearch-repeat-forward))
                (should (funcall fun "alpha"))
                (should built)))))
        (with-temp-buffer
          (insert "alpha beta\n")
          (goto-char (point-min))
          (let ((fun (funcall (default-value 'isearch-search-fun-function)))
                (isearch-regexp t)
                (isearch-regexp-function nil)
                (isearch-forward t)
                built)
            (cl-letf (((symbol-function 'rimel-regexp-build-regexp-string)
                       (lambda (str &optional _literal)
                         (setq built t)
                         "\\_<alpha\\_>")))
              (let ((this-command 'isearch-forward-regexp))
                (should (funcall fun "\\_<alpha\\_>"))
                (should-not built)))))
        )
    (rimel-regexp-mode -1)))

(defun rimel-regexp-test-run ()
  "Run all rimel-regexp tests."
  (ert-run-tests-batch-and-exit "rimel-regexp-test-"))

(provide 'rimel-regexp-test)

;;; rimel-regexp-test.el ends here
