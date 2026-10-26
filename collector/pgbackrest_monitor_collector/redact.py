"""Redaction of secrets from anything that is logged or stored."""
import re

# pgBackRest options whose values are secrets (command line or config form).
_SECRET_OPTIONS = (
    r"s3-key", r"s3-key-secret", r"s3-token", r"azure-key", r"gcs-key", r"gcs-token",
    r"cipher-pass", r"host-pass", r"sftp-private-key-passphrase", r"host-user-pass",
)
_OPTION_RE = re.compile(
    r"(--?(?:repo\d*-|pg\d*-)?(?:" + "|".join(_SECRET_OPTIONS) + r")\s*[= ]\s*)(\"[^\"]*\"|'[^']*'|\S+)",
    re.IGNORECASE,
)
# Generic key=value secrets (environment variables, conninfo strings, URLs).
_KV_RE = re.compile(
    r"((?:^|[\s,;&?])(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|passphrase)\s*=\s*)(\"[^\"]*\"|'[^']*'|\S+)",
    re.IGNORECASE,
)
_PGPASSWORD_RE = re.compile(r"(PGPASSWORD\s*=\s*)\S+")
_URL_CRED_RE = re.compile(r"(\w+://)([^/\s:@]+):([^@\s/]+)@")
_AWS_KEY_RE = re.compile(r"\b(AKIA|ASIA)[0-9A-Z]{16}\b")

REDACTED = "[REDACTED]"


def redact(text):
    """Return text with secret values replaced.  Safe on None."""
    if not text:
        return text
    out = _OPTION_RE.sub(lambda m: m.group(1) + REDACTED, text)
    out = _KV_RE.sub(lambda m: m.group(1) + REDACTED, out)
    out = _PGPASSWORD_RE.sub(lambda m: m.group(1) + REDACTED, out)
    out = _URL_CRED_RE.sub(lambda m: m.group(1) + m.group(2) + ":" + REDACTED + "@", out)
    out = _AWS_KEY_RE.sub(REDACTED, out)
    return out


def redact_argv(argv):
    """Redact a command line (list form) for logging."""
    return [redact(a) for a in argv]
