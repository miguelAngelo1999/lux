# Lux release infrastructure constants

GDRIVE_FOLDER_ID     = '1FMBWkcE77YM6aWYJqpKG0PalvqGsr5tI'
SERVICE_ACCOUNT_KEY  = '/Users/virgoh/lux/lucky-science-501221-c2-7248ccec3971.json'
GITHUB_REPO          = 'miguelAngelo1999/lux'
APP_NAME             = 'Lux'
DMG_BASENAME         = 'Lux-{version}-macOS-universal.dmg'
WINDOWS_BASENAME     = 'Lux-{version}-Windows-x64.exe'

# These are set after first upload and baked into Flutter (see lib/const/const.dart)
# The appcast.json file ID is stable — we overwrite its content each release
APPCAST_FILE_NAME    = 'appcast.json'
APPCAST_FILE_ID      = '1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p'
BETA_APPCAST_FILE_ID   = '1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p'  # same as stable for now
BETA_APPCAST_FILE_NAME = 'appcast.json'
# Stable DMG file ID — always update in-place so the download URL never changes
DMG_FILE_ID          = '1o6CAVZ3syI-_RYxYnDgOkzD1byWTAVM-'
# Stable Windows installer file ID - same in-place rule as the DMG. This is
# the id every appcast from 1.41.0 to 1.46.9 pointed at; reusing it keeps the
# download URL valid for clients already in the field.
WINDOWS_FILE_ID      = '1lfAXXY2i85dAo9MJ736XWtBdGNQqd2OG'

# Stable installer script file ID — always update in-place
INSTALLER_FILE_ID    = '1ZTzfxWISXtt6yB8CG_xSTmiG0IhonA_S'
TELEMETRY_URL        = 'https://script.google.com/macros/s/AKfycbwWUZPchIiZgKExLuPOS9LVucUrMSa_PDq2TNpe-FtGpSy4oJz7hWZUTWizxJQVx0C3nQ/exec'
