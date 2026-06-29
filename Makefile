REPORTS_DIR ?= reports

.PHONY: test lint format test-vmaas test-caas test-storage

test:
	mkdir -p $(REPORTS_DIR)
	pytest tests/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/results.xml

lint:
	ruff check tests/
	ruff format --check tests/

format:
	ruff format tests/

test-vmaas:
	mkdir -p $(REPORTS_DIR)
	pytest tests/vmaas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/vmaas.xml

test-caas:
	mkdir -p $(REPORTS_DIR)
	pytest tests/caas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/caas.xml

test-storage:
	mkdir -p $(REPORTS_DIR)
	pytest tests/storage/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/storage.xml
