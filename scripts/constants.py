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
