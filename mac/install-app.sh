#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/Model Picker.app"
LA="$HOME/Library/LaunchAgents/com.tara.modelpicker.proxy.plist"
LABEL=com.tara.modelpicker.proxy
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ModelPicker"
launchctl bootout gui/$(id -u)/$LABEL >/dev/null 2>&1 || true
osascript -e 'quit app "Model Picker"' >/dev/null 2>&1 || true; sleep 1; pkill -f "Applications/Model Picker.app/Contents/MacOS" >/dev/null 2>&1 || true
rm -rf "$APP/Contents/Resources/web"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/ModelPicker"
cp -R ../web/* "$APP/Contents/Resources/web/"
P="$APP/Contents/Info.plist"; cp Resources/Info.plist "$P"
pb(){ /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$P"; }
pb CFBundleExecutable ModelPicker; pb CFBundleIdentifier com.tara.modelpicker; pb CFBundlePackageType APPL
pb NSCalendarsFullAccessUsageDescription "Model Picker reads your calendar to answer schedule questions, and adds an event only after you press Approve."
pb NSRemindersFullAccessUsageDescription "Model Picker lists your open reminders when you ask. It never changes them."
pb NSRemindersUsageDescription "Model Picker lists your open reminders when you ask."
pb NSMicrophoneUsageDescription "Model Picker uses the microphone for hold-to-talk. Audio stays on this Mac."
pb NSSpeechRecognitionUsageDescription "Model Picker turns your speech into text on this Mac. Recognition stays on device."
pb NSAppleEventsUsageDescription "Model Picker controls Pages only when you ask it to make a document for you."
pb NSCalendarsUsageDescription "Model Picker reads your calendar only when you ask about your schedule."
codesign --force --deep -s - -r="designated => identifier \"com.tara.modelpicker\"" "$APP"  # stable identity: macOS keeps permissions across updates
# Background helper: keeps the fixed address http://127.0.0.1:7777/v1 alive after login, even with the window closed.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$LA" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ModelPicker</string><string>--proxy</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>20</integer>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/ModelPickerProxy.log</string>
<key>StandardOutPath</key><string>$HOME/Library/Logs/ModelPickerProxy.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$LA"
echo "Installed: $APP  (proxy LaunchAgent: $LA)"
