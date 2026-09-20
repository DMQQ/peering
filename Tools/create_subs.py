#!/usr/bin/env python3
"""
Creates all subscription products from Products.storekit in App Store Connect.
Requires an API key with App Manager role.

Usage:
    python3 Tools/create_subs.py --issuer-id <UUID> --key-id <KEY_ID> --key-path <path.p8> --app-id <APP_ID>

    # Or via env vars:
    ASC_ISSUER_ID=... ASC_KEY_ID=... ASC_KEY_PATH=... ASC_APP_ID=... python3 Tools/create_subs.py

Dependencies:
    pip3 install PyJWT cryptography requests
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

try:
    import jwt
    import requests
except ImportError:
    print("Run: pip3 install PyJWT cryptography requests")
    sys.exit(1)

STOREKIT_PATH = Path(__file__).parent.parent / "Config" / "Products.storekit"
BASE = "https://api.appstoreconnect.apple.com/v1"

PERIOD_MAP = {
    "P1W": "ONE_WEEK",
    "P1M": "ONE_MONTH",
    "P2M": "TWO_MONTHS",
    "P3M": "THREE_MONTHS",
    "P6M": "SIX_MONTHS",
    "P1Y": "ONE_YEAR",
}

# Map display price (USD) to App Store price tier number.
# Tier IDs are opaque strings in the pricePoints API; we match by customerPrice instead.
DISPLAY_PRICE_USD = {
    "pl.dmq.peering.iap.relay.monthly":  "3.99",
    "pl.dmq.peering.iap.relay.year":     "29.99",
    "pl.dmq.peering.iap.plus.monthly":   "7.99",
    "pl.dmq.peering.iap.plus.year":      "59.99",
    "pl.dmq.peering.iap.pro.monthly":    "12.99",
    "pl.dmq.peering.iap.pro.year":       "99.99",
}


def make_token(issuer_id, key_id, key_path):
    key = Path(key_path).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id},
    )


def api(method, path, token, body=None, params=None):
    resp = requests.request(
        method, BASE + path,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=body, params=params,
    )
    if resp.status_code == 204:
        return {}
    data = resp.json()
    if resp.status_code >= 400:
        err = data.get("errors", [{}])[0]
        print(f"    API ERROR {resp.status_code}: {err.get('detail', err.get('title', resp.text[:200]))}")
        return None
    return data


def create_group(token, app_id, name):
    print(f"Creating subscription group '{name}'...")
    result = api("POST", "/subscriptionGroups", token, {"data": {
        "type": "subscriptionGroups",
        "attributes": {"referenceName": name},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    if result:
        gid = result["data"]["id"]
        print(f"  Group created: {gid}")
        return gid
    return None


def create_subscription(token, group_id, sub):
    pid    = sub["productID"]
    period = PERIOD_MAP[sub["recurringSubscriptionPeriod"]]
    name   = sub["referenceName"]
    print(f"  Creating '{name}' ({pid}, {period})...")

    result = api("POST", "/subscriptions", token, {"data": {
        "type": "subscriptions",
        "attributes": {
            "productId":          pid,
            "name":               name,
            "subscriptionPeriod": period,
            "familySharable":     sub.get("familyShareable", False),
            "reviewNote":         "",
            "groupLevel":         sub.get("groupNumber", 1),
        },
        "relationships": {"group": {"data": {"type": "subscriptionGroups", "id": group_id}}},
    }})
    if not result:
        return None
    sub_id = result["data"]["id"]
    print(f"    Created: {sub_id}")
    return sub_id


def add_localization(token, sub_id, pid, loc):
    result = api("POST", "/subscriptionLocalizations", token, {"data": {
        "type": "subscriptionLocalizations",
        "attributes": {
            "locale":      loc["locale"].replace("_", "-"),
            "name":        loc["displayName"],
            "description": loc.get("description", ""),
        },
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub_id}}},
    }})
    if result is not None:
        print(f"    Localization ({loc['locale']}): OK")


def set_price(token, sub_id, pid):
    target_usd = DISPLAY_PRICE_USD.get(pid)
    if not target_usd:
        print(f"    No price configured for {pid}, skipping")
        return

    # Fetch price points for USA territory
    points = api("GET", f"/subscriptions/{sub_id}/pricePoints",
                 token, params={"filter[territory]": "USA", "limit": 200})
    if not points:
        return

    point_id = None
    for pt in points.get("data", []):
        # customerPrice looks like "$3.99"
        customer = pt["attributes"].get("customerPrice", "").lstrip("$").lstrip("US$").strip()
        if customer == target_usd:
            point_id = pt["id"]
            break

    if not point_id:
        print(f"    Could not find price point for ${target_usd} — set price manually in ASC")
        return

    result = api("POST", "/subscriptionPrices", token, {"data": {
        "type": "subscriptionPrices",
        "attributes": {"startDate": None, "preserveCurrentPrice": False},
        "relationships": {
            "subscription":           {"data": {"type": "subscriptions",       "id": sub_id}},
            "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": point_id}},
            "territory":              {"data": {"type": "territories", "id": "USA"}},
        },
    }})
    if result is not None:
        print(f"    Price ${target_usd}: OK")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"))
    parser.add_argument("--key-id",    default=os.environ.get("ASC_KEY_ID",    "YFJNLCD96P"))
    parser.add_argument("--key-path",  default=os.environ.get("ASC_KEY_PATH",  "/Users/dmq/Downloads/AuthKey_YFJNLCD96P.p8"))
    parser.add_argument("--app-id",    default=os.environ.get("ASC_APP_ID",    "6812658408"))
    parser.add_argument("--group-id",  default=os.environ.get("ASC_GROUP_ID"),
                        help="Reuse an existing group ID instead of creating a new one")
    args = parser.parse_args()

    if not args.issuer_id:
        print("ERROR: --issuer-id required (or ASC_ISSUER_ID env var)")
        sys.exit(1)

    storekit = json.loads(STOREKIT_PATH.read_text())
    token    = make_token(args.issuer_id, args.key_id, args.key_path)

    for group in storekit["subscriptionGroups"]:
        if args.group_id:
            group_id = args.group_id
            print(f"Reusing group {group_id}")
        else:
            group_id = create_group(token, args.app_id, group["name"])
            if not group_id:
                sys.exit(1)

        subs_sorted = sorted(group["subscriptions"],
                             key=lambda s: (s["groupNumber"], s["recurringSubscriptionPeriod"]))
        for sub in subs_sorted:
            sub_id = create_subscription(token, group_id, sub)
            if not sub_id:
                continue
            for loc in sub.get("localizations", []):
                add_localization(token, sub_id, sub["productID"], loc)
            set_price(token, sub_id, sub["productID"])

    print("\nDone. Review in App Store Connect > Monetization > Subscriptions.")


if __name__ == "__main__":
    main()
