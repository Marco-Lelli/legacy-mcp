"""Unit tests for legacy_mcp.modes._clixml (task #141).

Sample CLIXML fixtures below were captured empirically against real
powershell.exe -EncodedCommand output during Fase 1's analysis, not
hand-written -- the exact shape production code actually produces,
including the leading "#< CLIXML" marker, the progress record noise, and
the "_x000D__x000A_" control-character escaping on multi-line Error text.
"""

from __future__ import annotations

from legacy_mcp.modes import _clixml

_REAL_WARNING_SAMPLE = (
    b'#< CLIXML\r\n<Objs Version="1.1.0.1" '
    b'xmlns="http://schemas.microsoft.com/powershell/2004/04">'
    b'<Obj S="progress" RefId="0"><TN RefId="0">'
    b"<T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN>"
    b'<MS><I64 N="SourceId">1</I64><PR N="Record">'
    b"<AV>Preparing modules for first use.</AV><AI>0</AI><Nil /><PI>-1</PI>"
    b'<PC>-1</PC><T>Completed</T><SR>-1</SR><SD> </SD></PR></MS></Obj>'
    b'<S S="warning">this is a test warning</S></Objs>'
)

_REAL_ERROR_SAMPLE = (
    b'#< CLIXML\r\n<Objs Version="1.1.0.1" '
    b'xmlns="http://schemas.microsoft.com/powershell/2004/04">'
    b'<Obj S="progress" RefId="0"><TN RefId="0">'
    b"<T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN>"
    b'<MS><I64 N="SourceId">1</I64><PR N="Record">'
    b"<AV>Preparing modules for first use.</AV><AI>0</AI><Nil /><PI>-1</PI>"
    b'<PC>-1</PC><T>Completed</T><SR>-1</SR><SD> </SD></PR></MS></Obj>'
    b'<S S="Error">Write-Error "boom test error"; exit 1 : boom test error'
    b"_x000D__x000A_</S>"
    b'<S S="Error">    + CategoryInfo          : NotSpecified: (:) [Write-Error], '
    b"WriteErrorException_x000D__x000A_</S>"
    b'<S S="Error">    + FullyQualifiedErrorId : '
    b"Microsoft.PowerShell.Commands.WriteErrorException_x000D__x000A_</S>"
    b'<S S="Error"> _x000D__x000A_</S></Objs>'
)


class TestParseStreams:

    def test_empty_bytes_returns_empty_dict(self) -> None:
        assert _clixml.parse_streams(b"") == {}

    def test_whitespace_only_returns_empty_dict(self) -> None:
        assert _clixml.parse_streams(b"   \r\n  ") == {}

    def test_non_xml_garbage_does_not_raise(self) -> None:
        assert _clixml.parse_streams(b"not xml at all <<<") == {}

    def test_plain_text_stderr_does_not_raise(self) -> None:
        # The pre-#141 shape of every existing mock -- must degrade
        # gracefully, never throw.
        assert _clixml.parse_streams(b"Access is denied.") == {}

    def test_progress_record_alone_produces_no_streams(self) -> None:
        clixml = (
            b'#< CLIXML\r\n<Objs Version="1.1.0.1" '
            b'xmlns="http://schemas.microsoft.com/powershell/2004/04">'
            b'<Obj S="progress" RefId="0"><TN RefId="0">'
            b"<T>System.Management.Automation.PSCustomObject</T></TN>"
            b'<MS><I64 N="SourceId">1</I64></MS></Obj></Objs>'
        )
        assert _clixml.parse_streams(clixml) == {}

    def test_real_warning_sample_parses_correctly(self) -> None:
        streams = _clixml.parse_streams(_REAL_WARNING_SAMPLE)
        assert streams == {"warning": ["this is a test warning"]}

    def test_stream_name_lookup_is_case_insensitive(self) -> None:
        # PowerShell emits "warning" lowercase but "Error" capitalized --
        # observed empirically on both, both must normalize to lowercase.
        streams = _clixml.parse_streams(_REAL_ERROR_SAMPLE)
        assert "error" in streams
        assert "Error" not in streams

    def test_multiple_warnings_preserved_in_order(self) -> None:
        clixml = (
            b'#< CLIXML\r\n<Objs Version="1.1.0.1" '
            b'xmlns="http://schemas.microsoft.com/powershell/2004/04">'
            b'<S S="warning">first</S><S S="warning">second</S>'
            b'<S S="warning">third</S></Objs>'
        )
        streams = _clixml.parse_streams(clixml)
        assert streams["warning"] == ["first", "second", "third"]

    def test_escape_sequences_unescaped(self) -> None:
        clixml = (
            b'#< CLIXML\r\n<Objs Version="1.1.0.1" '
            b'xmlns="http://schemas.microsoft.com/powershell/2004/04">'
            b'<S S="warning">line one_x000D__x000A_line two</S></Objs>'
        )
        streams = _clixml.parse_streams(clixml)
        # rstrip("\r\n") only strips a TRAILING newline; an embedded one
        # (mid-string) must survive as a real CR LF, not the escaped form.
        assert streams["warning"] == ["line one\r\nline two"]
        assert "_x000D_" not in streams["warning"][0]


class TestExtractWarnings:

    def test_returns_empty_list_for_no_warnings(self) -> None:
        assert _clixml.extract_warnings(_REAL_ERROR_SAMPLE) == []

    def test_returns_warning_text(self) -> None:
        assert _clixml.extract_warnings(_REAL_WARNING_SAMPLE) == ["this is a test warning"]

    def test_empty_input_returns_empty_list(self) -> None:
        assert _clixml.extract_warnings(b"") == []


class TestExtractErrorMessage:

    def test_joins_multiline_error_into_readable_text(self) -> None:
        message = _clixml.extract_error_message(_REAL_ERROR_SAMPLE)
        assert "boom test error" in message
        assert "CategoryInfo" in message
        assert "FullyQualifiedErrorId" in message
        # No raw CLIXML markup or escape sequences leaking into the message.
        assert "<Objs" not in message
        assert "<S S=" not in message
        assert "_x000D_" not in message

    def test_falls_back_to_raw_text_for_plain_stderr(self) -> None:
        # No CLIXML at all -- must still return something useful instead of
        # an empty string, matching the pre-#141 behavior for this case.
        assert _clixml.extract_error_message(b"Access is denied.") == "Access is denied."

    def test_falls_back_to_raw_text_when_no_error_stream_present(self) -> None:
        # Valid CLIXML, but only a warning, no Error stream -- must not
        # return an empty string just because parsing "succeeded" with no
        # error content.
        message = _clixml.extract_error_message(_REAL_WARNING_SAMPLE)
        assert message != ""

    def test_empty_input_returns_empty_string(self) -> None:
        assert _clixml.extract_error_message(b"") == ""
