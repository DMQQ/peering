"""Captures one language's screens from the simulator into raw/<lang>/.

    python3 capture.py de            # needs the Mac host running, paired, and the demo window up

The demo window is `qlmanage -p demo/editor.png`; the simulator streams only that window.
"""
import json, os, re, subprocess, sys, tempfile
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SIM = "A13318D0-CA5F-4A0C-B54F-2C4DD6CE031B"
LOCALES = {"en": "en_US", "es": "es_ES", "fr": "fr_FR", "de": "de_DE", "pt-BR": "pt_BR", "ja": "ja_JP",
           "ko": "ko_KR", "zh-Hans": "zh_CN", "ru": "ru_RU", "it": "it_IT"}
KEYS = ["Apps", "Keyboard", "Shortcuts", "Open Mac terminals", "Mac terminals", "More connection options", "Connect via Relay", "Skip", "Hide keyboard", "New terminal", "Done", "Settings", "Connect", "Quit", "Agents"]


def labels(lang):
    cat = json.load(open(f"{ROOT}/MacCast/Localizable.xcstrings"))["strings"]
    out = {"lang": lang, "locale": LOCALES[lang]}
    for k in KEYS:
        loc = cat.get(k, {}).get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value")
        out[k] = k if lang == "en" or loc is None else loc
    return out


def attempt(lang):
    subprocess.run(["xcrun", "simctl", "terminate", SIM, "pl.dmq.peering"], capture_output=True)
    for key, kind in (("Peering.resumeWhenReachable", "-bool NO"), ("Peering.lastHostID", None), ("Peering.lastHostName", None)):
        cmd = ["xcrun", "simctl", "spawn", SIM, "defaults"] + (["write", "pl.dmq.peering", key] + kind.split() if kind else ["delete", "pl.dmq.peering", key])
        subprocess.run(cmd, capture_output=True)
    json.dump(labels(lang), open("/Users/Shared/peering-labels.json", "w"), ensure_ascii=False)
    tmp = tempfile.mkdtemp()
    result = f"{tmp}/r.xcresult"
    run_log = subprocess.run(["xcodebuild", "test", "-project", f"{ROOT}/MacCast.xcodeproj", "-scheme", "MacCast",
                              "-destination", f"platform=iOS Simulator,id={SIM}", "-derivedDataPath", os.environ.get("TMPDIR", "/tmp") + "/PeeringUI",
                              "-only-testing:MacCastUITests/ListingShotTests/testScenes", "-resultBundlePath", result],
                             capture_output=True, text=True)
    for line in (run_log.stdout + run_log.stderr).splitlines():
        if "error:" in line:
            print(line[:240])
    out = f"{tmp}/att"
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", out], capture_output=True)
    shots = {}
    for t in json.load(open(f"{out}/manifest.json")):
        for a in t["attachments"]:
            m = re.match(r"(0[1-9]-[a-z]+)_0_", a.get("suggestedHumanReadableName", ""))
            if m:
                shots[m.group(1)] = Image.open(f"{out}/{a['exportedFileName']}").convert("RGB")
    if "08-fail" in shots:
        os.makedirs(f"{HERE}/debug", exist_ok=True)
        shots["08-fail"].save(f"{HERE}/debug/{lang}-fail.png")
    return {k: v for k, v in shots.items() if k != "08-fail"}


def run(lang, tries=1):
    for n in range(tries):
        shots = attempt(lang)
        if len(shots) == 7:
            dest = f"{HERE}/raw/{lang}"
            os.makedirs(dest, exist_ok=True)
            for k, im in shots.items():
                im.save(f"{dest}/{k}.png")
            print(lang, "ok")
            return True
        print(lang, "attempt", n + 1, "got", sorted(shots))
    return False


if __name__ == "__main__":
    for lang in sys.argv[1:]:
        run(lang)
