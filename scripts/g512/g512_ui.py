#!/usr/bin/env python3

import json
import os
import select
import sys
import tempfile
import termios
import tty


BASE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = f"{BASE}/g512_state.json"

NAMES = {
    "0": "ULTRA BLUE",
    "1": "AZUL + QUENTE",
    "2": "CYBER LIGHT",
    "3": "MATRIX LIGHT",
    "4": "ICE LIGHT",
    "5": "RGB WAVE",
    "6": "WARM WAVE",
    "7": "OCEAN WAVE",
    "8": "PURPLE WAVE",
    "9": "SUPER RGB WAVE",
}


def load():
    try:
        with open(STATE_FILE, "r") as f:
            s = json.load(f)

        preset = str(s.get("preset", "1"))
        speed = float(s.get("speed", 1.0))

    except Exception:
        preset = "1"
        speed = 1.0

    if preset not in NAMES:
        preset = "1"

    speed = max(0.15, min(6.0, speed))

    return {
        "preset": preset,
        "speed": speed,
    }


def save(state):
    fd, tmp = tempfile.mkstemp(
        dir=BASE,
        prefix=".g512_state_",
        text=True
    )

    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f)
            f.flush()
            os.fsync(f.fileno())

        os.replace(tmp, STATE_FILE)

    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def draw(state):
    os.system("clear")

    print("╔════════════════════════════════════════════════╗")
    print("║           LOGITECH G512 RGB MANAGER            ║")
    print("╠════════════════════════════════════════════════╣")

    for n in "0123456789":
        name = NAMES[n]

        if n == state["preset"]:
            print(f"║ ▶ [{n}] {name:<38} ║")
        else:
            print(f"║   [{n}] {name:<38} ║")

    print("╠════════════════════════════════════════════════╣")
    print(f"║ VELOCIDADE: {state['speed']:4.2f}x                           ║")
    print("║                                                ║")
    print("║ 0-9  TROCA PRESET NA HORA                      ║")
    print("║ +    MAIS RÁPIDO                               ║")
    print("║ -    MAIS LENTO                                ║")
    print("║                                                ║")
    print("║ Q = FECHAR SOMENTE ESTE MENU                   ║")
    print("║     RGB CONTINUA RODANDO                       ║")
    print("╚════════════════════════════════════════════════╝")


def main():
    state = load()

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    draw(state)

    try:
        tty.setcbreak(fd)

        while True:
            ready, _, _ = select.select(
                [sys.stdin],
                [],
                [],
                None
            )

            if not ready:
                continue

            k = sys.stdin.read(1)

            if k.lower() == "q":
                break

            if k in NAMES:
                state["preset"] = k
                save(state)
                draw(state)

            elif k in ["+", "="]:
                state["speed"] = min(
                    6.0,
                    state["speed"] + 0.20
                )

                save(state)
                draw(state)

            elif k in ["-", "_"]:
                state["speed"] = max(
                    0.15,
                    state["speed"] - 0.20
                )

                save(state)
                draw(state)

    finally:
        termios.tcsetattr(
            fd,
            termios.TCSADRAIN,
            old
        )

        print()
        print(
            "Menu fechado. "
            f"Preset {state['preset']} continua rodando."
        )


if __name__ == "__main__":
    main()
