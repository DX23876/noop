#!/usr/bin/env python3
"""Emulator smoke test of the demo app (Android plan D-8): launch, get past the terms and onboarding, then
screenshot Today and the main tabs. Usage: android_smoke_flow.py <out_dir>. Expects one booted emulator with the
demo APK installed; `Tools/android-smoke.sh` drives it across screen sizes. Prints "crash: True" if the app's
process died with a fatal exception."""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "io.github.dx23876.noop.demo.debug"
OUT = sys.argv[1]
ADVANCE = re.compile(r"^(continue|next|begin|save & continue|skip( for now)?|not now|later|done|get started|"
                     r"finish|start|enter noop|explore( the demo)?|maybe later|skip setup|i'll do it later)$")


def adb(*a, text=True):
    return subprocess.run(["adb", *a], capture_output=True, text=text).stdout


def nodes():
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("exec-out", "cat", "/sdcard/ui.xml")
    root = ET.fromstring(xml[xml.index("<"):])
    out = []
    for n in root.iter("node"):
        a, b, c, d = map(int, re.findall(r"\d+", n.get("bounds")))
        out.append({"label": (n.get("text") or n.get("content-desc") or "").strip(), "cls": n.get("class"),
                    "checked": n.get("checked") == "true", "enabled": n.get("enabled") == "true",
                    "click": n.get("clickable") == "true", "x": (a + c) // 2, "y": (b + d) // 2,
                    "w": c - a, "h": d - b, "pkg": n.get("package")})
    return out


def tap(n):
    adb("shell", "input", "tap", str(n["x"]), str(n["y"]))


def shot(name):
    data = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    # A foldable has two displays and screencap prefixes a warning; the PNG of the first display follows it.
    data = data[data.find(b"\x89PNG"):]
    with open(f"{OUT}/{name}.png", "wb") as f:
        f.write(data)


def size():
    m = re.search(r"(\d+)x(\d+)", adb("shell", "wm", "size"))
    return int(m.group(1)), int(m.group(2))


def swipe_up():
    w, h = size()
    adb("shell", "input", "swipe", str(w // 2), str(int(h * 0.8)), str(w // 2), str(int(h * 0.25)), "300")


def crashed():
    return "FATAL EXCEPTION" in adb("logcat", "-d", "-s", "AndroidRuntime:E")


def main():
    for perm in ["BLUETOOTH_SCAN", "BLUETOOTH_CONNECT", "ACCESS_FINE_LOCATION", "POST_NOTIFICATIONS"]:
        adb("shell", "pm", "grant", PKG, f"android.permission.{perm}")
    adb("logcat", "-c")
    activity = adb("shell", "cmd", "package", "resolve-activity", "--brief", PKG).strip().splitlines()[-1]
    adb("shell", "am", "start", "-W", "-n", activity)
    time.sleep(6)
    shot("01-launch")
    # Terms gate: tick every box (scrolling on short screens), then accept.
    # The button looks disabled but reports enabled, so tick until the four boxes are seen checked, scrolling.
    ticked = 0
    for _ in range(8):
        for n in nodes():
            if n["cls"].endswith("CheckBox") and not n["checked"]:
                tap(n); time.sleep(0.5)
        ticked = max(ticked, sum(1 for n in nodes() if n["cls"].endswith("CheckBox") and n["checked"]))
        if ticked >= 4 or any("TERMS.md" in n["label"] for n in nodes()):
            break
        swipe_up(); time.sleep(1)
    accept = [n for n in nodes() if n["label"].lower() == "accept & continue"]
    if accept:
        tap(accept[0])
    time.sleep(3)
    # Onboarding: press the advancing button on each step, scrolling to reach it.
    step = 0
    for i in range(30):
        ns = nodes()
        if any(re.fullmatch(r"\d+ / \d+", n["label"]) for n in ns):
            step += 1
            shot(f"02-onboarding-{step:02d}")
        hit = None
        for _ in range(3):
            hit = next((n for n in ns if ADVANCE.match(n["label"].lower())), None)
            if hit:
                break
            swipe_up(); time.sleep(1); ns = nodes()
        if not hit:
            break
        tap(hit); time.sleep(2)
        if crashed():
            print("CRASH during onboarding"); break
    time.sleep(4)
    w, h = size()
    for _ in range(6):   # back to the top of Today
        adb("shell", "input", "swipe", str(w // 2), str(int(h * 0.3)), str(w // 2), str(int(h * 0.85)), "200")
    time.sleep(2)
    shot("03-home-top")
    swipe_up(); time.sleep(2)
    shot("04-home-scrolled")
    for _ in range(6):
        adb("shell", "input", "swipe", str(w // 2), str(int(h * 0.3)), str(w // 2), str(int(h * 0.85)), "200")
    time.sleep(1)
    for i, tab in enumerate(["Trends", "Sleep", "More"], start=5):
        hit = next((n for n in nodes() if n["label"] == tab), None)
        if hit is None:
            print("no tab", tab); continue
        tap(hit); time.sleep(3)
        shot(f"{i:02d}-{tab.lower()}")
    print("crash:", crashed())


if __name__ == "__main__":
    main()
