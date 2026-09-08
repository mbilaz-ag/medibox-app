"""Reject APKs with an invalid signature or an unexpected signer."""
import json
from pathlib import Path
import re
import subprocess
import sys


def verify_output(output, expected):
    digests = re.findall(r'Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F]+)', output)
    if not digests or any(d.upper() != expected for d in digests):
        raise ValueError('APK signer differs from the pinned MediBox certificate')


if __name__ == '__main__':
    policy = json.loads((Path(__file__).resolve().parents[1] / 'config/android-signing.json').read_text())
    result = subprocess.run([sys.argv[1], 'verify', '--verbose', '--print-certs', sys.argv[2]],
                            capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('APK signature verification failed')
    verify_output(result.stdout, policy['certificate_sha256'])
    print('APK signature matches the permanent MediBox certificate.')
