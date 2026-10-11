#!/usr/bin/env python3
"""Sets the localized name and description of the lifetime in-app purchase in App Store Connect.

    ASC_KEY_PATH=... ASC_KEY_ID=... ASC_ISSUER_ID=... python3 Tools/localize_lifetime.py [--dry-run]

Needs: pip3 install PyJWT cryptography requests
"""
import os
import sys
import time
from pathlib import Path

import jwt
import requests

APP_ID = "6812658408"
PRODUCT_ID = "pl.dmq.peering.iap.pro.lifetime1"
BASE = "https://api.appstoreconnect.apple.com/v1"
NAME_LIMIT, DESCRIPTION_LIMIT = 30, 45

LOCALIZATIONS = {
    "en-US": ("Peering Pro (Once)", "Pro for one payment. No renewal."),
    "de-DE": ("Peering Pro (Einmalig)", "Pro einmalig kaufen. Ohne Verlängerung."),
    "es-ES": ("Peering Pro (Pago único)", "Pro con un solo pago. Sin renovación."),
    "fr-FR": ("Peering Pro (Achat unique)", "Pro en un seul paiement. Sans abonnement."),
    "it": ("Peering Pro (Una tantum)", "Pro con un solo pagamento. Nessun rinnovo."),
    "ja": ("Peering Pro(買い切り)", "1回のお支払いでPro。更新はありません。"),
    "ko": ("Peering Pro (1회 구매)", "한 번 결제로 Pro 이용. 갱신 없음."),
    "pt-BR": ("Peering Pro (Pagamento único)", "Pro com um só pagamento. Sem renovação."),
    "ru": ("Peering Pro (разовая покупка)", "Pro за один платёж. Без продления."),
    "zh-Hans": ("Peering Pro(一次性购买)", "一次付费解锁 Pro,无需续订。"),
}


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        Path(os.environ["ASC_KEY_PATH"]).expanduser().read_text(),
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )


def call(method, path, body=None, params=None):
    response = requests.request(
        method, path if path.startswith("http") else BASE + path,
        headers={"Authorization": f"Bearer {TOKEN}"}, json=body, params=params,
    )
    if response.status_code >= 400:
        sys.exit(f"{method} {path}: {response.status_code} {response.text[:400]}")
    return response.json() if response.content else {}


for locale, (name, description) in LOCALIZATIONS.items():
    assert len(name) <= NAME_LIMIT, f"{locale} name is {len(name)} characters"
    assert len(description) <= DESCRIPTION_LIMIT, f"{locale} description is {len(description)} characters"

if "--dry-run" in sys.argv:
    sys.exit("lengths ok")

TOKEN = token()
products = call("GET", f"/apps/{APP_ID}/inAppPurchasesV2", params={"filter[productId]": PRODUCT_ID})["data"]
if not products:
    sys.exit(f"{PRODUCT_ID} not found")
product_id = products[0]["id"]

existing = {
    item["attributes"]["locale"]: item["id"]
    for item in call("GET", f"https://api.appstoreconnect.apple.com/v2/inAppPurchases/{product_id}/inAppPurchaseLocalizations", params={"limit": 200})["data"]
}

for locale, (name, description) in LOCALIZATIONS.items():
    attributes = {"name": name, "description": description}
    if locale in existing:
        call("PATCH", f"/inAppPurchaseLocalizations/{existing[locale]}", {"data": {
            "type": "inAppPurchaseLocalizations", "id": existing[locale], "attributes": attributes}})
    else:
        call("POST", "/inAppPurchaseLocalizations", {"data": {
            "type": "inAppPurchaseLocalizations",
            "attributes": {"locale": locale, **attributes},
            "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": product_id}}}}})

for item in call("GET", f"https://api.appstoreconnect.apple.com/v2/inAppPurchases/{product_id}/inAppPurchaseLocalizations", params={"limit": 200})["data"]:
    a = item["attributes"]
    print(f'{a["locale"]:8} {a["state"] if "state" in a else ""} {a["name"]} | {a["description"]}')
