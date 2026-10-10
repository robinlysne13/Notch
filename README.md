# Notch

A macOS menu-bar companion that lives in the MacBook notch. Hover it to expand. It shows Now
Playing with lyrics, surfaces verification codes from your inbox, and holds a drop shelf for files.

## Build and install

Requires macOS 14 or later and Xcode's Swift toolchain.

```
./run.sh
```

This builds the package in release mode, wraps the binary in `Notch.app`, signs it, and launches
it. Copy `Notch.app` to `/Applications` to keep it.

By default the bundle is ad-hoc signed. Set `CODESIGN_IDENTITY` to a certificate name from
`security find-identity -v -p codesigning` to sign with it instead, so macOS treats each rebuild
as the same app for Automation and Local Network permissions:

```
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./run.sh
```

## Now Playing sources

Notch polls every enabled source every two seconds and shows whichever one is playing. If nothing
is playing anywhere, it shows a paused source. Play, pause, skip and scrubbing go to the source
being shown. The caption under the artist names it.

| Source | What it covers | Setup |
| --- | --- | --- |
| Spotify account | Anything the account plays on any device: Sonos, phone, desktop | Connect in Settings (below) |
| Sonos | Music started from the Sonos app on any speaker on your network | Switch on in Settings |
| Local app | The Spotify or Music app on this Mac, via AppleScript | Allow the Automation prompt |

### Spotify account

Spotify's Web API only hands out tokens to a registered app, so you create one once:

1. Open the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and click
   **Create app**. Any name and description.
2. Under **Redirect URIs** add exactly `http://127.0.0.1:47391/callback` and click Add. Tick
   **Web API**. Save.
3. Copy the app's **Client ID** from its settings page.
4. Right-click the notch, choose **Settings…**, paste the Client ID, and click **Connect Spotify**.
   Your browser opens Spotify's consent page; approve it.

The sign-in uses Authorization Code with PKCE, so there is no client secret. Notch opens the
consent page in your default browser and catches the redirect on a short-lived listener bound to
127.0.0.1. Only a refresh token is kept, in an owner-only file under
`~/Library/Application Support/Notch/`. It is not placed in the Keychain because the Keychain
re-prompts for your login password every time a side-loaded binary changes.

Reading what is playing works on any account. Play, pause, skip and seek through the API require
Spotify Premium; Spotify answers 403 otherwise and Settings shows the reason.

Spotify Connect sessions on a Sonos speaker show up through this source. Music started from the
Sonos app does not, because the speaker streams Spotify directly and the account never sees it.
That is what the Sonos source is for.

### Sonos

Notch finds speakers with one SSDP search, then reads the zone-group topology from the first
speaker that answers. Only group coordinators are polled, since the other members of a group or
stereo pair carry no transport state. Transport commands go to the coordinator of the group being
shown.

macOS asks once whether Notch may find devices on the local network. If you decline, enable it
under System Settings › Privacy & Security › Local Network. Settings lists the groups found and
has a Scan Again button. The Sonos source is off until you switch it on there.

Home-theatre inputs and Spotify Connect sessions are skipped by this source, since Sonos exposes
no track metadata for them over polling.

**Grouping.** While a Sonos group is what's showing, a two-speaker button sits above the
skip-forward button. It opens a checklist of every room. Ticking a room joins it to the playing
group; unticking splits it off. The room doing the streaming stays ticked.

## Lyrics

Time-synced lyrics come from [LRCLIB](https://lrclib.net), a keyless community API, requested per
track. Toggle the panel with the note button above play.

## Verification codes

Settings takes an iCloud or Gmail address with an app-specific password. Notch reads the inbox
over IMAP, extracts verification codes from new mail, and shows them in the Codes tab, optionally
copying each new one to the clipboard. Passwords are stored in the Keychain.

## Diagnostics

Source selection, Spotify sign-in, Sonos topology and command failures are written to the unified
log under one subsystem:

```
/usr/bin/log show --last 5m --predicate 'subsystem == "com.robin.notch"' --style compact
```

Each change in what the notch shows is logged, so a "Nothing playing" is explained there.
