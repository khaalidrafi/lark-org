EMACS ?= emacs

# The package loads without a live Lark backend: the transport is
# built-in url.el behind `lark-org-http-function', and the tests stub
# it.  No -Q here either, so a distribution's site-lisp is still found.
LOAD = -L .

SRCS = lark-org.el

all: compile

compile:
	$(EMACS) --batch $(LOAD) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

test:
	$(EMACS) --batch $(LOAD) -l test -f ert-run-tests-batch-and-exit

clean:
	rm -f $(SRCS:.el=.elc) test.elc

.PHONY: all compile test clean
