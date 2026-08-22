#!/usr/bin/env python3

import colorsys
import math
import time

from openrgb import OpenRGBClient
from openrgb.utils import RGBColor


# ============================================================
# OPENRGB
# ============================================================

client = OpenRGBClient()

keyboard = next(
    (d for d in client.devices if "G512" in d.name),
    None,
)

if keyboard is None:
    raise SystemExit("ERRO: Logitech G512 não encontrado.")

keyboard.set_mode("Direct")

leds = {led.name: i for i, led in enumerate(keyboard.leds)}


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


def key_index(name):
    return leds.get(f"Key: {name}")


def raw_index(name):
    return leds.get(name)


def set_key(colors, name, color):
    i = key_index(name)
    if i is not None:
        colors[i] = color


def set_keys(colors, names, color):
    for name in names:
        set_key(colors, name, color)


def set_raw(colors, name, color):
    i = raw_index(name)
    if i is not None:
        colors[i] = color


def base(color):
    return [color for _ in keyboard.leds]


def send(colors):
    keyboard.set_colors(colors)


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

NUMPAD_OPERATORS = [
    "Number Pad /",
    "Number Pad *",
    "Number Pad -",
    "Number Pad +",
    "Number Pad .",
]

ALL_NUMBERS = TOP_NUMBERS + NUMPAD_NUMBERS + [
    "Num Lock",
] + NUMPAD_OPERATORS

FUNCTIONS = [f"F{i}" for i in range(1, 13)]

NAV = [
    "Insert",
    "Home",
    "Page Up",
    "Delete",
    "End",
    "Page Down",
    "Right Arrow",
    "Left Arrow",
    "Down Arrow",
    "Up Arrow",
]

MODIFIERS = [
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

RAW_INDICATORS = [
    "Logo Lighting",
    "Game Mode",
    "Caps Lock Indicator",
    "Scroll Lock Indicator",
]


# ============================================================
# CORES
# ============================================================

BLACK      = rgb(0, 0, 0)
DARK       = rgb(0, 5, 18)

BLUE       = rgb(0, 65, 255)
CYAN       = rgb(0, 220, 255)
GREEN      = rgb(0, 255, 90)
RED        = rgb(255, 0, 0)
ORANGE     = rgb(255, 90, 0)
YELLOW     = rgb(255, 220, 0)
PURPLE     = rgb(155, 0, 255)
PINK       = rgb(255, 0, 130)
WHITE      = rgb(230, 240, 255)
ICE        = rgb(100, 210, 255)
LIME       = rgb(150, 255, 0)
GOLD       = rgb(255, 170, 0)


# ============================================================
# PRESET 1
# AZUL + NÚMEROS QUENTES
# ============================================================

def preset_1(t):
    colors = base(DARK)

    set_keys(colors, LETTERS, BLUE)
    set_keys(colors, SYMBOLS, BLUE)
    set_keys(colors, FUNCTIONS, PURPLE)
    set_keys(colors, NAV, CYAN)
    set_keys(colors, MODIFIERS, WHITE)
    set_keys(colors, MEDIA, PINK)

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", GREEN)

    # enter numérico piscando
    if int(t * 2.5) % 2 == 0:
        set_key(colors, "Number Pad Enter", WHITE)
    else:
        set_key(colors, "Number Pad Enter", rgb(0, 35, 5))

    # todos números sincronizados em ciclo quente lento
    phase = (math.sin(t * 0.55) + 1.0) / 2.0
    warm = hsv(phase * 0.14, 1.0, 1.0)

    set_keys(colors, ALL_NUMBERS, warm)
    set_raw(colors, "Num Lock Indicator", warm)

    for name in RAW_INDICATORS:
        set_raw(colors, name, BLUE)

    return colors


# ============================================================
# PRESET 2
# CYBERPUNK
# ============================================================

def preset_2(t):
    colors = base(rgb(5, 0, 15))

    set_keys(colors, LETTERS, CYAN)
    set_keys(colors, FUNCTIONS, PINK)
    set_keys(colors, ALL_NUMBERS, PURPLE)
    set_keys(colors, NAV, PINK)
    set_keys(colors, MODIFIERS, rgb(40, 0, 90))

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", CYAN)
    set_key(colors, "Number Pad Enter", PINK)

    return colors


# ============================================================
# PRESET 3
# MATRIX
# ============================================================

def preset_3(t):
    colors = base(rgb(0, 8, 0))

    pulse = 0.55 + ((math.sin(t * 1.4) + 1) / 2) * 0.45

    green = rgb(0, 255 * pulse, 35 * pulse)

    set_keys(colors, LETTERS, green)
    set_keys(colors, TOP_NUMBERS, LIME)
    set_keys(colors, NUMPAD_NUMBERS, LIME)
    set_keys(colors, FUNCTIONS, rgb(0, 100, 15))
    set_keys(colors, NAV, rgb(0, 180, 40))

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", WHITE)
    set_key(colors, "Number Pad Enter", WHITE)

    return colors


# ============================================================
# PRESET 4
# ICE
# ============================================================

def preset_4(t):
    colors = base(rgb(0, 8, 22))

    set_keys(colors, LETTERS, ICE)
    set_keys(colors, ALL_NUMBERS, WHITE)
    set_keys(colors, FUNCTIONS, CYAN)
    set_keys(colors, NAV, BLUE)
    set_keys(colors, MODIFIERS, rgb(40, 90, 150))

    set_key(colors, "Escape", rgb(255, 60, 60))
    set_key(colors, "Enter", CYAN)
    set_key(colors, "Number Pad Enter", BLUE)

    return colors


# ============================================================
# PRESET 5
# FIRE
# ============================================================

def preset_5(t):
    colors = base(rgb(20, 0, 0))

    warm = hsv(((math.sin(t * 0.8) + 1) / 2) * 0.11)

    set_keys(colors, LETTERS, warm)
    set_keys(colors, ALL_NUMBERS, YELLOW)
    set_keys(colors, FUNCTIONS, RED)
    set_keys(colors, NAV, ORANGE)

    set_key(colors, "Escape", WHITE)
    set_key(colors, "Enter", ORANGE)
    set_key(colors, "Number Pad Enter", YELLOW)

    return colors


# ============================================================
# PRESET 6
# PURPLE NIGHT
# ============================================================

def preset_6(t):
    colors = base(rgb(8, 0, 20))

    set_keys(colors, LETTERS, PURPLE)
    set_keys(colors, ALL_NUMBERS, PINK)
    set_keys(colors, FUNCTIONS, BLUE)
    set_keys(colors, NAV, CYAN)
    set_keys(colors, MODIFIERS, rgb(80, 20, 130))

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", WHITE)
    set_key(colors, "Number Pad Enter", PINK)

    return colors


# ============================================================
# PRESET 7
# OCEAN
# ============================================================

def preset_7(t):
    colors = base(rgb(0, 8, 18))

    wave = ((math.sin(t * 0.7) + 1) / 2)
    ocean = hsv(0.50 + wave * 0.10, 1.0, 1.0)

    set_keys(colors, LETTERS, ocean)
    set_keys(colors, ALL_NUMBERS, CYAN)
    set_keys(colors, FUNCTIONS, BLUE)
    set_keys(colors, NAV, ICE)

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", GREEN)
    set_key(colors, "Number Pad Enter", CYAN)

    return colors


# ============================================================
# PRESET 8
# GOLD
# ============================================================

def preset_8(t):
    colors = base(rgb(15, 6, 0))

    set_keys(colors, LETTERS, GOLD)
    set_keys(colors, ALL_NUMBERS, YELLOW)
    set_keys(colors, FUNCTIONS, WHITE)
    set_keys(colors, NAV, ORANGE)
    set_keys(colors, MODIFIERS, rgb(110, 55, 0))

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", WHITE)
    set_key(colors, "Number Pad Enter", GOLD)

    return colors


# ============================================================
# PRESET 9
# RGB WAVE
# ============================================================

def preset_9(t):
    colors = base(BLACK)

    count = max(1, len(keyboard.leds))

    for i in range(count):
        hue = (i / count + t * 0.04) % 1.0
        colors[i] = hsv(hue)

    set_key(colors, "Escape", RED)

    return colors


# ============================================================
# PRESET 10
# POLICE
# ============================================================

def preset_10(t):
    colors = base(BLACK)

    blink = int(t * 3) % 2

    left = BLUE if blink == 0 else RED
    right = RED if blink == 0 else BLUE

    for i, name in enumerate(LETTERS):
        set_key(colors, name, left if i < 13 else right)

    set_keys(colors, FUNCTIONS[:6], left)
    set_keys(colors, FUNCTIONS[6:], right)
    set_keys(colors, TOP_NUMBERS[:5], left)
    set_keys(colors, TOP_NUMBERS[5:], right)

    set_key(colors, "Escape", WHITE)
    set_key(colors, "Enter", GREEN)

    return colors


# ============================================================
# PRESET 11
# MINIMAL BLUE
# ============================================================

def preset_11(t):
    colors = base(BLACK)

    set_keys(colors, LETTERS, BLUE)
    set_keys(colors, TOP_NUMBERS, CYAN)
    set_keys(colors, NUMPAD_NUMBERS, CYAN)
    set_keys(colors, FUNCTIONS, rgb(70, 70, 150))
    set_keys(colors, NAV, rgb(0, 110, 180))

    set_key(colors, "Escape", RED)
    set_key(colors, "Enter", GREEN)
    set_key(colors, "Number Pad Enter", GREEN)

    return colors


# ============================================================
# MENU
# ============================================================

PRESETS = {
    "1":  ("Azul + números quentes", preset_1),
    "2":  ("Cyberpunk", preset_2),
    "3":  ("Matrix", preset_3),
    "4":  ("Ice", preset_4),
    "5":  ("Fire", preset_5),
    "6":  ("Purple Night", preset_6),
    "7":  ("Ocean", preset_7),
    "8":  ("Gold", preset_8),
    "9":  ("RGB Wave", preset_9),
    "10": ("Police", preset_10),
    "11": ("Minimal Blue", preset_11),
}


def menu():
    print()
    print("========================================")
    print(" LOGITECH G512 RGB")
    print("========================================")

    for n, (name, _) in PRESETS.items():
        print(f" {n:>2}  {name}")

    print()
    print(" q   sair")
    print("========================================")
    print()


def main():
    menu()

    choice = input("Preset: ").strip()

    if choice.lower() == "q":
        return

    if choice not in PRESETS:
        raise SystemExit("Preset inválido.")

    name, effect = PRESETS[choice]

    print()
    print(f"Ativo: {choice} - {name}")
    print("Ctrl+C para voltar ao terminal.")
    print()

    start = time.monotonic()

    try:
        while True:
            t = time.monotonic() - start

            colors = effect(t)
            send(colors)

            time.sleep(0.08)

    except KeyboardInterrupt:
        print("\nEncerrado.")


if __name__ == "__main__":
    main()
