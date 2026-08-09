#!/usr/bin/env python3
"""Upload a DMG to Drive and point appcast.json at it.

Usage: publish_appcast.py <version> <dmg-path>

Both the DMG and appcast.json are updated in place using fixed file ids, so the
download URL baked into older builds keeps working. Creating fresh files each
release would leave previously shipped clients pointing at a stale id.

The corporate proxy CA lacks a KeyUsage extension, which OpenSSL 3 rejects, so
verification is disabled for these calls. They only reach Google Drive with an
OAuth token we already hold, and the payload is a build artifact that is about to
be public anyway.
"""

import hashlib
import io
import json
import os
import ssl
import subprocess
import sys

ssl._create_default_https_context = ssl._create_unverified_context

# Lux's own proxy setup exports CURL_CA_BUNDLE and SSL_CERT_FILE system-wide.
# requests' merge_environment_settings treats a CA bundle from the environment as
# a per-request setting, which then overrides session.verify = False, so the
# OAuth refresh fails on the corp CA's missing KeyUsage extension no matter what
# the session says. Clearing them before requests is imported is the only way to
# make verify=False actually mean it.
for _var in ("CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE",
             "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"):
    os.environ.pop(_var, None)
os.environ["PYTHONHTTPSVERIFY"] = "0"

sys.path.insert(0, "/Users/virgoh/lux/scripts")

import requests  # noqa: E402
import urllib3  # noqa: E402
from constants import APPCAST_FILE_ID, DMG_FILE_ID, GDRIVE_FOLDER_ID  # noqa: E402
from google.auth.transport.requests import Request  # noqa: E402
from google.oauth2.credentials import Credentials  # noqa: E402
from googleapiclient.discovery import build  # noqa: E402
from googleapiclient.http import MediaFileUpload, MediaIoBaseUpload  # noqa: E402

urllib3.disable_warnings()

TOKEN = "/Users/virgoh/lux/scripts/.oauth_token.json"
REPO = "/Users/virgoh/lux-clean"

# Set by release.sh after probing which local proxy is reachable. Passed through
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
        # trust_env=False stops requests re-reading proxy and CA settings from the
        # environment and undoing verify=False.
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
        print(f"# in-place update failed ({e}); creating {name}")
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


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip())
        return 2
    version, dmg_rel = sys.argv[1], sys.argv[2]
    dmg = dmg_rel if os.path.isabs(dmg_rel) else os.path.join(REPO, dmg_rel)
    if not os.path.exists(dmg):
        print(f"missing dmg: {dmg}")
        return 1

    digest = sha256_of(dmg)
    size = os.path.getsize(dmg)
    print(f"# dmg {size // 1024 // 1024}MB sha256={digest[:16]}...")

    svc = drive()

    dmg_name = os.path.basename(dmg)
    dmg_id = upload_in_place(
        svc,
        DMG_FILE_ID,
        dmg_name,
        MediaFileUpload(dmg, mimetype="application/octet-stream", resumable=True),
    )
    # Keep the visible name in step with the version even though the id is fixed.
    try:
        svc.files().update(fileId=dmg_id, body={"name": dmg_name}).execute()
    except Exception as e:
        print(f"# could not rename dmg: {e}")

    url = (
        f"https://drive.usercontent.google.com/download"
        f"?id={dmg_id}&export=download&confirm=t"
    )

    notes = subprocess.run(
        ["git", "-C", REPO, "log", "-1", "--pretty=%s"],
        capture_output=True,
        text=True,
    ).stdout.strip()

    appcast = {
        "version": version,
        "channel": "stable",
        "notes": notes,
        "macOS": {"url": url, "sha256": digest, "size": size},
        "windows": {"url": "", "sha256": "", "size": 0},
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

    print(f"# appcast -> {version}")
    print(f"# url {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
