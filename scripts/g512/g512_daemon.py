#!/usr/bin/env python3

import colorsys
import glob
import json
import math
import os
import time

from openrgb import OpenRGBClient
from openrgb.utils import RGBColor


BASE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = f"{BASE}/g512_state.json"


# ============================================================
# STATE
# ============================================================

DEFAULT_STATE = {
    "preset": "1",
    "speed": 1.0,
}


def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            data = json.load(f)

        preset = str(data.get("preset", "1"))
        speed = float(data.get("speed", 1.0))

        if preset not in "0123456789":
            preset = "1"

        speed = max(0.15, min(6.0, speed))

        return preset, speed

    except Exception:
        return "1", 1.0


if not os.path.exists(STATE_FILE):
    with open(STATE_FILE, "w") as f:
        json.dump(DEFAULT_STATE, f)



# ============================================================
# NUM LOCK REAL DO SISTEMA
# ============================================================

NUMLOCK_FILES = glob.glob(
    "/sys/class/leds/*::numlock/brightness"
)

CAPSLOCK_FILES = glob.glob(
    "/sys/class/leds/*::capslock/brightness"
)

SCROLLLOCK_FILES = glob.glob(
    "/sys/class/leds/*::scrolllock/brightness"
)

def numlock_is_on():
    """
    Lê o estado REAL do Num Lock no Linux.
    Retorna True quando ligado.
    """
    for path in NUMLOCK_FILES:
        try:
            with open(path, "r") as f:
                if int(f.read().strip()) > 0:
                    return True
        except Exception:
            pass

    return False


def capslock_is_on():
    """
    Lê o estado REAL do Caps Lock no Linux.
    """
    for path in CAPSLOCK_FILES:
        try:
            with open(path, "r") as f:
                if int(f.read().strip()) > 0:
                    return True
        except Exception:
            pass

    return False


def scrolllock_is_on():
    """
    Lê o estado REAL do Scroll Lock no Linux.
    """
    for path in SCROLLLOCK_FILES:
        try:
            with open(path, "r") as f:
                if int(f.read().strip()) > 0:
                    return True
        except Exception:
            pass

    return False


def apply_numlock_status(colors):
    """
    Aplica uma indicação universal por cima de QUALQUER preset.

    LIGADO:
        verde extremamente forte

    DESLIGADO:
        verde escuro/fraco

    Afeta:
        - tecla Num Lock
        - LED indicador Num Lock
    """

    if numlock_is_on():
        color = rgb(0, 255, 60)
    else:
        color = rgb(0, 45, 10)

    key(colors, "Num Lock", color)
    raw(colors, "Num Lock Indicator", color)

    return colors


def apply_capslock_status(colors):
    """
    CAPS LOCK GLOBAL EM TODOS OS PRESETS.

    Ligado:
        tecla Caps Lock forte
        LED Caps Lock igual à tecla

    Desligado:
        mesma cor, brilho reduzido
    """

    if capslock_is_on():
        color = rgb(255, 170, 0)
    else:
        color = rgb(70, 45, 0)

    key(colors, "Caps Lock", color)
    raw(colors, "Caps Lock Indicator", color)

    return colors


# ============================================================
# OPENRGB
# ============================================================

while True:
    try:
        client = OpenRGBClient()

        keyboard = next(
            (d for d in client.devices if "G512" in d.name),
            None
        )

        if keyboard is not None:
            break

    except Exception:
        pass

    time.sleep(2)


keyboard.set_mode("Direct")

LEDS = {
    led.name: i
    for i, led in enumerate(keyboard.leds)
}

N = len(keyboard.leds)


# ============================================================
# HELPERS
# ============================================================


def apply_scrolllock_status(colors):
    """
    SCROLL LOCK SEGUE O PRESET.

    ON:
        mesma tonalidade do preset, levada ao brilho máximo.

    OFF:
        mesma tonalidade do preset, brilho reduzido.

    Indicador = exatamente a mesma cor da tecla.
    """

    i = idx("Scroll Lock")

    if i is None:
        return colors

    original = colors[i]

    r = original.red
    g = original.green
    b = original.blue

    if scrolllock_is_on():
        peak = max(r, g, b, 1)
        factor = 255.0 / peak

        color = rgb(
            r * factor,
            g * factor,
            b * factor
        )
    else:
        color = rgb(
            max(8, r * 0.28),
            max(8, g * 0.28),
            max(8, b * 0.28)
        )

    key(colors, "Scroll Lock", color)
    raw(colors, "Scroll Lock Indicator", color)

    return colors

def rgb(r, g, b):
    return RGBColor(
        max(0, min(255, int(r))),
        max(0, min(255, int(g))),
        max(0, min(255, int(b))),
    )


def hsv(h, s=1.0, v=1.0):
    r, g, b = colorsys.hsv_to_rgb(
        h % 1.0,
        s,
        v
    )

    return rgb(
        r * 255,
        g * 255,
        b * 255
    )


def idx(name):
    return LEDS.get(f"Key: {name}")


def ridx(name):
    return LEDS.get(name)


def key(c, name, color):
    i = idx(name)

    if i is not None:
        c[i] = color


def keys(c, names, color):
    for name in names:
        key(c, name, color)


def raw(c, name, color):
    i = ridx(name)

    if i is not None:
        c[i] = color


def fill(color):
    return [
        color
        for _ in range(N)
    ]


# ============================================================
# GRUPOS
# ============================================================

LETTERS = list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

TOP_NUMBERS = list("1234567890")

NUMPAD_NUMBERS = [
    "Number Pad 1",
    "Number Pad 2",
    "Number Pad 3",
    "Number Pad 4",
    "Number Pad 5",
    "Number Pad 6",
    "Number Pad 7",
    "Number Pad 8",
    "Number Pad 9",
    "Number Pad 0",
]

NUMPAD_OPS = [
    "Number Pad /",
    "Number Pad *",
    "Number Pad -",
    "Number Pad +",
    "Number Pad .",
]

NUMBERS = (
    TOP_NUMBERS +
    NUMPAD_NUMBERS +
    NUMPAD_OPS +
    ["Num Lock"]
)

FUNCTIONS = [
    f"F{i}"
    for i in range(1, 13)
]

FUNCTIONS_NORMAL = [
    f"F{i}"
    for i in range(1, 9)
]

FUNCTIONS_MEDIA = [
    "F9",
    "F10",
    "F11",
    "F12",
]

# O G512 não expõe "Key: Fn" no mapa do OpenRGB.
# No layout atual usamos o LED fisicamente correspondente
# ao Right Windows como FN.
FN_LED = "Menu"

NAV = [
    "Insert",
    "Home",
    "Page Up",
    "Delete",
    "End",
    "Page Down",
    "Left Arrow",
    "Right Arrow",
    "Up Arrow",
    "Down Arrow",
]

MODS = [
    "Backspace",
    "Tab",
    "Space",
    "Caps Lock",
    "Left Control",
    "Left Shift",
    "Left Alt",
    "Left Windows",
    "Right Control",
    "Right Shift",
    "Right Alt",
    "Right Windows",
    "Menu",
]

SYMBOLS = [
    "-",
    "=",
    "[",
    "]",
    "\\ (ANSI)",
    "\\ (ISO)",
    "#",
    ";",
    "'",
    "`",
    ",",
    ".",
    "/",
]

MEDIA = [
    "Print Screen",
    "Scroll Lock",
    "Pause/Break",
    "Media Next",
    "Media Previous",
    "Media Stop",
    "Media Play/Pause",
    "Media Mute",
]


def indicators(c, color):
    for name in [
        "Logo Lighting",
        "Game Mode",
        "Caps Lock Indicator",
        "Scroll Lock Indicator",
    ]:
        raw(c, name, color)


def num_indicator(c, color):
    raw(
        c,
        "Num Lock Indicator",
        color
    )



def preset_0(t, speed):
    c = fill(rgb(20, 70, 180))

    keys(c, LETTERS, rgb(30, 150, 255))
    keys(c, NUMBERS, rgb(0, 255, 255))
    keys(c, FUNCTIONS, rgb(190, 70, 255))
    keys(c, NAV, rgb(80, 230, 255))
    keys(c, MODS, rgb(130, 180, 255))
    keys(c, SYMBOLS, rgb(40, 190, 255))
    keys(c, MEDIA, rgb(255, 70, 230))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 100))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    indicators(c, rgb(30, 150, 255))
    num_indicator(c, rgb(0, 255, 255))

    return c


# ============================================================
# 1 - SEU PRESET
# ============================================================

def preset_1(t, speed):
    c = fill(rgb(15, 80, 190))

    keys(c, LETTERS, rgb(0, 100, 255))
    keys(c, SYMBOLS, rgb(0, 170, 255))
    keys(c, FUNCTIONS, rgb(180, 30, 255))
    keys(c, NAV, rgb(0, 245, 255))
    keys(c, MODS, rgb(210, 230, 255))
    keys(c, MEDIA, rgb(255, 30, 170))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 80))

    # Enter numérico piscando
    p = (
        math.sin(t * speed * 5.0) + 1
    ) / 2

    key(
        c,
        "Number Pad Enter",
        rgb(
            100 + 155 * p,
            100 + 155 * p,
            100 + 155 * p
        )
    )

    # números quentes sincronizados
    phase = (
        math.sin(t * speed * 0.45) + 1
    ) / 2

    warm = hsv(
        phase * 0.145,
        1.0,
        1.0
    )

    keys(c, NUMBERS, warm)
    num_indicator(c, warm)

    indicators(c, rgb(0, 100, 255))

    return c


# ============================================================
# 2 - CYBER
# ============================================================

def preset_2(t, speed):
    c = fill(rgb(100, 20, 150))

    keys(c, LETTERS, rgb(0, 255, 255))
    keys(c, NUMBERS, rgb(255, 30, 180))
    keys(c, FUNCTIONS, rgb(190, 60, 255))
    keys(c, NAV, rgb(50, 220, 255))
    keys(c, MODS, rgb(180, 100, 240))
    keys(c, SYMBOLS, rgb(30, 220, 255))
    keys(c, MEDIA, rgb(255, 100, 210))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 220))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    return c


# ============================================================
# 3 - MATRIX
# ============================================================

def preset_3(t, speed):
    c = fill(rgb(20, 130, 40))

    pulse = 200 + 55 * (
        (
            math.sin(t * speed * 1.2) + 1
        ) / 2
    )

    keys(
        c,
        LETTERS,
        rgb(20, pulse, 60)
    )

    keys(c, NUMBERS, rgb(190, 255, 40))
    keys(c, FUNCTIONS, rgb(20, 230, 80))
    keys(c, NAV, rgb(80, 255, 150))
    keys(c, MODS, rgb(80, 190, 100))
    keys(c, SYMBOLS, rgb(50, 240, 100))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(255, 255, 255))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    return c


# ============================================================
# 4 - ICE
# ============================================================

def preset_4(t, speed):
    c = fill(rgb(70, 150, 230))

    keys(c, LETTERS, rgb(150, 235, 255))
    keys(c, NUMBERS, rgb(255, 255, 255))
    keys(c, FUNCTIONS, rgb(40, 210, 255))
    keys(c, NAV, rgb(60, 130, 255))
    keys(c, MODS, rgb(150, 200, 255))
    keys(c, SYMBOLS, rgb(100, 220, 255))

    key(c, "Escape", rgb(255, 40, 40))
    key(c, "Enter", rgb(0, 255, 255))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    return c


# ============================================================
# 5 - RGB WAVE
# ============================================================

def preset_5(t, speed):
    c = []

    for i in range(N):
        hue = (
            i / max(1, N) +
            t * speed * 0.06
        ) % 1.0

        c.append(
            hsv(hue, 0.85, 1.0)
        )

    # letras SEMPRE uma única cor
    lc = hsv(
        (t * speed * 0.06) % 1.0,
        0.8,
        1.0
    )

    keys(c, LETTERS, lc)

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 100))

    return c


# ============================================================
# 6 - WARM WAVE
# ============================================================

def preset_6(t, speed):
    c = []

    for i in range(N):
        phase = (
            i / max(1, N) * 0.5 +
            t * speed * 0.08
        )

        x = (
            math.sin(
                phase * math.pi * 2
            ) + 1
        ) / 2

        c.append(
            hsv(
                x * 0.14,
                1.0,
                1.0
            )
        )

    x = (
        math.sin(t * speed * 0.6) + 1
    ) / 2

    keys(
        c,
        LETTERS,
        hsv(x * 0.14, 1, 1)
    )

    key(c, "Escape", rgb(255, 255, 255))
    key(c, "Enter", rgb(0, 255, 100))

    return c


# ============================================================
# 7 - OCEAN WAVE
# ============================================================

def preset_7(t, speed):
    c = []

    for i in range(N):
        phase = (
            i / max(1, N) +
            t * speed * 0.05
        ) % 1.0

        c.append(
            hsv(
                0.48 + phase * 0.18,
                0.85,
                1.0
            )
        )

    hue = (
        0.48 +
        (
            (t * speed * 0.05) % 1.0
        ) * 0.18
    )

    keys(
        c,
        LETTERS,
        hsv(hue, 0.8, 1)
    )

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 130))

    return c


# ============================================================
# 8 - PURPLE WAVE
# ============================================================

def preset_8(t, speed):
    c = []

    for i in range(N):
        phase = (
            i / max(1, N) +
            t * speed * 0.055
        )

        x = (
            math.sin(
                phase * math.pi * 2
            ) + 1
        ) / 2

        c.append(
            hsv(
                0.75 + x * 0.18,
                0.85,
                1.0
            )
        )

    x = (
        math.sin(t * speed * 0.5) + 1
    ) / 2

    keys(
        c,
        LETTERS,
        hsv(
            0.75 + x * 0.18,
            0.80,
            1.0
        )
    )

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 255))

    return c


# ============================================================
# 9 - SUPER RGB
# ============================================================

def preset_9(t, speed):
    c = []

    for i in range(N):
        hue = (
            i / max(1, N) +
            t * speed * 0.10
        ) % 1.0

        c.append(
            hsv(hue, 1.0, 1.0)
        )

    letter_color = hsv(
        (
            t * speed * 0.10 +
            0.15
        ) % 1.0,
        0.75,
        1.0
    )

    keys(
        c,
        LETTERS,
        letter_color
    )

    fc = hsv(
        (
            t * speed * 0.10 +
            0.45
        ) % 1.0,
        1,
        1
    )

    keys(c, FUNCTIONS, fc)

    nc = hsv(
        (
            t * speed * 0.10 +
            0.70
        ) % 1.0,
        1,
        1
    )

    keys(c, NUMBERS, nc)
    num_indicator(c, nc)

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 100))

    p = (
        math.sin(t * speed * 5) + 1
    ) / 2

    key(
        c,
        "Number Pad Enter",
        rgb(
            120 + 135 * p,
            120 + 135 * p,
            255
        )
    )

    return c


PRESETS = {
    "0": preset_0,
    "1": preset_1,
    "2": preset_2,
    "3": preset_3,
    "4": preset_4,
    "5": preset_5,
    "6": preset_6,
    "7": preset_7,
    "8": preset_8,
    "9": preset_9,
}


# ============================================================
# DAEMON LOOP
# ============================================================

start = time.monotonic()

last_preset = None

while True:

    preset, speed = load_state()

    if preset != last_preset:
        start = time.monotonic()
        last_preset = preset

    t = time.monotonic() - start

    try:
        colors = PRESETS[preset](t, speed)

        # Caps Lock segue o preset
        colors = apply_capslock_status(colors)

        # Scroll Lock segue o preset
        colors = apply_scrolllock_status(colors)

        # Num Lock é vermelho global
        colors = apply_numlock_status(colors)

        keyboard.set_colors(colors)

    except Exception:
        # tenta reconectar ao OpenRGB
        try:
            client = OpenRGBClient()

            keyboard = next(
                (
                    d
                    for d in client.devices
                    if "G512" in d.name
                ),
                keyboard
            )

            keyboard.set_mode("Direct")

        except Exception:
            time.sleep(1)

    time.sleep(0.05)
