# onair-sign

An LED panel that turns red the moment any app touches your Mac's camera, so
the people you live with know not to walk into a meeting. It goes orange when
you're in a call with the camera off, shows the start time of your next Google
Meet when you're free, and otherwise a dim clock.

```
   camera live        in a call, camera off      call ahead        everything else
 ┌──────────────┐      ┌──────────────┐      ┌──────────────┐    ┌──────────────┐
 │  On camera   │      │  in meeting  │      │   10:30 AM   │    │              │
 │  ends 11:30  │      │  ends 11:30  │      │     next     │    │     2:47     │
 │              │      │              │      │   meeting    │    │              │
 └──────────────┘      └──────────────┘      └──────────────┘    └──────────────┘
       red                  orange              grey + blue          dim grey
```

Roughly $60 in parts, no soldering, an evening's work.

---

## Hardware

| Part | Note | USD |
|---|---|---:|
| [Adafruit MatrixPortal S3](https://www.adafruit.com/product/5778) | ESP32-S3, presses straight onto the panel | 19.95 |
| [64×32 RGB matrix, 4mm pitch](https://www.adafruit.com/product/2278) | 255 × 127 mm. Ribbon and power lead included | 39.95 |
| USB-C supply | Whatever you own — see [Power](#power) | — |

A HUB75 matrix is a dumb display: no framebuffer, no controller. You feed it
one row at a time and refresh the whole panel hundreds of times a second or it
visibly flickers. The MatrixPortal earns its price because the ESP32-S3 has a
hardware parallel peripheral, so the refresh runs off-CPU via DMA instead of
bit-banging.

Assembly:

1. Peel the tape off the two threaded standoffs.
2. Panel's power harness → spade lugs onto `+5V` and `GND`.
3. MatrixPortal → press onto the 8×2 shrouded connector.
4. USB-C in. The board ships with a demo, so you see it work before writing
   any code.

The Address E jumper only applies to 64×64 panels.

### Power

Adafruit rates the panel at up to 4 A and warns against running it from USB.
That's accurate for a panel driven at full white, and it's why most guides
tell you to buy a 5 V 4 A brick and wire it to the standoffs.

It's also far more than this needs. Every state here runs at level 4 or 5 of
16, on one or two colour channels, lighting a fraction of the pixels. **USB-C
carries it comfortably.** I bought the 4 A supply and never wired it up.

The rule is brightness, not panel size. If you raise `BRIGHTNESS` or the
colour constants and the panel starts to flicker, show wrong colours, or
reboot the ESP32 — that's an under-powered panel, not a WiFi fault. Add the
supply then.

---

## Architecture

```
Mac                          relay                    sign
┌────────────────────┐      ┌──────────────┐      ┌──────────────────┐
│ Swift daemon       │      │ Adafruit IO  │      │ MatrixPortal S3  │
│ launchd, KeepAlive │─────▶│ feed "onair" │─────▶│ CircuitPython    │
│                    │ HTTPS│              │ MQTT │                  │
│ CoreMediaIO   1 s  │      └──────────────┘      │ 64×32 HUB75      │
│ Calendar API 60 s  │                            └──────────────────┘
└────────────────────┘
```

The daemon publishes on every state change plus a 30-second heartbeat — about
two data points a minute against Adafruit IO's free-tier budget of thirty.
The heartbeat is what lets the sign tell "camera is off" apart from "the Mac
has gone away".

Payload is one JSON string. **Meeting titles are never published** — the
daemon resolves them, logs them locally, and sends only times. `active` is the
meeting under way and when it ends; `next` is the one still to come:

```json
{"live": false, "cameras": [], "active": {"until": "11:30"}, "next": {"time": "10:30 AM"}}
```

Google's `timeMin` filters on an event's *end*, so a meeting already in
progress comes back from the same query as the upcoming ones — no second
request needed.

---

## Setup

### The board

1. Double-tap reset. A `MATRIXS3BOOT` drive appears. Drag on the MatrixPortal
   S3 `.uf2` from [circuitpython.org](https://circuitpython.org/board/adafruit_matrixportal_s3/).
   It reboots as `CIRCUITPY`. **Note the major version** — the library bundle
   must match it.

2. Install libraries. With the board mounted:

   ```bash
   pipx install circup
   circup install adafruit_minimqtt adafruit_io adafruit_display_text \
                  adafruit_connection_manager adafruit_ticks adafruit_ntp
   ```

   Or copy them by hand from the matching `-mpy-` bundle at
   [circuitpython.org/libraries](https://circuitpython.org/libraries).

3. Copy `esp32/code.py` to the drive root, and `esp32/settings.toml.example`
   to `settings.toml` with your values filled in.

   The ESP32-S3 has **no 5 GHz radio**. Check your SSID actually carries a
   2.4 GHz band before you order anything — a band-steered network can look
   fine right up until it doesn't.

### Adafruit IO

Sign up, then **create a feed named `onair`**. Posting data to a feed that
doesn't exist returns 404 rather than creating it.

Grab your username and key from *My Key*.

### Google Calendar

An API key will not work — keys only authorize public data. Any number of
accounts is supported; each keeps its own refresh token and the sign shows
whichever meeting comes first across all of them.

Two settings decide whether this works at all:

- **External, not Internal.** An Internal consent screen only authorizes
  accounts inside its own Workspace org, so it can't cover several domains.
- **In production, not Testing.** An External app left in *Testing* issues
  refresh tokens that **expire after 7 days**. The app stays unverified, which
  costs one warning screen during consent and nothing after.

Then:

1. [Cloud Console](https://console.cloud.google.com/) → new project.
2. APIs & Services → Library → enable **Google Calendar API**.
3. OAuth consent screen → **External**, scope `.../auth/calendar.readonly`,
   add each address as a test user.
4. **Publish app** → confirm it reads *In production*.
5. Credentials → OAuth client ID → **Desktop app**. Not *Web application*;
   desktop clients accept a loopback redirect on any port, which is what the
   consent flow uses.

### The Mac daemon

```bash
cd mac
./build.sh
./onair --auth you@example.com     # once per Google account
./onair --aio <username> <key>     # Adafruit IO
./onair --accounts                 # check what stuck

# edit the paths in com.example.onair.plist first
cp com.example.onair.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.example.onair.plist
tail -f ~/Library/Logs/onair.log
```

Credentials land in `~/.config/onair/credentials.json` at mode 0600, the same
way `gcloud` and `gh` store theirs.

If a Workspace blocks unverified third-party apps, answer `n` at *"Use it for
this account?"* and supply a client created inside that Workspace. It's stored
against that one account; the rest keep using the shared client.

### Configuration

| Variable | Default | Meaning |
|---|---|---|
| `ONAIR_FEED` | `onair` | Adafruit IO feed name |
| `ONAIR_EXCLUDE` | `OBS Virtual Camera` | comma-separated devices to ignore |

Firmware constants live at the top of `esp32/code.py`: `BRIGHTNESS`,
`STALE_AFTER`, `RESYNC_EVERY`, and the colours. Everything sits at level 5 of
16 except the clock at level 4, so the panel stays glanceable rather than
glaring.

---

## How camera detection works

macOS exposes every camera — built-in, USB, Continuity, and virtual devices
like OBS — as a CoreMediaIO object carrying
`kCMIODevicePropertyDeviceIsRunningSomewhere`, true whenever any process is
pulling frames. Enumerate devices, read the flag, OR the results.

```swift
func isStreaming(_ device: CMIOObjectID) -> Bool {
    var addr = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(device, &addr, 0, nil,
        UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0 else { return false }
    return value != 0
}
```

**No TCC permission is required.** You read device metadata and never open an
`AVCaptureSession`, so nothing appears under Privacy & Security and the daemon
works from `launchd` on first launch.

Measured: about **1.6 s** from opening Photo Booth to the panel turning red,
**0.6 s** to clear. Most of that is app startup, not the poll.

Device names come from `kCMIOObjectPropertyName` on the same objects, which is
how `ONAIR_EXCLUDE` works — an OBS Virtual Camera left running would otherwise
pin the sign to *On camera* all day.

---

## What I learned

The parts are easy. These cost the actual time.

### 1. `lsof` lies about who is using the camera

```
lsof | grep VDC  →  Safari, Brave, Slack, Claude, Granola, Spark
```

Every popular snippet greps `lsof` for the CoreMediaIO plugin. On my machine
that named six apps, none of which were using the camera — they merely had the
plugin memory-mapped (`txt`). Use the CoreMediaIO property instead.

### 2. The log-scraping recipes are dead

Older projects parse `log stream` for camera events. On current macOS,
`AVFCapture` messages returned nothing over 48 hours, and every identifying
field in the `com.apple.cmio` subsystem is `<private>`. Un-redacting needs a
configuration profile.

There is also **no supported API for which app holds the camera**. Treat any
project claiming per-app attribution with suspicion — the honest ones admit
they're guessing from the frontmost app.

### 3. A VPN can swallow your LAN

```
route -n get 192.168.x.x   →   interface: utun0
```

Mac and board sat on the same subnet and couldn't reach each other in either
direction. Cloudflare WARP ran in Exclude mode with **no RFC1918 range** among
its entries, so local traffic routed into the tunnel and died. Always-On and
Switch-Locked, so it can't simply be turned off.

The tell is a `100.64.0.0/10` (CGNAT) source address in a failed `curl`. Fix
is to relay through something public, which is why this talks to Adafruit IO
rather than the LAN.

### 4. CircuitPython floats are single precision

```
clock read 6:29 while the Mac read 6:20
```

A Unix epoch is ~1.8×10⁹, needing ten significant digits. float32 gives about
seven, so representable values up there are ~128 seconds apart. Holding the
epoch in a float put the clock nine minutes fast. Keep both time anchors as
integers and take the elapsed term from `time.monotonic_ns()`.

### 5. DST without `zoneinfo`

CircuitPython has no timezone database. US Central is computed from the rules
directly — second Sunday in March to first Sunday in November — using a
`days_from_civil` epoch helper so it doesn't depend on platform `mktime`
semantics. Verified against CPython's standard library at both transition
boundaries to the minute, across several years.

### 6. Two Google OAuth settings decide everything

Covered under [Setup](#google-calendar). The Testing-status trap is the nasty
one: it fails silently a week after you stop paying attention.

### 7. Ten characters, and not one more

`terminalio.FONT` is 6 px wide, so a 64 px panel holds exactly ten characters.
Write the copy to that budget before you fall in love with it: `until 11:30`
is eleven and clipped a pixel off each edge, while `ends 11:30` fits exactly.
Text bigger than `scale=1` means hand-building a glyph set, which is real work
for a handful of characters.

### 8. Equal red and green is not yellow

Green LEDs are far more luminous per unit drive than red, so `0x555500` does
not read as yellow — it reads as green with a faint warm cast. A convincing
orange needed red at level 5 against green at 3. Do not reason about these
panels in sRGB; put candidates side by side on the hardware and pick by eye.

### 9. Not every meeting is a Google Meet

The obvious filter is `hangoutLink`, which only exists for Meet. Zoom, Teams
and Webex all come back empty, so real meetings silently vanish from the sign.
Use `conferenceData.entryPoints` and look for an `entryPointType` of `video`;
Google populates it for anything added through a calendar add-on.

Fall back to scanning location and body only for invites that just paste a
URL, and match join-link *paths*. Bare `zoom.us` also fires on `docs.zoom.us`
and `applications.zoom.us`.

### 10. Build the staleness fallback first

If the Mac sleeps mid-meeting and the sign has no timeout, it stays lit on ON
AIR indefinitely — worse than having no sign, because people stop trusting it.
This one falls back to the clock after 90 seconds of silence, and the clock
runs off the board's own counter so it survives the network going away.

---

## Layout

```
mac/
  main.swift                camera polling, state machine, publishing, CLI
  calendar.swift            OAuth 2.0 + PKCE, loopback catcher, Calendar API
  Info.plist                bundle identity, embedded via linker
  build.sh
  com.example.onair.plist   launchd agent — edit the paths
esp32/
  code.py                   firmware: display, MQTT, NTP, DST
  settings.toml.example
docs/
  steal-this.html           one-page writeup
```

## License

MIT. See [LICENSE](LICENSE).
