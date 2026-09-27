SHELL := /bin/bash

.PHONY: bundle test lint fmt fmt-check clean

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

clean:
	rm -rf dist
