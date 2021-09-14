# dotmgr - dotfiles manager.

SHELL := /bin/bash

# Tool locations can be overridden, which is handy in CI or a vendored checkout.
SHELLCHECK ?= shellcheck
BATS ?= bats

SCRIPT := bin/dotmgr
LIB := lib/dotmgr.sh

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
# bin/dotmgr sources ../lib/dotmgr.sh relative to its own location, so the lib
# must land in $(PREFIX)/lib to keep that path valid once installed.
LIBDIR := $(PREFIX)/lib

.PHONY: all lint test check help install uninstall

all: check

help:
	@echo "Targets:"
	@echo "  make lint       - run shellcheck over the script and lib"
	@echo "  make test       - run the bats test suite"
	@echo "  make check      - lint then test"
	@echo "  make install    - install dotmgr under PREFIX ($(PREFIX))"
	@echo "  make uninstall  - remove an installed copy"

lint:
	$(SHELLCHECK) -x $(LIB) $(SCRIPT)

test:
	$(BATS) test

check: lint test

install:
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBDIR)
	install -m 0644 $(LIB) $(DESTDIR)$(LIBDIR)/dotmgr.sh
	install -m 0755 $(SCRIPT) $(DESTDIR)$(BINDIR)/dotmgr

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/dotmgr
	rm -f $(DESTDIR)$(LIBDIR)/dotmgr.sh
