SHELL := /bin/bash

.PHONY: bundle test lint fmt clean

bundle:
	./scripts/build.sh

test: lint bundle
	bash tests/run-tests.sh

lint:
	shellcheck lib/core.sh appimage-install.sh appimage-install-tui.sh scripts/build.sh tests/run-tests.sh

fmt:
	shfmt -w lib/core.sh appimage-install.sh appimage-install-tui.sh scripts/build.sh tests/run-tests.sh

clean:
	rm -rf dist
