# ZettaBrain RAG — Build Makefile
# Usage:
#   make build       — sync scripts, build package
#   make publish     — build + upload to PyPI
#   make bump v=0.1.9 — bump version everywhere
#   make clean       — remove dist/

VERSION := $(shell grep '^version' pyproject.toml | cut -d'"' -f2)

.PHONY: build publish bump clean sync

# Sync setup.sh from scripts/ to root (single source of truth)
sync:
	@echo "Syncing setup.sh from scripts/ to root..."
	cp zettabrain_rag/scripts/setup.sh setup.sh
	@echo "Done."

# Build the package (always sync first)
build: sync clean
	@echo "Building zettabrain-rag v$(VERSION)..."
	python3 -m build
	@echo "Built:"
	@ls -lh dist/

# Build + upload to PyPI
publish: build
	@echo "Uploading to PyPI..."
	twine upload dist/*

# Bump version in all files
bump:
	@if [ -z "$(v)" ]; then echo "Usage: make bump v=0.1.9"; exit 1; fi
	sed -i '' 's/version = "$(VERSION)"/version = "$(v)"/' pyproject.toml
	sed -i '' 's/__version__ = "$(VERSION)"/__version__ = "$(v)"/' zettabrain_rag/__init__.py
	@echo "Bumped $(VERSION) → $(v)"
	@grep '^version' pyproject.toml
	@grep '__version__' zettabrain_rag/__init__.py

# Remove dist
clean:
	rm -rf dist/ *.egg-info/
	@echo "Cleaned."

# Full release: bump + build + push + publish
release:
	@if [ -z "$(v)" ]; then echo "Usage: make release v=0.1.9"; exit 1; fi
	$(MAKE) bump v=$(v)
	$(MAKE) build
	git add .
	git commit -m "release: v$(v)"
	git push origin main
	twine upload dist/*
	@echo "Released v$(v) to GitHub and PyPI."
