# URL Schemes

Control FineTune from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or any app that can open URLs. This makes it easy to automate volume changes, build keyboard shortcuts, or integrate FineTune into your workflow.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume | `finetune://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set volume (0–100, or up to 400 with boost) |
| Step volume | `finetune://step-volume?app=BUNDLE_ID&direction=up` | Nudge volume up or down by ~5% |
| Set mute | `finetune://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute an app |
| Toggle mute | `finetune://toggle-mute?app=BUNDLE_ID` | Toggle mute state |
| Set device | `finetune://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an app to a specific output |
| Reset | `finetune://reset` | Reset all apps to 100% and unmuted |
| Tape (debug) | `finetune://tape?app=BUNDLE_ID&...` | Drive an app's tape transport (see below) |

## Examples

```bash
# Set Spotify to 50% volume
open "finetune://set-volumes?app=com.spotify.client&volume=50"

# Set different volumes for different apps at once
open "finetune://set-volumes?app=com.spotify.client&volume=80&app=com.hnc.Discord&volume=40"

# Mute multiple apps at once
open "finetune://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"

# Step Discord volume down
open "finetune://step-volume?app=com.hnc.Discord&direction=down"

# Route an app to a specific device
open "finetune://set-device?app=com.spotify.client&device=YOUR_DEVICE_UID"

# Reset everything
open "finetune://reset"
```

## Use Cases

**Meeting mode** — Mute everything except your video call app:

```bash
open "finetune://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"
```

**Focus playlist** — Set music to a low background level and silence notifications:

```bash
open "finetune://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup** — Boost a game and lower Discord:

```bash
open "finetune://set-volumes?app=com.game.example&volume=400&app=com.hnc.Discord&volume=40"
```

These commands work in Terminal, shell scripts, Automator, Raycast script commands, macOS Shortcuts (using "Open URL"), and any other tool that can open URLs.

## Tape Transport (debug)

The tape records an app's audio into a ring buffer so you can rewind it, play it at
another speed, or save the last few minutes. It is off by default and records nothing
until you arm it: arming starts the recording from that moment, so there is no way to
save audio the tape was not already keeping.

This URL action is the interim control surface until the transport UI ships.

| Parameter | Values | What it does |
|-----------|--------|--------------|
| `app` | bundle ID | Required. Which app's tape. |
| `enable` | `true` / `false` | Arm or disarm the tape. |
| `rewind` | seconds | Play from N seconds behind live. |
| `rate` | `-4` … `4` | Tape speed; `0` stops. Pitch follows speed. |
| `ramp` | seconds | Optional ramp for that speed change (default `0.02`). |
| `live` | `1` | Return to live playback. |
| `export` | minutes | Save the last N minutes to `~/Music/FineTune/`. |
| `status` | `1` | Log the transport's state to Console. |

Parameters apply in that order. Arming allocates the ring in the background, so send
`enable=true` first and the playback commands afterwards, not in the same URL.

```bash
# Arm Spotify's tape (5 minutes of history by default, ~115 MB)
open "finetune://tape?app=com.spotify.client&enable=true"

# Jump back 10 seconds and listen to the past
open "finetune://tape?app=com.spotify.client&rewind=10"

# Half speed (pitch drops with it), then a slow brake to a stop
open "finetune://tape?app=com.spotify.client&rate=0.5"
open "finetune://tape?app=com.spotify.client&rate=0&ramp=0.8"

# Back to live
open "finetune://tape?app=com.spotify.client&live=1"

# Save the last minute, and check the transport's state
open "finetune://tape?app=com.spotify.client&export=1"
open "finetune://tape?app=com.spotify.client&status=1"
```

Watch the log output with:

```bash
log stream --predicate 'subsystem CONTAINS "FineTune" AND category == "URLHandler"' --info
```

## Finding Bundle IDs

App names shown in FineTune map to bundle IDs. Common ones:

| App | Bundle ID |
|-----|-----------|
| Spotify | `com.spotify.client` |
| Apple Music | `com.apple.Music` |
| Chrome | `com.google.Chrome` |
| Safari | `com.apple.Safari` |
| Discord | `com.hnc.Discord` |
| Slack | `com.tinyspeck.slackmacgap` |
| Zoom | `us.zoom.xos` |
| Firefox | `org.mozilla.firefox` |
| Arc | `company.thebrowser.Browser` |

To find any app's bundle ID:

```bash
osascript -e 'id of app "App Name"'
```

## Finding Device UIDs

In FineTune, click the pencil icon to enter edit mode, tap the **info button** on a device row to open the device inspector, then click the copy button next to the UID to put it on the clipboard.
