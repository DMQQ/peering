#!/usr/bin/env python3
"""Adds the missing localizations of the Pro monthly and yearly subscriptions in App Store Connect.

    ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... python3 Tools/localize_pro_subscriptions.py [--dry-run]

Locales that already exist (en-US) are left as they are. Needs: pip3 install PyJWT cryptography requests
"""
import os
import sys
import time
from pathlib import Path

import jwt
import requests

APP_ID = "6812658408"
BASE = "https://api.appstoreconnect.apple.com/v1"
NAME_LIMIT, DESCRIPTION_LIMIT = 30, 45

# locale: (monthly name, yearly name, description shared by both)
LOCALIZATIONS = {
    "de-DE": ("Peering Pro", "Peering Pro (Jährlich)", "Jeder Mac, jedes Display, unbegrenztes Relay."),
    "es-ES": ("Peering Pro", "Peering Pro (Anual)", "Todos los Mac, pantallas y relay ilimitado."),
    "fr-FR": ("Peering Pro", "Peering Pro (Annuel)", "Chaque Mac, chaque écran, relais illimité."),
    "it": ("Peering Pro", "Peering Pro (Annuale)", "Ogni Mac, ogni display, relay illimitato."),
    "ja": ("Peering Pro", "Peering Pro(年間)", "すべてのMacとディスプレイ、リレー無制限。"),
    "ko": ("Peering Pro", "Peering Pro (연간)", "모든 Mac, 모든 디스플레이, 무제한 릴레이."),
    "pt-BR": ("Peering Pro", "Peering Pro (Anual)", "Todos os Macs, telas e relay ilimitado."),
    "ru": ("Peering Pro", "Peering Pro (на год)", "Все Mac и дисплеи, ретранслятор без лимита."),
    "zh-Hans": ("Peering Pro", "Peering Pro(年付)", "所有 Mac、所有显示器，中继不限量。"),
}
PRODUCTS = {"pl.dmq.peering.iap.pro.monthly": 0, "pl.dmq.peering.iap.pro.year": 1}

for locale, (monthly, yearly, description) in LOCALIZATIONS.items():
    for name in (monthly, yearly):
        assert 2 <= len(name) <= NAME_LIMIT, f"{locale} name {name!r} is {len(name)} characters"
    assert 2 <= len(description) <= DESCRIPTION_LIMIT, f"{locale} description is {len(description)} characters"
    assert "—" not in description and "–" not in description

if "--dry-run" in sys.argv:
    sys.exit("lengths ok")

now = int(time.time())
TOKEN = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    Path(os.environ["ASC_KEY_PATH"]).expanduser().read_text(),
    algorithm="ES256",
    headers={"kid": os.environ["ASC_KEY_ID"]},
)


def call(method, path, body=None, params=None):
    response = requests.request(
        method, path if path.startswith("http") else BASE + path,
        headers={"Authorization": f"Bearer {TOKEN}"}, json=body, params=params, timeout=30,
    )
    if response.status_code >= 400:
        sys.exit(f"{method} {path}: {response.status_code} {response.text[:400]}")
    return response.json() if response.content else {}


subscriptions = {}
for group in call("GET", f"/apps/{APP_ID}/subscriptionGroups")["data"]:
    for item in call("GET", f"/subscriptionGroups/{group['id']}/subscriptions", params={"limit": 50})["data"]:
        subscriptions[item["attributes"]["productId"]] = item["id"]

for product, column in PRODUCTS.items():
    if product not in subscriptions:
        sys.exit(f"{product} not found")
    subscription_id = subscriptions[product]
    existing = {
        item["attributes"]["locale"]
        for item in call("GET", f"/subscriptions/{subscription_id}/subscriptionLocalizations", params={"limit": 50})["data"]
    }
    for locale, texts in LOCALIZATIONS.items():
        if locale in existing:
            continue
        call("POST", "/subscriptionLocalizations", {"data": {
            "type": "subscriptionLocalizations",
            "attributes": {"locale": locale, "name": texts[column], "description": texts[2]},
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": subscription_id}}}}})
    print(product)
    for item in call("GET", f"/subscriptions/{subscription_id}/subscriptionLocalizations", params={"limit": 50})["data"]:
        a = item["attributes"]
        print(f'  {a["locale"]:8} {a.get("state", ""):18} {a["name"]} | {a["description"]}')
