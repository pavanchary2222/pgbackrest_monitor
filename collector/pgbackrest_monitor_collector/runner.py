"""Safe execution of the pgBackRest binary (no shell, fixed argv, timeout, captured output)."""
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import List, Optional

from .redact import redact

STDERR_KEEP = 2000  # characters of stderr retained for error messages


@dataclass
class CommandResult:
    argv: List[str]
    started_at: datetime
    finished_at: datetime
    status: str                 # completed | timeout | binary_missing | permission_denied | spawn_failed
    exit_code: Optional[int] = None
    stdout: str = ""
    stderr: str = ""
    error: Optional[str] = None  # redacted, human readable

    @property
    def ok(self) -> bool:
        return self.status == "completed" and self.exit_code == 0


def run_command(argv: List[str], timeout: int) -> CommandResult:
    """Run argv with a hard timeout.  Never raises for process-level failures."""
    started = datetime.now(timezone.utc)
    try:
        proc = subprocess.run(
            argv, shell=False, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as e:
        finished = datetime.now(timezone.utc)
        stderr = (e.stderr.decode("utf-8", "replace") if isinstance(e.stderr, bytes) else (e.stderr or ""))
        return CommandResult(argv, started, finished, "timeout", None, "", stderr[-STDERR_KEEP:],
                             "pgbackrest %s did not finish within %ds and was killed" % (argv[-1], timeout))
    except FileNotFoundError:
        finished = datetime.now(timezone.utc)
        return CommandResult(argv, started, finished, "binary_missing", None, "", "",
                             "pgbackrest executable not found: %s" % argv[0])
    except PermissionError as e:
        finished = datetime.now(timezone.utc)
        return CommandResult(argv, started, finished, "permission_denied", None, "", "",
                             "cannot execute %s: %s" % (argv[0], e.strerror))
    except OSError as e:
        finished = datetime.now(timezone.utc)
        return CommandResult(argv, started, finished, "spawn_failed", None, "", "",
                             "cannot execute %s: %s" % (argv[0], redact(str(e))))
    finished = datetime.now(timezone.utc)
    err = None
    if proc.returncode != 0:
        tail = proc.stderr.strip()[-STDERR_KEEP:] or proc.stdout.strip()[-STDERR_KEEP:]
        err = "pgbackrest %s exited with code %d: %s" % (argv[-1], proc.returncode, redact(tail) or "(no output)")
    return CommandResult(argv, started, finished, "completed", proc.returncode, proc.stdout, proc.stderr, err)


def pgbackrest_version(binary: str, timeout: int = 15) -> Optional[str]:
    """Return the version string reported by `pgbackrest version`, or None."""
    res = run_command([binary, "version"], timeout)
    if res.ok:
        # "pgBackRest 2.59.3"
        parts = res.stdout.strip().split()
        return parts[-1] if parts else None
    return None
