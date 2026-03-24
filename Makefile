EMACS ?= emacs

PACKAGE = org-babel-entangle
EL = $(PACKAGE).el
ELC = $(PACKAGE).elc
TEST_EL = test/test-$(PACKAGE).el

.PHONY: all compile test lint clean

all: compile test

compile: $(ELC)

$(ELC): $(EL)
	$(EMACS) --batch -Q -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(EL)

test: compile
	$(EMACS) --batch -Q -L . \
	  -l ert \
	  -l $(TEST_EL) \
	  -f ert-run-tests-batch-and-exit

lint:
	$(EMACS) --batch -Q -L . \
	  --eval "(require 'package)" \
	  --eval "(package-lint-batch-and-exit)" $(EL)

clean:
	rm -f $(ELC)
