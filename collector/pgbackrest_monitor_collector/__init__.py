"""Collector for the pgbackrest_monitor PostgreSQL extension.

Runs `pgbackrest --stanza=<name> --output=json info` for each configured stanza, validates the
output and hands it to the extension's SECURITY DEFINER functions.  The collector never runs
backup, restore, expire or any other mutating pgBackRest command.
"""

__version__ = "1.0.0"
