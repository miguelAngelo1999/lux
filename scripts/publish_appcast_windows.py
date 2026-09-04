#!/usr/bin/env python3
"""Upload a Windows installer to Drive and point appcast.json at it.

Usage: publish_appcast_windows.py <version> <installer-path>

The Windows counterpart of publish_appcast.py. Both scripts share one appcast
file, so each reads the current contents and replaces only its own platform key.
publish_appcast.py used to rebuild the whole document and hardcode an empty
"windows" block, which wiped the Windows download URL on every macOS release and
left Windows clients with no updates from 1.48.5 onward.

The installer is written to a fixed file id so the download URL baked into
already-shipped builds keeps resolving.

TLS verification is disabled for these calls because the corporate proxy CA has
no KeyUsage extension and OpenSSL 3 rejects it. The requests still authenticate
with an OAuth token we hold, and the payload is a build artifact about to be
published anyway.
"""

import hashlib
import io
import json
import os
import ssl
import subprocess
import sys

ssl._create_default_https_context = ssl._create_unverified_context

# Lux exports CURL_CA_BUNDLE and SSL_CERT_FILE system-wide while proxying. In
# requests, a CA bundle picked up from the environment outranks session.verify,
# so the OAuth refresh fails on the corp CA no matter what the session says.
# Clearing these before requests is imported is what makes verify=False bite.
for _var in ("CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE",
             "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"):
    os.environ.pop(_var, None)
os.environ["PYTHONHTTPSVERIFY"] = "0"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

import requests  # noqa: E402
import urllib3  # noqa: E402
from constants import APPCAST_FILE_ID, GDRIVE_FOLDER_ID, WINDOWS_FILE_ID  # noqa: E402
from google.auth.transport.requests import Request  # noqa: E402
from google.oauth2.credentials import Credentials  # noqa: E402
from googleapiclient.discovery import build  # noqa: E402
from googleapiclient.http import MediaFileUpload, MediaIoBaseUpload  # noqa: E402

urllib3.disable_warnings()

# Unlike the macOS script this cannot assume a home directory layout, so the
# token location is overridable and defaults to sitting next to this script.
TOKEN = os.environ.get(
    "LUX_OAUTH_TOKEN", os.path.join(SCRIPT_DIR, ".oauth_token.json")
)

# Set by the caller after probing which local proxy is reachable. Passed
# explicitly because trust_env is off.
PROXY = os.environ.get("LUX_RELEASE_PROXY", "")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def drive():
    creds = Credentials.from_authorized_user_file(
        TOKEN, ["https://www.googleapis.com/auth/drive"]
    )
    if not creds.valid:
        sess = requests.Session()
        # trust_env=False stops requests re-reading proxy and CA settings from
        # the environment and undoing verify=False.
        sess.trust_env = False
        sess.verify = False
        sess.proxies = {"http": PROXY, "https": PROXY} if PROXY else {}
        creds.refresh(Request(session=sess))
    svc = build("drive", "v3", credentials=creds)
    try:
        svc._http.http.disable_ssl_certificate_validation = True
    except Exception:
        pass
    return svc


def upload_in_place(svc, file_id, name, media):
    """Overwrite a known file, falling back to creating it if the id is gone."""
    try:
        svc.files().update(fileId=file_id, media_body=media, fields="id").execute()
        return file_id
    except Exception as e:
        print("# in-place update failed ({}); creating {}".format(e, name))
        created = (
            svc.files()
            .create(
                body={"name": name, "parents": [GDRIVE_FOLDER_ID]},
                media_body=media,
                fields="id",
            )
            .execute()
        )
        svc.permissions().create(
            fileId=created["id"], body={"type": "anyone", "role": "reader"}
        ).execute()
        return created["id"]


def fetch_appcast(svc):
    """The appcast as it stands on Drive, so the macOS entry survives."""
    try:
        raw = svc.files().get_media(fileId=APPCAST_FILE_ID).execute()
        if isinstance(raw, bytes):
            raw = raw.decode()
        return json.loads(raw)
    except Exception as e:
        print("# could not read existing appcast ({}); starting fresh".format(e))
        return {}


def platform_entry(appcast, key):
    """Existing entry for a platform, normalised, or an empty one."""
    entry = appcast.get(key) or {}
    result = {
        "url": entry.get("url", ""),
        "sha256": entry.get("sha256", ""),
        "size": entry.get("size", 0),
    }
    if entry.get("version"):
        result["version"] = entry["version"]
    return result


def release_notes():
    """Subject of the newest commit that is not itself a release commit."""
    override = os.environ.get("LUX_RELEASE_NOTES", "").strip()
    if override:
        return override

    log = subprocess.run(
        ["git", "-C", REPO, "log", "-30", "--pretty=%s"],
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    for subject in log:
        s = subject.strip()
        if s and not s.startswith(("release:", "chore: bump")):
            return s
    return log[0].strip() if log else ""


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip())
        return 2

    version, exe_rel = sys.argv[1], sys.argv[2]
    exe = exe_rel if os.path.isabs(exe_rel) else os.path.join(REPO, exe_rel)
    if not os.path.exists(exe):
        print("missing installer: {}".format(exe))
        return 1

    digest = sha256_of(exe)
    size = os.path.getsize(exe)
    print("# installer {}MB sha256={}...".format(size // 1024 // 1024, digest[:16]))

    svc = drive()

    exe_name = os.path.basename(exe)
    exe_id = upload_in_place(
        svc,
        WINDOWS_FILE_ID,
        exe_name,
        MediaFileUpload(exe, mimetype="application/octet-stream", resumable=True),
    )
    # Keep the visible name in step with the version even though the id is fixed.
    try:
        svc.files().update(fileId=exe_id, body={"name": exe_name}).execute()
    except Exception as e:
        print("# could not rename installer: {}".format(e))

    url = (
        "https://drive.usercontent.google.com/download"
        "?id={}&export=download&confirm=t".format(exe_id)
    )

    current = fetch_appcast(svc)
    macos = platform_entry(current, "macOS")
    if macos["url"]:
        print("# preserving macOS entry, {} bytes".format(macos["size"]))
    else:
        print("# no macOS entry to preserve")

    # One version field covers both platforms, so publishing a Windows build at
    # a version the macOS build has not reached would offer Mac users a
    # downgrade, and vice versa. Refuse rather than half-break one platform.
    # Per-platform versioning: each platform carries its own version field
    # (windows.version, macOS.version). The top-level "version" field is kept
    # as the higher of the two for backward compatibility with old clients, but
    # the updater now reads the per-platform field so platforms can release
    # independently without ever blocking or skewing each other.
    macos_version = (macos.get("version") or current.get("version") or "").strip()
    top_version = version  # Windows is publishing now, so it's at least this
    if macos_version:
        try:
            from packaging.version import Version as PkgV
            top_version = str(max(PkgV(version), PkgV(macos_version)))
        except Exception:
            top_version = version  # packaging not available — use Windows version

    appcast = {
        "version": top_version,
        "channel": "stable",
        "notes": os.environ.get("LUX_RELEASE_NOTES", "").strip() or release_notes(),
        # Carried over, never blanked. This script publishes the Windows build
        # only; the macOS entry belongs to publish_appcast.py.
        "macOS": macos,
        "windows": {"url": url, "sha256": digest, "size": size, "version": version},
    }
    body = json.dumps(appcast, indent=2) + "\n"

    upload_in_place(
        svc,
        APPCAST_FILE_ID,
        "appcast.json",
        MediaIoBaseUpload(io.BytesIO(body.encode()), mimetype="application/json"),
    )

    with open(os.path.join(REPO, "appcast.json"), "w") as f:
        f.write(body)

    print("# appcast -> {}".format(version))
    print("# url {}".format(url))
    return 0


if __name__ == "__main__":
    sys.exit(main())