# -*- coding:utf-8 -*-

EMACS ?= emacs
ELC := rimel.elc rimel-convert.elc

.PHONY: all build test test-all lint byte-compile clean
all: byte-compile lint test

byte-compile: $(ELC)

%.elc: %.el
	$(EMACS) --batch  -Q -L ./test  -L . -l ./test/liberime-stub.el --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile $<
test:
	emacs --batch -Q -L . -L test \
	  -l ert \
	  -l test/rimel-test.el \
	  -f rimel-test-run


lint: byte-compile package-lint checkdoc
package-lint:
	$(EMACS) --batch -Q \
		--eval "(package-initialize)" \
		--eval "(require 'package-lint)" \
		--eval "(setq package-lint-main-file \"rimel.el\")" \
		-f package-lint-batch-and-exit \
		rimel.el rimel-convert.el

checkdoc:
	$(EMACS) --batch -Q \
		--eval "(require 'checkdoc)" \
		--eval "(let ((sentence-end-double-space nil) \
		              (checkdoc-proper-noun-list nil) \
		              (checkdoc-verb-check-experimental-flag nil) \
		              (ok t)) \
		  (dolist (f '(\"rimel.el\" \"rimel-convert.el\")) \
		    (ignore-errors (kill-buffer \"*Warnings*\")) \
		    (let ((inhibit-message t)) \
		      (checkdoc-file f)) \
		    (when (get-buffer \"*Warnings*\") \
		      (setq ok nil) \
		      (with-current-buffer \"*Warnings*\" \
		        (message \"%s\" (buffer-string))))) \
		  (unless ok (kill-emacs 1)))"

