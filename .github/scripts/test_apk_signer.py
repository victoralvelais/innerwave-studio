import unittest
from unittest.mock import patch

from verify_apk_signer import verify


def block(encoded):
    return b"-----BEGIN CERTIFICATE-----\n" + encoded + b"\n-----END CERTIFICATE-----"


class SignerOutputTests(unittest.TestCase):
    def test_metadata_labels_and_duplicate_prints_do_not_change_signer_identity(self):
        report = b"Signing scheme v3 (SDK range 28+):\n" + block(b"A") + b"\n" + block(b"A")
        with patch("verify_apk_signer.fingerprint", return_value="aa") as fingerprint:
            verify(report, b"expected public DER")
        self.assertEqual(fingerprint.call_args_list[0].args, (b"expected public DER", "DER"))
        self.assertEqual(fingerprint.call_args_list[1].args, (block(b"A"), "PEM"))

    def test_missing_or_additional_signer_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no signer"):
            verify(b"human readable text only", b"der")
        with patch("verify_apk_signer.fingerprint", side_effect=["aa", "aa", "bb"]):
            with self.assertRaisesRegex(ValueError, "signer mismatch"):
                verify(block(b"A") + b"\n" + block(b"B"), b"der")
