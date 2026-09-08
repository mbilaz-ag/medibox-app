"""Reject APKs with an invalid signature or an unexpected signer."""
import json
from pathlib import Path
import re
import subprocess
import sys


def verify_output(output, expected):
    matches = re.findall(
        r'certificate\s+SHA[- ]?256\s+digest:\s*([0-9a-fA-F:\s]+)',
        output,
        flags=re.IGNORECASE,
    )
    digests = [re.sub(r'[^0-9a-fA-F]', '', value).upper() for value in matches]
    if not digests or any(d.upper() != expected for d in digests):
        observed = ', '.join(digests) or 'none'
        raise ValueError(
            'APK signer differs from the pinned MediBox certificate; '
            f'observed SHA-256: {observed}'
        )


if __name__ == '__main__':
    policy = json.loads((Path(__file__).resolve().parents[1] / 'config/android-signing.json').read_text())
    result = subprocess.run([sys.argv[1], 'verify', '--verbose', '--print-certs', sys.argv[2]],
                            capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('APK signature verification failed')
    verify_output(result.stdout + '\n' + result.stderr,
                  policy['certificate_sha256'])
    print('APK signature matches the permanent MediBox certificate.')
