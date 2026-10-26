"""Parsing and validation of `pgbackrest --output=json info` output.

Only fields that are verified in real output (pgBackRest 2.59.3) or documented in release notes are
checked.  Optional, version-dependent fields (repo array / repo-key >= 2.33, lsn >= 2.35,
error >= 2.36, lock progress >= 2.38/2.48, annotation >= 2.41, restore progress >= 2.56) are
accepted when present and never required.
"""
import json
from typing import Any, Dict, List

from .redact import redact

BACKUP_TYPES = ("full", "diff", "incr")


class ParseError(Exception):
    pass


class ValidationError(Exception):
    def __init__(self, problems: List[str]):
        super().__init__("; ".join(problems))
        self.problems = problems


def parse_info_output(stdout: str) -> Any:
    text = (stdout or "").strip()
    if not text:
        raise ParseError("empty output")
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        snippet = redact(text[:120]).replace("\n", " ")
        raise ParseError("invalid JSON at line %d column %d: %s (output starts: %r)" % (e.lineno, e.colno, e.msg, snippet))


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def validate_info(doc: Any, stanza: str) -> Dict[str, Any]:
    """Validate the document for one stanza; return the stanza element.  Raises ValidationError."""
    problems: List[str] = []
    if not isinstance(doc, list):
        raise ValidationError(["top level is %s, expected array of stanzas" % type(doc).__name__])
    matches = [e for e in doc if isinstance(e, dict) and e.get("name") == stanza]
    if not matches:
        names = [e.get("name") for e in doc if isinstance(e, dict)]
        raise ValidationError(["stanza %r not present in output (stanzas reported: %s)" % (stanza, names or "none")])
    s = matches[0]

    status = s.get("status")
    if not isinstance(status, dict) or not _is_int(status.get("code")):
        problems.append("status.code missing or not an integer")
    elif "message" in status and not isinstance(status["message"], str):
        problems.append("status.message is not a string")
    lock = status.get("lock") if isinstance(status, dict) else None
    if lock is not None:
        if not isinstance(lock, dict):
            problems.append("status.lock is not an object")
        else:
            for op in ("backup", "restore"):
                if op in lock and not isinstance(lock[op].get("held"), bool):
                    problems.append("status.lock.%s.held is not a boolean" % op)

    repos = s.get("repo")
    if repos is not None:
        if not isinstance(repos, list):
            problems.append("repo is not an array")
        else:
            for i, r in enumerate(repos):
                if not isinstance(r, dict) or not _is_int(r.get("key")):
                    problems.append("repo[%d].key missing or not an integer" % i)
                elif not isinstance(r.get("status"), dict) or not _is_int(r["status"].get("code")):
                    problems.append("repo[%d].status.code missing or not an integer" % i)

    backups = s.get("backup", [])
    if not isinstance(backups, list):
        problems.append("backup is not an array")
        backups = []
    for i, b in enumerate(backups):
        where = "backup[%d]" % i
        if not isinstance(b, dict):
            problems.append("%s is not an object" % where)
            continue
        if not isinstance(b.get("label"), str) or not b["label"]:
            problems.append("%s.label missing" % where)
        if b.get("type") not in BACKUP_TYPES:
            problems.append("%s.type %r not one of %s" % (where, b.get("type"), BACKUP_TYPES))
        ts = b.get("timestamp")
        if not isinstance(ts, dict) or not _is_int(ts.get("start")) or not _is_int(ts.get("stop")):
            problems.append("%s.timestamp.start/stop missing or not integers" % where)
        db = b.get("database")
        if db is not None and (not isinstance(db, dict) or ("repo-key" in db and not _is_int(db["repo-key"]))):
            problems.append("%s.database.repo-key not an integer" % where)
        if "error" in b and b["error"] is not None and not isinstance(b["error"], bool):
            problems.append("%s.error is not a boolean" % where)

    archives = s.get("archive", [])
    if not isinstance(archives, list):
        problems.append("archive is not an array")
    else:
        for i, a in enumerate(archives):
            if not isinstance(a, dict) or not isinstance(a.get("id"), str):
                problems.append("archive[%d].id missing" % i)
            else:
                for k in ("min", "max"):
                    if a.get(k) is not None and not isinstance(a[k], str):
                        problems.append("archive[%d].%s is not a string" % (i, k))

    if problems:
        raise ValidationError(problems)
    return s


def summarize(stanza_elem: Dict[str, Any]) -> str:
    """One-line summary for logs."""
    st = stanza_elem.get("status", {})
    repos = stanza_elem.get("repo") or []
    lock = st.get("lock") or {}
    parts = [
        "status=%s(%s)" % (st.get("code"), st.get("message")),
        "backups=%d" % len(stanza_elem.get("backup") or []),
        "repos=" + ",".join("%s:%s" % (r.get("key"), r.get("status", {}).get("code")) for r in repos),
    ]
    if lock.get("backup", {}).get("held"):
        parts.append("backup/expire running")
    if lock.get("restore", {}).get("held"):
        parts.append("restore running")
    return " ".join(parts)
