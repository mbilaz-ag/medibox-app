"""Prepare the generated Android host for the standalone MediBox Admin app."""

from pathlib import Path
import shutil
import sys


repo = Path(__file__).resolve().parents[2]
admin = repo / "admin_app"
generated = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(repo / "tool"))
from android_signing import configure_android_signing  # noqa: E402

target = admin / "android"
if target.exists():
    shutil.rmtree(target)
shutil.copytree(generated / "android", target)

manifest = target / "app/src/main/AndroidManifest.xml"
text = manifest.read_text()
text = text.replace('android:label="medibox_admin"', 'android:label="MediBox Admin"')
for permission in (
    "android.permission.INTERNET",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.WAKE_LOCK",
):
    if permission not in text:
        text = text.replace(
            "<application",
            f'<uses-permission android:name="{permission}"/>\n    <application',
            1,
        )
manifest.write_text(text)

gradle = target / "app/build.gradle.kts"
gradle.write_text(configure_android_signing(gradle.read_text()))

