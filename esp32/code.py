# ON AIR sign for Adafruit MatrixPortal S3 + 64x32 HUB75 panel.
#
# State arrives by MQTT push from Adafruit IO, because the Mac and this board
# cannot reach each other on the LAN -- corporate WARP swallows the subnet.
# Both ends can reach the public internet, so io.adafruit.com is the relay.
#
# Camera live    -> red "On camera", with "ends <time>" if a meeting is on
# In a meeting   -> orange "in meeting" / "ends <time>", camera off
# Meeting ahead  -> grey start time above a blue "next meeting"
# Anything else  -> dim clock, US Central, never times out
#
# The clock is the resting state. It runs off the board's own monotonic
# counter, so it survives the Mac sleeping, the daemon stopping, and
# Adafruit IO being unreachable.

import json
import time
from os import getenv

import adafruit_connection_manager
import adafruit_minimqtt.adafruit_minimqtt as MQTT
import adafruit_ntp
import board
import displayio
import framebufferio
import rgbmatrix
import terminalio
import wifi
from adafruit_display_text.label import Label
from adafruit_io.adafruit_io import IO_MQTT

FEED = "onair"
BRIGHTNESS = 0.6

# No message for this long and the sign falls back to the clock.
STALE_AFTER = 90
# How often to re-check the clock against NTP.
RESYNC_EVERY = 3600

# The panel runs at bit_depth=4, so only the top nibble of each channel counts
# -- 16 levels, one step per 0x11. Everything sits low: the clock at level 4
# and the two alert states one step above it at level 5. Blue keeps its hue by
# scaling all three channels together (3:6:15 -> 1:2:5).
CLOCK_DIM = 0x444444   # level 4
RED = 0x550000         # level 5
ORANGE = 0x553300      # red at level 5, green held to 3 -- equal R and G
                       # reads green on these panels, so green is pulled down
GRAY = 0x555555        # level 5
BLUE = 0x112255        # level 5 on blue, hue preserved

# --- Panel ---------------------------------------------------------------

displayio.release_displays()

matrix = rgbmatrix.RGBMatrix(
    width=64,
    height=32,
    bit_depth=4,
    rgb_pins=[
        board.MTX_R1, board.MTX_G1, board.MTX_B1,
        board.MTX_R2, board.MTX_G2, board.MTX_B2,
    ],
    addr_pins=[board.MTX_ADDRA, board.MTX_ADDRB, board.MTX_ADDRC, board.MTX_ADDRD],
    clock_pin=board.MTX_CLK,
    latch_pin=board.MTX_LAT,
    output_enable_pin=board.MTX_OE,
)
display = framebufferio.FramebufferDisplay(matrix, auto_refresh=True)

try:
    display.brightness = BRIGHTNESS
except (AttributeError, NotImplementedError):
    pass

scene = displayio.Group()
display.root_group = scene


def row(y, color, scale=1):
    label = Label(terminalio.FONT, text="", color=color, scale=scale)
    label.anchor_point = (0.5, 0.5)
    label.anchored_position = (32, y)
    return label


# Camera and in-meeting states: two centred rows, recoloured per state.
# At 6px per character a 64px panel holds 10, which "in meeting" and
# "ends 2:30" both fit.
duo_group = displayio.Group()
duo_rows = [row(11, RED), row(22, RED)]
for label in duo_rows:
    duo_group.append(label)
scene.append(duo_group)


def show_duo(color, first, second):
    """One or two centred rows. A single line sits in the middle."""
    for label in duo_rows:
        label.color = color
    duo_rows[0].text = first
    duo_rows[1].text = second
    duo_rows[0].anchored_position = (32, 11 if second else 16)


meeting_group = displayio.Group()
clock_row = row(5, GRAY)
label_rows = [row(17, BLUE), row(27, BLUE)]
meeting_group.append(clock_row)
for label in label_rows:
    meeting_group.append(label)
scene.append(meeting_group)

# --- Clock face ----------------------------------------------------------

clock_group = displayio.Group()
clock_label = row(16, CLOCK_DIM)
clock_group.append(clock_label)
scene.append(clock_group)


# --- Time ----------------------------------------------------------------


def _epoch(y, mo, d, h=0, mi=0, s=0):
    """UTC epoch seconds for a civil date, independent of any platform tz."""
    yy = y - (1 if mo <= 2 else 0)
    era = (yy if yy >= 0 else yy - 399) // 400
    yoe = yy - era * 400
    doy = (153 * (mo + (-3 if mo > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s


def _nth_sunday(year, month, nth):
    wday = ((_epoch(year, month, 1) // 86400) + 4) % 7  # 0 = Sunday
    return 1 + ((7 - wday) % 7) + (nth - 1) * 7


def central_offset(epoch):
    """-5h in CDT, -6h in CST. Uses the US rules, so DST follows on its own."""
    year = time.localtime(int(epoch)).tm_year
    starts = _epoch(year, 3, _nth_sunday(year, 3, 2), 8)   # 2am CST
    ends = _epoch(year, 11, _nth_sunday(year, 11, 1), 7)   # 2am CDT
    return -5 * 3600 if starts <= epoch < ends else -6 * 3600


# CircuitPython floats are single precision, so an epoch near 1.8e9 quantises
# to ~128-second steps. Both anchors below are integers, and monotonic_ns
# returns an int, so the clock never touches a float.
epoch_at_sync = None
monotonic_at_sync = None
last_sync = None


def sync_clock():
    """Best effort. A failure just leaves the existing reading running."""
    global epoch_at_sync, monotonic_at_sync, last_sync
    try:
        ntp = adafruit_ntp.NTP(pool, tz_offset=0, cache_seconds=0)
        stamp = ntp.datetime
        epoch_at_sync = _epoch(
            stamp.tm_year, stamp.tm_mon, stamp.tm_mday,
            stamp.tm_hour, stamp.tm_min, stamp.tm_sec,
        )
        monotonic_at_sync = time.monotonic_ns()
        last_sync = time.monotonic()
        print("ntp synced:", epoch_at_sync)
    except Exception as error:  # noqa: BLE001 - keep the old base on failure
        print("ntp failed:", error)
        if last_sync is None:
            last_sync = time.monotonic() - RESYNC_EVERY + 30  # retry soon


def utc_now():
    if epoch_at_sync is None:
        return None
    elapsed = (time.monotonic_ns() - monotonic_at_sync) // 1000000000
    return epoch_at_sync + elapsed


def local_seconds():
    """Seconds since local midnight, or None before the first NTP sync."""
    utc = utc_now()
    return None if utc is None else (utc + central_offset(utc)) % 86400


def clock_text():
    seconds = local_seconds()
    if seconds is None:
        return "--:--"
    hour = (seconds // 3600) % 12 or 12
    return "%d:%02d" % (hour, (seconds % 3600) // 60)


# --- Rendering -----------------------------------------------------------

current = None


def render(mode, meeting=None):
    """Redraw only when something actually changed."""
    global current
    if mode == "clock":
        key = ("clock", clock_text())
    elif mode == "meeting":
        key = ("meeting", meeting["time"])
    elif mode in ("camera", "inmeeting"):
        key = (mode, (meeting or {}).get("until", ""))
    else:
        key = (mode, "")
    if key == current:
        return
    current = key

    duo_group.hidden = mode not in ("camera", "inmeeting")
    meeting_group.hidden = mode != "meeting"
    clock_group.hidden = mode != "clock"

    if mode == "clock":
        print("clock:", key[1])
        clock_label.text = key[1]
    elif mode == "meeting":
        clock_row.text = meeting["time"]
        label_rows[0].text = "next"
        label_rows[1].text = "meeting"
    elif mode == "camera":
        show_duo(RED, "On camera", "ends %s" % key[1] if key[1] else "")
    elif mode == "inmeeting":
        show_duo(ORANGE, "in meeting", "ends %s" % key[1] if key[1] else "")


def show_boot(message):
    """Startup progress, before any state is known."""
    global current
    current = None
    duo_group.hidden = True
    clock_group.hidden = True
    meeting_group.hidden = False
    clock_row.text = message
    label_rows[0].text = ""
    label_rows[1].text = ""


# --- Network -------------------------------------------------------------

show_boot("wifi..")

if not wifi.radio.connected:
    try:
        wifi.radio.connect(getenv("CIRCUITPY_WIFI_SSID"),
                           getenv("CIRCUITPY_WIFI_PASSWORD"))
    except Exception as error:  # noqa: BLE001 - the clock still needs to run
        print("wifi failed:", error)
print("wifi:", wifi.radio.ipv4_address)

pool = adafruit_connection_manager.get_radio_socketpool(wifi.radio)
ssl_context = adafruit_connection_manager.get_radio_ssl_context(wifi.radio)

show_boot("time..")
sync_clock()

show_boot("mqtt..")

mqtt_client = MQTT.MQTT(
    broker="io.adafruit.com",
    port=8883,
    username=getenv("ADAFRUIT_AIO_USERNAME"),
    password=getenv("ADAFRUIT_AIO_KEY"),
    socket_pool=pool,
    ssl_context=ssl_context,
    is_ssl=True,
)
io = IO_MQTT(mqtt_client)

live = False
active_meeting = None
next_meeting = None
last_message = -STALE_AFTER  # start on the clock, not on a stale meeting


def on_connect(client):
    print("mqtt connected")
    client.subscribe(FEED)
    # Ask for the retained last value so a reboot shows the truth immediately.
    client.get(FEED)


def on_message(client, feed_id, payload):
    global live, active_meeting, next_meeting, last_message
    try:
        state = json.loads(payload)
    except ValueError:
        print("bad payload:", payload)
        return
    live = bool(state.get("live"))
    active_meeting = state.get("active")
    next_meeting = state.get("next")
    last_message = time.monotonic()
    print("state:", "camera" if live else "idle",
          "until " + active_meeting["until"] if active_meeting
          else (next_meeting or {}).get("time", "clock"))


io.on_connect = on_connect
io.on_message = on_message

connected = False
backoff = 1
next_retry = 0

try:
    io.connect()
    connected = True
except Exception as error:  # noqa: BLE001 - the clock runs regardless
    print("initial connect failed:", error)
    next_retry = time.monotonic() + backoff

while True:
    if connected:
        try:
            # minimqtt requires this to be >= the socket timeout (1s).
            io.loop(timeout=1)
            backoff = 1
        except Exception as error:  # noqa: BLE001
            print("mqtt error:", error)
            connected = False
            next_retry = time.monotonic() + backoff
    elif time.monotonic() >= next_retry:
        try:
            io.reconnect()
            connected = True
            backoff = 1
        except Exception as error:  # noqa: BLE001
            print("reconnect failed:", error)
            backoff = min(backoff * 2, 60)
            next_retry = time.monotonic() + backoff

    if last_sync is None or time.monotonic() - last_sync > RESYNC_EVERY:
        sync_clock()

    age = time.monotonic() - last_message
    if age > STALE_AFTER:
        render("clock")          # the Mac has gone quiet
    elif live:
        render("camera", active_meeting)
    elif active_meeting:
        render("inmeeting", active_meeting)
    elif next_meeting:
        render("meeting", next_meeting)
    else:
        render("clock")

    if not connected:
        time.sleep(0.2)
