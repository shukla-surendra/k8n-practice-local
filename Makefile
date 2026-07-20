DOCS_VENV := .venv-docs
DOCS_PY := $(DOCS_VENV)/bin/python
DOCS_MKDOCS := $(DOCS_VENV)/bin/mkdocs

.PHONY: help docs-install docs-serve docs-clean

help:
	@echo "docs-install  create $(DOCS_VENV) and install mkdocs + mkdocs-material"
	@echo "docs-serve    strict-build (fails on broken links/nav) then serve with live reload (http://127.0.0.1:8000)"
	@echo "docs-clean    remove the built site"

$(DOCS_PY):
	python3 -m venv $(DOCS_VENV)
	$(DOCS_PY) -m pip install --quiet --upgrade pip
	$(DOCS_PY) -m pip install --quiet -r docs-requirements.txt

docs-install: $(DOCS_PY)

docs-serve: docs-install
	$(DOCS_MKDOCS) build --strict
	$(DOCS_MKDOCS) serve

docs-clean:
	rm -rf site
