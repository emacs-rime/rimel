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
      (should (equal args '("ni" 100 nil "luna_pinyin_simp" t nil))))))

(ert-deftest rimel-regexp-test-build-regexp-reuses-session ()
  "A string with several codes shares one temporary session."
  (let (sessions-destroyed
        session-args
        built)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda () (setq sessions-destroyed 0) 42))
              ((symbol-function 'liberime-session-destroy)
               (lambda (session)
                 (setq sessions-destroyed (1+ sessions-destroyed))
                 (should (eq session 42))))
              ((symbol-function 'liberime-search)
               (lambda (&rest a)
                 (push (car a) session-args)
                 (should (eq (nth 5 a) 42))
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (setq built (rimel-regexp-build-regexp-string "ni shijie"))
      (should (eq sessions-destroyed 1))
      (should (equal (nreverse session-args) '("ni" "shijie")))
      (should (stringp built)))))

(ert-deftest rimel-regexp-test-build-regexp-single-code-no-session ()
  "A single code does not create a session."
  (let (created)
    (cl-letf (((symbol-function 'liberime-session-create)
               (lambda () (setq created t) 42))
              ((symbol-function 'liberime-search)
               (lambda (&rest a)
                 (should (null (nth 5 a)))
                 (list :commit nil :full '("你") :prefix nil
                       :remainder nil :remaining-input "ni"
                       :schema-id nil))))
      (rimel-regexp-build-regexp-string "ni")
      (should-not created))))

(ert-deftest rimel-regexp-test-composes-without-prefix-only-match ()
  (let ((whole-query
         (list :commit nil :full '("整词") :prefix '("甲" "假")
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
        (should (string-match-p (concat "\\`" regexp "\\'") "整词"))
        (should (string-match-p (concat "\\`" regexp "\\'") "abcd"))
        (should-not (string-match-p (concat "\\`" regexp "\\'") "甲"))
        (should (eq regexp (rimel-regexp--code-regexp "abcd")))))))

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

(defun rimel-regexp-test-run ()
  "Run all rimel-regexp tests."
  (ert-run-tests-batch-and-exit "rimel-regexp-test-"))

(provide 'rimel-regexp-test)

;;; rimel-regexp-test.el ends here
