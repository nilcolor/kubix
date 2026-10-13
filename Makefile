# A thin front door over scripts/*.sh.
.DEFAULT_GOAL := help
.PHONY: help prep generate build release share run test lint clean

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN { FS = ":.*?## " } { printf "  %-9s %s\n", $$1, $$2 }'

prep: ## build libghostty and stage its resources
	./scripts/setup.sh

generate: ## prepare dependencies and generate kubix.xcodeproj
	./scripts/generate.sh

build: ## generate the project and build the debug app
	./scripts/build.sh

release: ## build the release app and check its signature and contents
	./scripts/release.sh

share: ## build the release app and zip it to ~/Downloads/Kubix-<git describe>.zip
	./scripts/share.sh

run: ## build and launch the debug app
	./scripts/run.sh

test: ## run both host-free SwiftPM test targets
	./scripts/test.sh

lint: ## lint Swift sources (warnings fail too)
	./scripts/lint.sh

clean: ## remove app and SwiftPM build artifacts
	rm -rf build .build KubixCore/.build
