import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
from android_signing import configure_android_signing
from restore_release_keystore import restore_key
from verify_apk_signer import verify_output

TEMPLATE = '''android {
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}
'''
POLICY = {'store_type': 'PKCS12', 'alias': 'medibox-release',
          'certificate_sha256': hashlib.sha256(b'public-certificate').hexdigest().upper()}


class SigningTests(unittest.TestCase):
    def test_config_uses_environment_and_removes_debug(self):
        actual = configure_android_signing(TEMPLATE)
        self.assertNotIn('signingConfigs.getByName("debug")', actual)
        self.assertIn('signingConfigs.getByName("mediboxRelease")', actual)
        self.assertIn('System.getenv("MEDIBOX_KEYSTORE_PASSWORD")', actual)
        self.assertIn('check(!System.getenv("MEDIBOX_KEYSTORE_PATH").isNullOrBlank())', actual)

    def test_idempotence(self):
        actual = configure_android_signing(TEMPLATE)
        self.assertEqual(actual, configure_android_signing(actual))

    def test_unrecognized_templates_fail(self):
        for value in ('android {}', TEMPLATE * 2):
            with self.assertRaises(ValueError):
                configure_android_signing(value)

    def test_missing_secrets_does_not_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                restore_key('', '', tmp, POLICY, Path(tmp) / 'env')
            self.assertEqual(list(Path(tmp).iterdir()), [])

    @patch('restore_release_keystore.subprocess.run')
    def test_wrong_certificate_is_removed(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, b'wrong', b'')
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                restore_key('dGVzdA==', 'test-password', tmp, POLICY, Path(tmp) / 'env')
            self.assertEqual(list(Path(tmp).iterdir()), [])

    @patch('restore_release_keystore.subprocess.run')
    def test_restored_key_private_and_environment_has_no_password(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, b'public-certificate', b'')
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / 'env'
            key = restore_key('dGVzdA==', 'test-password', tmp, POLICY, env)
            self.assertEqual(key.read_bytes(), b'test')
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertEqual(key.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(env.read_text(), f'MEDIBOX_KEYSTORE_PATH={key}\n')
            self.assertNotIn('test-password', env.read_text())

    def test_apk_signer_must_match_every_signer(self):
        expected = POLICY['certificate_sha256']
        valid = f'Signer #1 certificate SHA-256 digest: {expected.lower()}'
        verify_output(valid, expected)
        for value in ('', 'Signer #1 certificate SHA-256 digest: 0123',
                      valid + '\nSigner #2 certificate SHA-256 digest: 0123'):
            with self.assertRaises(ValueError):
                verify_output(value, expected)


if __name__ == '__main__':
    unittest.main()
