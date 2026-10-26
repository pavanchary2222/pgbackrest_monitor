#!/usr/bin/env python3
"""Stand-in for the pgbackrest binary, driven by environment variables:
   FAKE_PGBACKREST_FIXTURE=<path>   print this file on stdout
   FAKE_PGBACKREST_EXIT=<n>         exit code (default 0)
   FAKE_PGBACKREST_SLEEP=<seconds>  sleep before answering (timeout tests)
   FAKE_PGBACKREST_STDERR=<text>    print this on stderr
"""
import os
import sys
import time

if "version" in sys.argv:
    print("pgBackRest 9.99.0")
    sys.exit(0)
if os.environ.get("FAKE_PGBACKREST_SLEEP"):
    time.sleep(float(os.environ["FAKE_PGBACKREST_SLEEP"]))
if os.environ.get("FAKE_PGBACKREST_STDERR"):
    sys.stderr.write(os.environ["FAKE_PGBACKREST_STDERR"] + "\n")
fx = os.environ.get("FAKE_PGBACKREST_FIXTURE")
if fx:
    sys.stdout.write(open(fx).read())
sys.exit(int(os.environ.get("FAKE_PGBACKREST_EXIT", "0")))
