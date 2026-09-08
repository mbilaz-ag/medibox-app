"""Restore the owner's signing key outside checkout; never log key material."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def restore_key(encoded, password, runner_temp, policy, github_env):
    if not encoded or not password:
        raise ValueError('Both MediBox signing secrets must be configured')
    if len(encoded) > 40000:
        raise ValueError('Signing key is too large')
    try:
        raw = base64.b64decode(''.join(encoded.split()), validate=True)
    except Exception:
        raise ValueError('Invalid signing key encoding') from None
    private_dir = Path(tempfile.mkdtemp(prefix='medibox-signing-', dir=runner_temp))
    key = private_dir / 'release.p12'
    try:
        with key.open('xb') as stream:
            os.chmod(key, 0o600)
            stream.write(raw)
        result = subprocess.run([
            'keytool', '-exportcert', '-keystore', str(key),
            '-storetype', policy['store_type'], '-alias', policy['alias'],
            '-storepass:env', 'MEDIBOX_KEYSTORE_PASSWORD',
        ], env=dict(os.environ, MEDIBOX_KEYSTORE_PASSWORD=password),
            capture_output=True, timeout=30)
        digest = hashlib.sha256(result.stdout).hexdigest().upper()
        if result.returncode != 0 or digest != policy['certificate_sha256']:
            raise ValueError('Signing certificate does not match the pinned certificate')
        with Path(github_env).open('a') as stream:
            stream.write(f'MEDIBOX_KEYSTORE_PATH={key}\n')
        return key
    except BaseException:
        key.unlink(missing_ok=True)
        private_dir.rmdir()
        raise


if __name__ == '__main__':
    try:
        policy = json.loads((Path(__file__).resolve().parents[1] / 'config/android-signing.json').read_text())
        restore_key(os.environ.get('MEDIBOX_KEYSTORE_BASE64', ''),
                    os.environ.get('MEDIBOX_KEYSTORE_PASSWORD', ''),
                    os.environ['RUNNER_TEMP'], policy, os.environ['GITHUB_ENV'])
    except Exception:
        raise SystemExit('MediBox signing setup failed. Check the two repository signing secrets.') from None
    print('Permanent signing certificate verified; temporary key ready.')
