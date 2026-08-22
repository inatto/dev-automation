#!/usr/bin/env python3

import colorsys
import math
import os
import select
import sys
import termios
import time
import tty

from openrgb import OpenRGBClient
from openrgb.utils import RGBColor


# ============================================================
# OPENRGB
# ============================================================

client = OpenRGBClient()

keyboard = next(
    (d for d in client.devices if "G512" in d.name),
    None
)

if keyboard is None:
    raise SystemExit("ERRO: Logitech G512 não encontrado.")

keyboard.set_mode("Direct")

LEDS = {led.name: i for i, led in enumerate(keyboard.leds)}
N = len(keyboard.leds)


# ============================================================
# HELPERS
# ============================================================

def rgb(r, g, b):
    return RGBColor(
        max(0, min(255, int(r))),
        max(0, min(255, int(g))),
        max(0, min(255, int(b))),
    )


def hsv(h, s=1.0, v=1.0):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
    return rgb(r * 255, g * 255, b * 255)


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
    return [color for _ in range(N)]


# ============================================================
# GRUPOS
# ============================================================

LETTERS = list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

TOP_NUMBERS = list("1234567890")

NUMPAD_NUMBERS = [
    "Number Pad 1", "Number Pad 2", "Number Pad 3",
    "Number Pad 4", "Number Pad 5", "Number Pad 6",
    "Number Pad 7", "Number Pad 8", "Number Pad 9",
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

FUNCTIONS = [f"F{i}" for i in range(1, 13)]

NAV = [
    "Insert", "Home", "Page Up",
    "Delete", "End", "Page Down",
    "Left Arrow", "Right Arrow",
    "Up Arrow", "Down Arrow",
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
    "-", "=", "[", "]",
    "\\ (ANSI)", "\\ (ISO)",
    "#", ";", "'", "`",
    ",", ".", "/",
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


# ============================================================
# COMUM
# Nenhuma tecla apagada.
# ============================================================

def indicators(c, color):
    for name in [
        "Logo Lighting",
        "Game Mode",
        "Caps Lock Indicator",
        "Scroll Lock Indicator",
    ]:
        raw(c, name, color)


def num_indicator(c, color):
    raw(c, "Num Lock Indicator", color)


# ============================================================
# PRESET 0 - ULTRA BLUE
# ============================================================

def preset_0(t):
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
# PRESET 1 - ORIGINAL
# ============================================================

def preset_1(t):
    c = fill(rgb(15, 80, 190))

    keys(c, LETTERS, rgb(0, 100, 255))
    keys(c, SYMBOLS, rgb(0, 170, 255))
    keys(c, FUNCTIONS, rgb(180, 30, 255))
    keys(c, NAV, rgb(0, 245, 255))
    keys(c, MODS, rgb(210, 230, 255))
    keys(c, MEDIA, rgb(255, 30, 170))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 80))

    # NUMPAD ENTER PISCANDO, MAS NUNCA APAGA
    p = (math.sin(t * 5.0) + 1.0) / 2.0

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
    phase = (math.sin(t * 0.45) + 1.0) / 2.0
    warm = hsv(phase * 0.145, 1.0, 1.0)

    keys(c, NUMBERS, warm)
    num_indicator(c, warm)

    indicators(c, rgb(0, 100, 255))

    return c


# ============================================================
# PRESET 2 - CYBER LIGHT
# ============================================================

def preset_2(t):
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

    indicators(c, rgb(0, 255, 255))
    num_indicator(c, rgb(255, 30, 180))

    return c


# ============================================================
# PRESET 3 - MATRIX BRILHANTE
# ============================================================

def preset_3(t):
    c = fill(rgb(20, 130, 40))

    pulse = 200 + 55 * ((math.sin(t * 1.2) + 1) / 2)

    # A-Z todas juntas
    keys(c, LETTERS, rgb(20, pulse, 60))
    keys(c, NUMBERS, rgb(190, 255, 40))
    keys(c, FUNCTIONS, rgb(20, 230, 80))
    keys(c, NAV, rgb(80, 255, 150))
    keys(c, MODS, rgb(80, 190, 100))
    keys(c, SYMBOLS, rgb(50, 240, 100))
    keys(c, MEDIA, rgb(160, 255, 180))

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(255, 255, 255))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    indicators(c, rgb(30, 255, 90))
    num_indicator(c, rgb(190, 255, 40))

    return c


# ============================================================
# PRESET 4 - ICE BRILHANTE
# ============================================================

def preset_4(t):
    c = fill(rgb(70, 150, 230))

    keys(c, LETTERS, rgb(150, 235, 255))
    keys(c, NUMBERS, rgb(255, 255, 255))
    keys(c, FUNCTIONS, rgb(40, 210, 255))
    keys(c, NAV, rgb(60, 130, 255))
    keys(c, MODS, rgb(150, 200, 255))
    keys(c, SYMBOLS, rgb(100, 220, 255))
    keys(c, MEDIA, rgb(170, 245, 255))

    key(c, "Escape", rgb(255, 40, 40))
    key(c, "Enter", rgb(0, 255, 255))
    key(c, "Number Pad Enter", rgb(255, 255, 255))

    indicators(c, rgb(150, 235, 255))
    num_indicator(c, rgb(255, 255, 255))

    return c


# ============================================================
# WAVE HELPER
# ============================================================

def wave_base(t, speed, offset=0.0, saturation=0.85):
    c = []

    for i in range(N):
        hue = (
            (i / max(1, N)) +
            (t * speed) +
            offset
        ) % 1.0

        # Sempre brilho máximo
        c.append(
            hsv(
                hue,
                saturation,
                1.0
            )
        )

    return c


def preserve_letter_group(c, t, speed, offset=0.0):
    # TODAS A-Z exatamente a mesma cor
    hue = (t * speed + offset) % 1.0
    letters_color = hsv(hue, 0.80, 1.0)
    keys(c, LETTERS, letters_color)


# ============================================================
# PRESET 5 - RGB WAVE
# ============================================================

def preset_5(t):
    c = wave_base(t, CURRENT_SPEED * 0.06)

    preserve_letter_group(
        c,
        t,
        CURRENT_SPEED * 0.06
    )

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 100))

    return c


# ============================================================
# PRESET 6 - WARM WAVE
# ============================================================

def preset_6(t):
    c = []

    for i in range(N):
        phase = (
            (i / max(1, N)) * 0.5 +
            t * CURRENT_SPEED * 0.08
        )

        x = (math.sin(phase * math.pi * 2) + 1) / 2

        c.append(
            hsv(
                x * 0.14,
                1.0,
                1.0
            )
        )

    # letras todas quentes IGUAIS
    x = (
        math.sin(t * CURRENT_SPEED * 0.6) + 1
    ) / 2

    keys(
        c,
        LETTERS,
        hsv(x * 0.14, 1.0, 1.0)
    )

    key(c, "Escape", rgb(255, 255, 255))
    key(c, "Enter", rgb(0, 255, 100))

    return c


# ============================================================
# PRESET 7 - OCEAN WAVE
# ============================================================

def preset_7(t):
    c = []

    for i in range(N):
        phase = (
            i / max(1, N) +
            t * CURRENT_SPEED * 0.05
        ) % 1.0

        hue = 0.48 + phase * 0.18

        c.append(
            hsv(
                hue,
                0.85,
                1.0
            )
        )

    # A-Z juntas
    hue = (
        0.48 +
        ((t * CURRENT_SPEED * 0.05) % 1.0) * 0.18
    )

    keys(
        c,
        LETTERS,
        hsv(hue, 0.80, 1.0)
    )

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 130))

    return c


# ============================================================
# PRESET 8 - PURPLE/PINK WAVE
# ============================================================

def preset_8(t):
    c = []

    for i in range(N):
        phase = (
            i / max(1, N) +
            t * CURRENT_SPEED * 0.055
        )

        x = (
            math.sin(phase * math.pi * 2) + 1
        ) / 2

        hue = 0.75 + x * 0.18

        c.append(
            hsv(
                hue,
                0.85,
                1.0
            )
        )

    x = (
        math.sin(
            t * CURRENT_SPEED * 0.5
        ) + 1
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
# PRESET 9 - SUPER RGB WAVE
# ============================================================

def preset_9(t):
    c = wave_base(
        t,
        CURRENT_SPEED * 0.10,
        saturation=1.0
    )

    # letras continuam TODAS iguais
    preserve_letter_group(
        c,
        t,
        CURRENT_SPEED * 0.10,
        0.15
    )

    # F1-F12 também juntas
    function_color = hsv(
        (
            t * CURRENT_SPEED * 0.10 +
            0.45
        ) % 1.0,
        1.0,
        1.0
    )

    keys(
        c,
        FUNCTIONS,
        function_color
    )

    # números juntos
    number_color = hsv(
        (
            t * CURRENT_SPEED * 0.10 +
            0.70
        ) % 1.0,
        1.0,
        1.0
    )

    keys(
        c,
        NUMBERS,
        number_color
    )

    num_indicator(
        c,
        number_color
    )

    key(c, "Escape", rgb(255, 0, 0))
    key(c, "Enter", rgb(0, 255, 100))

    # enter numpad pulsa BRILHANTE
    p = (
        math.sin(
            t * CURRENT_SPEED * 5
        ) + 1
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


# ============================================================
# PRESETS
# ============================================================

PRESETS = {
    "0": ("ULTRA BLUE", preset_0),
    "1": ("AZUL + QUENTE", preset_1),
    "2": ("CYBER LIGHT", preset_2),
    "3": ("MATRIX LIGHT", preset_3),
    "4": ("ICE LIGHT", preset_4),

    # METADE WAVE
    "5": ("RGB WAVE", preset_5),
    "6": ("WARM WAVE", preset_6),
    "7": ("OCEAN WAVE", preset_7),
    "8": ("PURPLE WAVE", preset_8),
    "9": ("SUPER RGB WAVE", preset_9),
}


# ============================================================
# VELOCIDADE GLOBAL
# ============================================================

CURRENT_SPEED = 1.0

MIN_SPEED = 0.15
MAX_SPEED = 6.0

SPEED_STEP = 0.20


def speed_up():
    global CURRENT_SPEED

    CURRENT_SPEED = min(
        MAX_SPEED,
        CURRENT_SPEED + SPEED_STEP
    )


def speed_down():
    global CURRENT_SPEED

    CURRENT_SPEED = max(
        MIN_SPEED,
        CURRENT_SPEED - SPEED_STEP
    )


# ============================================================
# UI
# ============================================================

def draw(active):
    os.system("clear")

    print("╔════════════════════════════════════════════════╗")
    print("║           LOGITECH G512 RGB MANAGER            ║")
    print("╠════════════════════════════════════════════════╣")

    for n in "0123456789":
        name = PRESETS[n][0]

        if n == active:
            print(f"║ ▶ [{n}] {name:<38} ║")
        else:
            print(f"║   [{n}] {name:<38} ║")

    print("╠════════════════════════════════════════════════╣")
    print(f"║ VELOCIDADE: {CURRENT_SPEED:4.2f}x                           ║")
    print("║                                                ║")
    print("║ 0-9  TROCAR PRESET IMEDIATAMENTE               ║")
    print("║  +   MAIS RÁPIDO                               ║")
    print("║  -   MAIS LENTO                                ║")
    print("║                                                ║")
    print("║ NÃO PRECISA ENTER                              ║")
    print("║ Q = SAIR                                       ║")
    print("╚════════════════════════════════════════════════╝")


# ============================================================
# MAIN
# ============================================================

def main():
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    active = "1"
    effect = PRESETS[active][1]

    start = time.monotonic()

    draw(active)

    try:
        tty.setcbreak(fd)

        while True:

            ready, _, _ = select.select(
                [sys.stdin],
                [],
                [],
                0.045
            )

            if ready:
                pressed = sys.stdin.read(1)

                if pressed.lower() == "q":
                    break

                if pressed in PRESETS:
                    active = pressed
                    effect = PRESETS[pressed][1]
                    start = time.monotonic()

                    draw(active)

                elif pressed in ["+", "="]:
                    speed_up()
                    draw(active)

                elif pressed in ["-", "_"]:
                    speed_down()
                    draw(active)

            t = time.monotonic() - start

            keyboard.set_colors(
                effect(t)
            )

    except KeyboardInterrupt:
        pass

    finally:
        termios.tcsetattr(
            fd,
            termios.TCSADRAIN,
            old
        )

        print("\nG512 RGB encerrado.")


if __name__ == "__main__":
    main()
