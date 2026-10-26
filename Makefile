EXTENSION    = pgbackrest_monitor
EXTVERSION   = 1.0
DATA         = sql/$(EXTENSION)--$(EXTVERSION).sql
DOCS         = README.md
REGRESS      = wal_helpers ingest_fixtures health_rules retention permissions
REGRESS_OPTS = --inputdir=tests --outputdir=tests --load-extension=$(EXTENSION) --dbname=pgbackrest_monitor_regress

PG_CONFIG   ?= pg_config
PGXS        := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Python collector unit tests (stdlib unittest, no external dependencies)
.PHONY: unittest
unittest:
	cd collector && python3 -m unittest discover -s ../tests/unit -v

# End-to-end test against the lab created by tests/integration/lab_setup.sh
.PHONY: integration
integration:
	tests/integration/run_integration.sh
