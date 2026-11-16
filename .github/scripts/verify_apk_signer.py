"""Compare the verified APK signer PEMs with the expected public DER certificate."""

from pathlib import Path
import re
import subprocess
import sys


def fingerprint(certificate, encoding):
    der = subprocess.check_output(
        ["openssl", "x509", "-inform", encoding, "-outform", "DER"], input=certificate
    )
    return subprocess.check_output(["openssl", "dgst", "-sha256", "-binary"], input=der).hex()


def verify(report, expected_der):
    blocks = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", report, re.S)
    if not blocks:
        raise ValueError("apksigner verified no signer certificates in PEM format.")
    expected = fingerprint(expected_der, "DER")
    found = {fingerprint(pem, "PEM") for pem in blocks}
    if found != {expected}:
        raise ValueError(f"APK signer mismatch. Expected {expected}, found {', '.join(sorted(found))}.")
    print(f"Verified APK signer SHA-256 {expected}")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes())
