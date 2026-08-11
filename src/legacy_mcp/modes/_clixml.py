"""Parses PowerShell's CLIXML serialization of non-Output streams (Warning,
Error, Verbose, Debug, Information) as it appears on the stderr of a
``powershell.exe -EncodedCommand ...`` subprocess (task #141).

Constraint verified empirically, not assumed -- documented here because it
determines whether this module is even applicable:

    This CLIXML-on-stderr shape is specific to the -EncodedCommand/-Command
    invocation style. ``powershell.exe -File script.ps1`` writes
    Write-Warning output as plain "WARNING: <text>" text on STDOUT instead
    -- mixed directly into the Output stream, which would corrupt any JSON
    payload built from stdout. LiveConnector (live.py) uses -EncodedCommand
    exclusively today (verified: grep for "powershell.exe" in that file).
    If that invocation style is ever changed to -File, this module no
    longer applies and must be revisited -- it would otherwise silently
    stop finding anything (parse_streams degrades to returning {} on
    non-CLIXML input, per its own contract below), not corrupt data, but
    warnings and clean error messages would quietly go back to being lost.

Shape of the input, decoded from bytes::

    #< CLIXML
    <Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
      <Obj S="progress" RefId="0">...</Obj>
      <S S="warning">message text</S>
      <S S="Error">message text_x000D__x000A_</S>
      ...
    </Objs>

Each non-Output stream record is a top-level ``<S S="streamname">text</S>``
element -- casing of the ``S=`` attribute varies (``"warning"`` lowercase,
``"Error"`` capitalized, both observed empirically against real
powershell.exe output), normalized to lowercase here. Progress records use
a different shape (``<Obj S="progress">``) and are ignored -- they are
noise for this module's purpose (informational only, e.g. "Preparing
modules for first use"). Control characters are escaped by PowerShell as
``_xHHHH_`` (4 hex digits); unescaped before being returned.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET

_ESCAPE_RE = re.compile(r"_x([0-9A-Fa-f]{4})_")
_CLIXML_MARKER = "#< CLIXML"


def _unescape(text: str) -> str:
    """Reverse PowerShell's CLIXML _xHHHH_ character escaping."""
    return _ESCAPE_RE.sub(lambda m: chr(int(m.group(1), 16)), text)


def _local_tag(tag: str) -> str:
    """Strip the XML namespace URI from an ElementTree tag, e.g.
    "{http://schemas.microsoft.com/powershell/2004/04}S" -> "S". Namespace-
    agnostic on purpose: matching only the local tag name is more robust
    against a namespace URI that shifts across PowerShell versions than
    hardcoding the exact URI observed empirically on this system.
    """
    return tag.split("}", 1)[1] if "}" in tag else tag


def parse_streams(raw: bytes) -> dict[str, list[str]]:
    """Parse CLIXML bytes into ``{stream_name_lowercase: [message, ...]}``.

    Returns ``{}`` for empty input or input that does not parse as CLIXML
    (e.g. plain, non-XML stderr text from a context this format does not
    apply to). Never raises -- a best-effort diagnostic parse must not
    itself become a new failure point (Principle 10: soft degradation).
    """
    if not raw:
        return {}
    text = raw.decode("utf-8", errors="replace")
    stripped = text.lstrip()
    if stripped.startswith(_CLIXML_MARKER):
        idx = text.find("\n")
        text = text[idx + 1 :] if idx != -1 else ""
    if not text.strip():
        return {}
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        return {}

    streams: dict[str, list[str]] = {}
    for el in root.iter():
        if _local_tag(el.tag) != "S":
            continue
        stream = (el.get("S") or "").strip().lower()
        if not stream:
            continue
        value = _unescape(el.text or "").rstrip("\r\n")
        streams.setdefault(stream, []).append(value)
    return streams


def extract_warnings(raw: bytes) -> list[str]:
    """Return every Warning-stream message found in *raw*, in call order."""
    return parse_streams(raw).get("warning", [])


def extract_error_message(raw: bytes) -> str:
    """Return a readable message built from the Error-stream records in
    *raw*, joined in order (PowerShell splits one formatted error across
    several <S S="Error"> lines -- message, then "+ CategoryInfo", "+
    FullyQualifiedErrorId", matching what a console would show).

    Falls back to the raw decoded text -- the pre-#141 behavior -- when
    *raw* is not CLIXML or has no Error-stream content. This keeps the
    function safe to call unconditionally: a plain-text stderr (a mocked
    test, or a genuinely non-CLIXML failure mode) still yields something
    useful instead of an empty string.
    """
    error_lines = parse_streams(raw).get("error", [])
    if error_lines:
        return "\n".join(error_lines)
    return raw.decode(errors="replace").strip()
