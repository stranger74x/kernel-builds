# Helpers for keeping the patched kernel up to date.  Run `make` to see them.
VARIANTS ?= cachyos/linux-cachyos cachyos/linux-cachyos-lts
BRANCH   := $(shell git rev-parse --abbrev-ref HEAD)

.DEFAULT_GOAL := help
.PHONY: help import check inspect report clean

help:
	@echo "make import       pull upstream's new files onto branch upstream-import"
	@echo "make check        push this branch, run the cloud check, download the reports (needs gh)"
	@echo "make inspect V=cachyos/linux-cachyos-lts   inspect a source tree you already have"
	@echo "make report       print the verdict of the last reports"
	@echo "make clean        delete report folders"

import:
	@bash tools/import-upstream.sh

# Cloud check: GitHub downloads the kernel for you; you only get the small files back.
check:
	git push -u origin HEAD
	@sha=$$(git rev-parse HEAD); id=""; \
	for i in 1 2 3 4 5 6; do sleep 5; \
	  id=$$(gh run list --workflow check-patch.yml --commit $$sha --limit 1 --json databaseId --jq '.[0].databaseId'); \
	  [ -n "$$id" ] && break; done; \
	if [ -z "$$id" ]; then \
	  echo "push did not start a run (no watched file changed); starting one by hand"; \
	  gh workflow run check-patch.yml --ref $(BRANCH); sleep 10; \
	  id=$$(gh run list --workflow check-patch.yml --branch $(BRANCH) --limit 1 --json databaseId --jq '.[0].databaseId'); \
	fi; \
	gh run watch $$id --exit-status; s=$$?; \
	rm -rf fua-check-remote; gh run download $$id --dir fua-check-remote; \
	grep -h '^\*\*Verdict' fua-check-remote/*/report.md; \
	echo "Details: fua-check-remote/<variant>/report.md"; exit $$s

inspect:
	@bash tools/inspect-fua.sh $(V)

report:
	@grep -h '^\*\*Verdict' fua-check*/*/report.md 2>/dev/null || echo "no reports yet"

clean:
	rm -rf fua-check fua-check-remote
