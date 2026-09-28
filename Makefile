SHELL := /bin/bash

PREFIX ?= $(HOME)/.local

.PHONY: bundle test lint fmt fmt-check clean install uninstall

bundle:
	./scripts/build.sh

test: lint fmt-check bundle
	bash tests/run-tests.sh

lint:
	shellcheck lib/core.sh appimage-manager.sh appimage-manager-tui.sh scripts/build.sh tests/run-tests.sh

fmt:
	shfmt -w lib/core.sh appimage-manager.sh appimage-manager-tui.sh scripts/build.sh tests/run-tests.sh

fmt-check:
	shfmt -d lib/core.sh appimage-manager.sh appimage-manager-tui.sh scripts/build.sh tests/run-tests.sh

install: bundle
	install -d "$(PREFIX)/bin"
	install -m 755 dist/appimage-manager dist/appimage-manager-tui "$(PREFIX)/bin/"

uninstall:
	rm -f "$(PREFIX)/bin/appimage-manager" "$(PREFIX)/bin/appimage-manager-tui"

clean:
	rm -rf dist
