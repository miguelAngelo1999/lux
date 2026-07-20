#!/usr/bin/osascript
-- ============================================================
-- Lux Installation Helper — Launcher
-- ============================================================
-- Uses /usr/bin/osascript as interpreter so this works
-- regardless of the user's default shell (bash, zsh, fish…).
--
-- Background: Terminal.app has a confirmed bug where .command
-- files silently fail when "Shells open with" is set to a
-- non-standard shell path. The shebang is never reached —
-- Terminal just opens the shell and does nothing.
-- osascript bypasses Terminal's shell preference entirely.
--
-- This script opens a new Terminal window and runs the
-- installer bash script (lux_install.sh) located alongside
-- this file in the same folder (the DMG volume).
-- ============================================================

set selfDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
set installerScript to selfDir & "/lux_install.sh"

-- Verify the installer script exists alongside this launcher
set checkResult to do shell script "test -f " & quoted form of installerScript & " && echo yes || echo no"
if checkResult is not "yes" then
	display dialog "Could not find lux_install.sh next to this file." & return & return & "Make sure both files are in the same folder." buttons {"OK"} default button "OK" with icon stop
	return
end if

tell application "Terminal"
	activate
	do script "/bin/bash " & quoted form of installerScript
end tell
