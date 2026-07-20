DOCS_VENV := .venv-docs
DOCS_PY := $(DOCS_VENV)/bin/python
DOCS_MKDOCS := $(DOCS_VENV)/bin/mkdocs

.PHONY: help docs-install docs-serve docs-build docs-clean

help:
	@echo "docs-install  create $(DOCS_VENV) and install mkdocs + mkdocs-material"
	@echo "docs-serve    serve the docs site locally with live reload (http://127.0.0.1:8000)"
	@echo "docs-build    build the static site into ./site"
	@echo "docs-clean    remove the built site"

$(DOCS_PY):
	python3 -m venv $(DOCS_VENV)
	$(DOCS_PY) -m pip install --quiet --upgrade pip
	$(DOCS_PY) -m pip install --quiet -r docs-requirements.txt

docs-install: $(DOCS_PY)

docs-serve: docs-install
	$(DOCS_MKDOCS) serve

docs-build: docs-install
	$(DOCS_MKDOCS) build --strict

docs-clean:
	rm -rf site
