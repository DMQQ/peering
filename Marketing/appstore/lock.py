"""Captures the real lock screen with two pushed notifications, in one language, into raw/<lang>/07-lock.png.

    python3 lock.py de

Switches the simulator's system language (the lock screen's date and clock follow it), so the
simulator is rebooted; `python3 lock.py --restore` puts the English settings back.
"""
import json, os, re, subprocess, sys, tempfile, time
from PIL import Image
import capture
from capture import SIM, HERE, LOCALES, ROOT

PREFS = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{SIM}/data/Library/Preferences/.GlobalPreferences.plist")


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def set_language(lang):
    sh("xcrun", "simctl", "shutdown", SIM)
    sh("plutil", "-replace", "AppleLanguages", "-json", json.dumps([lang]), PREFS)
    sh("plutil", "-replace", "AppleLocale", "-string", LOCALES[lang], PREFS)
    sh("xcrun", "simctl", "boot", SIM)
    sh("xcrun", "simctl", "bootstatus", SIM, "-b")
    time.sleep(8)


def title(lang, key):
    cat = json.load(open(f"{ROOT}/MacCast/Localizable.xcstrings"))["strings"]
    return key if lang == "en" else cat[key]["localizations"][lang]["stringUnit"]["value"]


def push(lang, ttl, body, thread):
    f = tempfile.mktemp(suffix=".apns")
    json.dump({"Simulator Target Bundle": "pl.dmq.peering",
               "aps": {"alert": {"title": ttl, "body": body}, "sound": "default", "thread-id": thread}}, open(f, "w"), ensure_ascii=False)
    print(sh("xcrun", "simctl", "push", SIM, "pl.dmq.peering", f).stderr.strip())


def run(lang):
    copy = json.load(open(f"{HERE}/copy.json"))[lang]
    set_language(lang)
    json.dump(capture.labels(lang), open("/Users/Shared/peering-labels.json", "w"), ensure_ascii=False)
    for f in ("peering-home", "peering-go"):
        if os.path.exists(f"/Users/Shared/{f}"):
            os.remove(f"/Users/Shared/{f}")
    tmp = tempfile.mkdtemp()
    result = f"{tmp}/r.xcresult"
    proc = subprocess.Popen(["xcodebuild", "test", "-project", f"{ROOT}/MacCast.xcodeproj", "-scheme", "MacCast",
                             "-destination", f"platform=iOS Simulator,id={SIM}", "-derivedDataPath", os.environ.get("TMPDIR", "/tmp") + "/PeeringUI",
                             "-only-testing:MacCastUITests/LockShotTests/testLockScreen", "-resultBundlePath", result],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(600):
        if os.path.exists("/Users/Shared/peering-home"):
            break
        time.sleep(1)
    time.sleep(3)
    mac = "Damian’s MacBook Pro: "
    push(lang, title(lang, "Terminal needs you"), mac + copy["n1"], "a")
    time.sleep(3)
    push(lang, title(lang, "Terminal finished"), mac + copy["n2"], "b")
    time.sleep(10)
    open("/Users/Shared/peering-go", "w").write("go")
    proc.wait()
    out = f"{tmp}/att"
    sh("xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", out)
    for t in json.load(open(f"{out}/manifest.json")):
        for a in t["attachments"]:
            if "10-lock" in a.get("suggestedHumanReadableName", ""):
                dest = f"{HERE}/raw/{lang}"
                os.makedirs(dest, exist_ok=True)
                Image.open(f"{out}/{a['exportedFileName']}").convert("RGB").save(f"{dest}/07-lock.png")
                print(lang, "lock ok")
                return True
    print(lang, "lock failed")
    return False


if __name__ == "__main__":
    if sys.argv[1] == "--restore":
        set_language("en")
    else:
        for l in sys.argv[1:]:
            run(l)
