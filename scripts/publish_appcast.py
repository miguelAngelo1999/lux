#!/usr/bin/env python3
"""Upload a DMG to Drive and point an appcast at it.

Usage: publish_appcast.py <version> <dmg-path> [--channel stable|beta]

Both the DMG and appcast file are updated in place using fixed file ids, so the
download URL baked into older builds keeps working. Creating fresh files each
release would leave previously shipped clients pointing at a stale id.

Channels are two entirely separate files/ids (appcast.json for stable,
appcast-beta.json for beta) — never one file with a "channel" tag clients are
expected to filter on. Nothing in the app reads the top-level "channel" field;
which appcast URL a client fetches is what actually gates a beta build, decided
client-side by a Settings toggle (default: stable).

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
from constants import (  # noqa: E402
    APPCAST_FILE_ID,
    BETA_APPCAST_FILE_ID,
    BETA_APPCAST_FILE_NAME,
    DMG_FILE_ID,
    GDRIVE_FOLDER_ID,
)
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
    # httplib2 ignores env proxy vars. Monkey-patch the connection class to use the proxy.
    if PROXY:
        import httplib2
        pi = httplib2.ProxyInfo(
            proxy_type=3,  # PROXY_TYPE_HTTP
            proxy_host="127.0.0.1",
            proxy_port=8079,
        )
        authed_http = svc._http
        if hasattr(authed_http, 'http'):
            authed_http.http.proxy_info = pi
            authed_http.http.disable_ssl_certificate_validation = True
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


def fetch_appcast(svc, appcast_file_id):
    """The appcast as it stands on Drive.

    Read before write so the platform this script is not publishing keeps
    its download URL. Building the dict from scratch is what silently
    disabled Windows updates for every release after 1.46.9.
    """
    try:
        raw = svc.files().get_media(fileId=appcast_file_id).execute()
        if isinstance(raw, bytes):
            raw = raw.decode()
        return json.loads(raw)
    except Exception as e:
        print(f"# could not read existing appcast ({e}); starting fresh")
        return {}


def platform_entry(appcast, key):
    """Existing entry for a platform, normalised, or an empty one.

    Preserves "version" too — dropping it here is what makes the OTHER
    platform's client fall back to the top-level "version" field and loop
    forever on a false update prompt (this exact bug shipped twice).
    """
    entry = appcast.get(key) or {}
    return {
        "url": entry.get("url", ""),
        "sha256": entry.get("sha256", ""),
        "size": entry.get("size", 0),
        "version": entry.get("version", ""),
    }


def release_notes():
    """Subject of the newest commit that is not itself a release commit.

    Taking the newest commit outright described the *previous* release, because
    the release commit is the most recent thing on the branch by the time this
    runs. LUX_RELEASE_NOTES overrides when the summary needs to read better than
    a commit subject.
    """
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
    # Build positional args list and extract --channel value
    channel = "stable"
    positional = []
    skip_next = False
    for i, a in enumerate(sys.argv[1:]):
        if skip_next:
            skip_next = False
            continue
        if a.startswith("--channel="):
            channel = a.split("=", 1)[1].strip().lower()
        elif a == "--channel" and i + 1 < len(sys.argv) - 1:
            channel = sys.argv[i + 2].strip().lower()
            skip_next = True
        elif not a.startswith("--"):
            positional.append(a)

    if len(positional) != 2:
        print(__doc__.strip())
        return 2
    if channel not in ("stable", "beta"):
        print(f"invalid --channel {channel!r}; must be stable or beta")
        return 2

    version, dmg_rel = positional
    dmg = dmg_rel if os.path.isabs(dmg_rel) else os.path.join(REPO, dmg_rel)
    if not os.path.exists(dmg):
        print(f"missing dmg: {dmg}")
        return 1

    appcast_file_id = BETA_APPCAST_FILE_ID if channel == "beta" else APPCAST_FILE_ID
    appcast_local_name = BETA_APPCAST_FILE_NAME if channel == "beta" else "appcast.json"
    dmg_drive_name_prefix = "beta-" if channel == "beta" else ""

    digest = sha256_of(dmg)
    size = os.path.getsize(dmg)
    print(f"# channel: {channel}")
    print(f"# dmg {size // 1024 // 1024}MB sha256={digest[:16]}...")

    svc = drive()

    # Beta and stable DMGs share the same Drive file id only for stable (fixed
    # id baked into old clients). A beta build always gets a fresh Drive file —
    # there is no old beta client depending on a stable beta URL, and reusing
    # the stable DMG_FILE_ID would overwrite the current stable download.
    dmg_name = os.path.basename(dmg)
    if channel == "beta":
        created = svc.files().create(
            body={"name": f"{dmg_drive_name_prefix}{dmg_name}", "parents": [GDRIVE_FOLDER_ID]},
            media_body=MediaFileUpload(dmg, mimetype="application/octet-stream", resumable=True),
            fields="id",
        ).execute()
        svc.permissions().create(
            fileId=created["id"], body={"type": "anyone", "role": "reader"}
        ).execute()
        dmg_id = created["id"]
    else:
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

    notes = release_notes()

    current = fetch_appcast(svc, appcast_file_id)
    windows = platform_entry(current, "windows")
    if windows["url"]:
        print("# preserving windows entry, {} bytes, version={}".format(
            windows["size"], windows["version"] or "(none)"))
    else:
        print("# no windows entry to preserve")

    # Top-level "version" is informational only — display/debugging, e.g. in a
    # release-notes email. NOTHING should compare against it: the Dart client
    # reads macOS.version / windows.version for the platform it's running on,
    # falling back to this field only for appcast files old enough to predate
    # per-platform versioning. Do NOT set this to max(macOS, windows) — that
    # silently breaks the OTHER platform's "no update available" check the
    # next time only this platform ships, which is exactly what caused the
    # 2026-09-01 infinite-update-prompt bug on macOS.
    appcast = {
        "version": version,
        "channel": channel,
        "notes": notes,
        "macOS": {"url": url, "sha256": digest, "size": size, "version": version},
        # Carried over, never blanked. This script publishes the macOS
        # build only; clobbering this is what broke Windows updates.
        "windows": windows,
    }
    body = json.dumps(appcast, indent=2) + "\n"

    upload_in_place(
        svc,
        appcast_file_id,
        appcast_local_name,
        MediaIoBaseUpload(io.BytesIO(body.encode()), mimetype="application/json"),
    )

    with open(os.path.join(REPO, appcast_local_name), "w") as f:
        f.write(body)

    print(f"# {appcast_local_name} -> {version}")
    print(f"# url {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
