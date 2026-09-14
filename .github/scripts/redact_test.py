#!/usr/bin/env python3
"""Regression tests for redact.py (run: python3 .github/scripts/redact_test.py)."""
from __future__ import annotations

import base64
import binascii
import json
import pathlib
import sys
import tempfile

# Import sibling module without requiring package install.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import redact  # noqa: E402


def _assert(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def test_apply_ranges_single_pass() -> None:
    data = b"aaaSECRETbbbSECRETccc"
    ranges = [(3, 9), (12, 18)]
    out = redact.apply_ranges(data, ranges)
    _assert(out == b"aaa[REDACTED]bbb[REDACTED]ccc", f"unexpected: {out!r}")


def test_short_quoted_b64_when_path_unresolved() -> None:
    """16-39-char quoted b64 must wipe even when File path does not resolve."""
    # 24-byte secret -> 32-char std base64 (between 16 and 39).
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    encoded = base64.b64encode(secret)
    _assert(16 <= len(encoded) <= 39, f"fixture length {len(encoded)} not in 16-39")

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        # Secret only inside quoted base64; no cleartext copy.
        target.write_bytes(b'payload="' + encoded + b'"\n')

        findings = [
            {
                "Secret": secret.decode("ascii"),
                # Unresolvable path: no column wipe; encoded-field path only.
                "File": "/scan/missing/does-not-exist.log",
                "StartLine": 1,
                "EndLine": 1,
                "StartColumn": 1,
                "EndColumn": 10,
            }
        ]
        findings_path = root / "findings.json"
        findings_path.write_text(json.dumps(findings))

        redact.redact_tree(findings, root)
        published = target.read_bytes()
        _assert(encoded not in published, f"encoded blob still present: {published!r}")
        _assert(secret not in published, f"secret still present: {published!r}")
        _assert(b"[REDACTED]" in published, f"marker missing: {published!r}")


def test_unquoted_token_b64_when_path_unresolved() -> None:
    """Unquoted token=<b64> must wipe when File path does not resolve."""
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    encoded = base64.b64encode(secret)
    _assert(16 <= len(encoded) <= 39, f"fixture length {len(encoded)} not in 16-39")

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        # Unquoted assignment; no cleartext secret copy.
        target.write_bytes(b"token=" + encoded + b"\n")

        findings = [
            {
                "Secret": secret.decode("ascii"),
                "File": "/scan/missing/does-not-exist.log",
                "StartLine": 1,
                "EndLine": 1,
                "StartColumn": 1,
                "EndColumn": 10,
            }
        ]
        (root / "findings.json").write_text(json.dumps(findings))

        redact.redact_tree(findings, root)
        published = target.read_bytes()
        _assert(encoded not in published, f"encoded blob still present: {published!r}")
        _assert(secret not in published, f"secret still present: {published!r}")
        _assert(b"[REDACTED]" in published, f"marker missing: {published!r}")
        _assert(
            published.startswith(b"token=[REDACTED]"),
            f"assignment prefix lost: {published!r}",
        )


def test_hex_encoded_secret_when_path_unresolved() -> None:
    """Hex-encoded Secret must wipe when File path does not resolve."""
    secret = b"ABCDEFGHIJKLMNOP"
    encoded = binascii.hexlify(secret)
    _assert(len(encoded) == 32, f"fixture hex length {len(encoded)}")

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b"blob=" + encoded + b"\n")

        findings = [
            {
                "Secret": secret.decode("ascii"),
                "File": "/scan/missing/does-not-exist.log",
                "StartLine": 1,
                "EndLine": 1,
                "StartColumn": 1,
                "EndColumn": 10,
            }
        ]
        (root / "findings.json").write_text(json.dumps(findings))

        redact.redact_tree(findings, root)
        published = target.read_bytes()
        _assert(encoded not in published, f"hex blob still present: {published!r}")
        _assert(secret not in published, f"secret still present: {published!r}")
        _assert(b"[REDACTED]" in published, f"marker missing: {published!r}")


def test_hex_encoded_secret_mixed_case_when_path_unresolved() -> None:
    """Mixed-case hex encodings must wipe when File path does not resolve."""
    secret = b"ABCDEFGHIJKLMNOP"
    lower = binascii.hexlify(secret)
    # Mix case on a-f digits only (ASCII secret → utf-8 Secret roundtrip safe).
    # Neither pure lower nor pure upper — catches case-insensitive search gaps.
    letter_i = 0
    mixed_chars: list[int] = []
    for c in lower:
        if 97 <= c <= 102:  # a-f
            mixed_chars.append(c - 32 if letter_i % 2 == 0 else c)
            letter_i += 1
        else:
            mixed_chars.append(c)
    mixed = bytes(mixed_chars)
    _assert(mixed != lower, "fixture should differ from lowercase")
    _assert(mixed != lower.upper(), "fixture should differ from uppercase")
    _assert(mixed.lower() == lower, "fixture must decode same")

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b"blob=" + mixed + b"\n")

        findings = [
            {
                "Secret": secret.decode("ascii"),
                "File": "/scan/missing/does-not-exist.log",
                "StartLine": 1,
                "EndLine": 1,
                "StartColumn": 1,
                "EndColumn": 10,
            }
        ]
        (root / "findings.json").write_text(json.dumps(findings))

        redact.redact_tree(findings, root)
        published = target.read_bytes()
        _assert(mixed not in published, f"mixed-case hex still present: {published!r}")
        _assert(b"[REDACTED]" in published, f"marker missing: {published!r}")


def test_resolve_path_rejects_traversal() -> None:
    """File fields with .. or symlink escape must not resolve outside root."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "redacted"
        root.mkdir()
        (root / "ok.log").write_text("inside\n")
        outside = pathlib.Path(tmp) / "outside.log"
        outside.write_text("SECRET\n")
        # Symlink under redacted_dir pointing outside.
        link = root / "escape.log"
        link.symlink_to(outside)

        _assert(
            redact.resolve_path(root, "/scan/../outside.log") is None,
            "expected .. traversal to be rejected",
        )
        _assert(
            redact.resolve_path(root, "/scan/escape.log") is None,
            "expected symlink escape to be rejected",
        )
        _assert(
            redact.resolve_path(root, "/scan/ok.log") == root / "ok.log",
            "expected in-tree path to resolve",
        )


def _b64url_nopad(data: bytes) -> str:
    """URL-safe Base64 without padding (JWT compact-form segment)."""
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _make_fake_jwt() -> str:
    """Build a compact JWT at runtime so source has no token-shaped literal."""
    header = _b64url_nopad(b'{"alg":"none"}')
    payload = _b64url_nopad(b'{"sub":"test-user","name":"example"}')
    signature = "testsignaturevalue"
    return f"{header}.{payload}.{signature}"


_FAKE_JWT = _make_fake_jwt()


def _decoded_finding(
    secret: str,
    file_field: str,
    *,
    start_col: int = 1,
    end_col: int = 5,
    depth: int = 2,
    encoding: str = "base64",
) -> dict:
    return {
        "Secret": secret,
        "File": file_field,
        "StartLine": 1,
        "EndLine": 1,
        "StartColumn": start_col,
        "EndColumn": end_col,
        "Tags": [f"decoded:{encoding}", f"decode-depth:{depth}"],
        "RuleID": "jwt",
    }


def test_embedded_b64_in_mixed_json_string() -> None:
    """AAP jobs-page analog: b64 wrapper inside mixed stdout, not a whole field."""
    inner = json.dumps({"access_token": _FAKE_JWT}, separators=(",", ":")).encode()
    outer = base64.b64encode(inner)
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "jobs-page-1.json"
        # One minified line; quoted value is NOT pure b64 (prefix/suffix text).
        target.write_bytes(
            b'{"keep":"VISIBLE","results":[{"stdout":"begin ' + outer + b' end"}]}'
        )
        redact.redact_tree(
            [_decoded_finding(_FAKE_JWT, "/scan/jobs-page-1.json", depth=2)],
            root,
        )
        published = target.read_bytes()
        _assert(outer not in published, f"wrapper still present: {published!r}")
        _assert(_FAKE_JWT.encode() not in published, "jwt still present")
        _assert(b"VISIBLE" in published, "unrelated JSON field was wiped")
        _assert(b"begin [REDACTED] end" in published, f"marker placement: {published!r}")


def test_decoded_depth2_columns_do_not_nibble() -> None:
    """Depth>=2 columns are parent-buffer coords; must not punch KEEP prefix."""
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    encoded = base64.b64encode(secret)
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        # Columns 1-4 would wipe KEEP if applied blindly.
        target.write_bytes(b"KEEP " + encoded + b"\n")
        redact.redact_tree(
            [
                _decoded_finding(
                    secret.decode("ascii"),
                    "/scan/app.log",
                    start_col=1,
                    end_col=4,
                    depth=2,
                )
            ],
            root,
        )
        published = target.read_bytes()
        _assert(published.startswith(b"KEEP "), f"prefix nibbled: {published!r}")
        _assert(encoded not in published, "wrapper not wiped")
        _assert(b"[REDACTED]" in published, "marker missing")


def test_decoded_depth1_verified_columns_wipe_wrapper() -> None:
    """Depth-1 columns that actually bound the wrapper still wipe it."""
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    encoded = base64.b64encode(secret)
    prefix = b'{"x":"'
    suffix = b'"}'
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(prefix + encoded + suffix)
        start_col = len(prefix) + 1
        end_col = len(prefix) + len(encoded)
        redact.redact_tree(
            [
                _decoded_finding(
                    secret.decode("ascii"),
                    "/scan/app.log",
                    start_col=start_col,
                    end_col=end_col,
                    depth=1,
                )
            ],
            root,
        )
        published = target.read_bytes()
        _assert(encoded not in published, f"wrapper still present: {published!r}")
        _assert(published.startswith(prefix), f"prefix lost: {published!r}")
        _assert(published.endswith(suffix), f"suffix lost: {published!r}")


def test_percent_encoded_secret() -> None:
    """gitleaks decoded:percent runs must wipe when Secret is only percent-encoded."""
    secret = b"ABCDEFGHIJKLMNOP"
    # quote_from_bytes never percent-encodes letters; build a raw %XX run.
    encoded = "".join(f"%{byte:02X}" for byte in secret).encode("ascii")
    _assert(encoded.count(b"%") >= 8, f"fixture too short: {encoded!r}")
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b"token=" + encoded + b"\n")
        redact.redact_tree(
            [
                _decoded_finding(
                    secret.decode("ascii"),
                    "/scan/app.log",
                    depth=1,
                    encoding="percent",
                )
            ],
            root,
        )
        published = target.read_bytes()
        _assert(encoded not in published, f"percent blob still present: {published!r}")
        _assert(secret not in published, "secret still present")
        _assert(b"[REDACTED]" in published, "marker missing")


def test_unrelated_b64_not_wiped() -> None:
    """Peel only blobs that decode to a finding Secret — not every b64 token."""
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    encoded = base64.b64encode(secret)
    innocent = base64.b64encode(b"not-a-secret-value!!")
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b'innocent="' + innocent + b'" payload="' + encoded + b'"\n')
        redact.redact_tree(
            [_decoded_finding(secret.decode("ascii"), "/scan/app.log", depth=2)],
            root,
        )
        published = target.read_bytes()
        _assert(innocent in published, f"unrelated b64 wiped: {published!r}")
        _assert(encoded not in published, "secret wrapper not wiped")


def test_caas_jobs_page_decoded_payload_leaves_no_compact_jwt() -> None:
    """CaaS leftover: Secret is decoded jwt payload; compact jwt sits in extra_vars.

    Depth-2 columns 1-4 would nibble the JSON prefix (summa[REDACTED]...) if
    applied as file bytes. Compact jwt must still be wiped; prefix must stay.
    """
    payload_b64 = _FAKE_JWT.split(".")[1]
    payload = base64.urlsafe_b64decode(payload_b64 + "==")
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "jobs-page-1.json"
        prefix = b'{"count":1,"results":[{"summary_fields":{"foo":1},"extra_vars":"'
        body = b"token: " + _FAKE_JWT.encode() + b"\\nkubeconfig: ignored"
        suffix = b'"}]}'
        target.write_bytes(prefix + body + suffix)
        redact.redact_tree(
            [
                _decoded_finding(
                    payload.decode("ascii"),
                    "/scan/jobs-page-1.json",
                    start_col=1,
                    end_col=4,
                    depth=2,
                )
            ],
            root,
        )
        published = target.read_bytes()
        _assert(
            published.startswith(b'{"count":1'),
            f"JSON prefix nibbled: {published[:40]!r}",
        )
        _assert(_FAKE_JWT.encode() not in published, "compact jwt still present")
        _assert(b"eyJ" not in published, f"jwt fragment left: {published!r}")
        _assert(b"[REDACTED]" in published, "marker missing")


def test_b64_wrapped_hex_secret() -> None:
    """base64(hex(secret)) must peel; exclusive b64-then-hex fallbacks miss it."""
    secret = b"ABCDEFGHIJKLMNOPQRSTUVWX"
    hexed = binascii.hexlify(secret)
    wrapped = base64.b64encode(hexed)
    _assert(
        redact.blob_decodes_to_secret(wrapped, [secret]),
        "peel missed b64(hex(secret))",
    )
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b"blob=" + wrapped + b"\n")
        redact.redact_tree(
            [_decoded_finding(secret.decode("ascii"), "/scan/app.log", depth=2)],
            root,
        )
        published = target.read_bytes()
        _assert(wrapped not in published, f"wrapper still present: {published!r}")
        _assert(hexed not in published, "hex layer still present")
        _assert(secret not in published, "secret still present")
        _assert(b"[REDACTED]" in published, "marker missing")


def test_hex_wrapper_of_json_containing_secret() -> None:
    """decoded:hex of a JSON wrapper, not hex(secret) itself."""
    inner = json.dumps({"access_token": _FAKE_JWT}, separators=(",", ":")).encode()
    hexed = binascii.hexlify(inner)
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        target = root / "app.log"
        target.write_bytes(b"blob=" + hexed + b"\n")
        redact.redact_tree(
            [_decoded_finding(_FAKE_JWT, "/scan/app.log", depth=2, encoding="hex")],
            root,
        )
        published = target.read_bytes()
        _assert(hexed not in published, f"hex wrapper still present: {published!r}")
        _assert(_FAKE_JWT.encode() not in published, "jwt still present")
        _assert(published.startswith(b"blob=[REDACTED]\n"), f"unexpected: {published!r}")


def main() -> None:
    test_apply_ranges_single_pass()
    test_short_quoted_b64_when_path_unresolved()
    test_unquoted_token_b64_when_path_unresolved()
    test_hex_encoded_secret_when_path_unresolved()
    test_hex_encoded_secret_mixed_case_when_path_unresolved()
    test_resolve_path_rejects_traversal()
    test_embedded_b64_in_mixed_json_string()
    test_decoded_depth2_columns_do_not_nibble()
    test_decoded_depth1_verified_columns_wipe_wrapper()
    test_percent_encoded_secret()
    test_unrelated_b64_not_wiped()
    test_caas_jobs_page_decoded_payload_leaves_no_compact_jwt()
    test_b64_wrapped_hex_secret()
    test_hex_wrapper_of_json_containing_secret()
    print("redact_test.py: ok")



if __name__ == "__main__":
    main()
