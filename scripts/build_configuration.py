"""Validate the fork's Telegram API credentials without starting a build."""
import argparse
import json
import os
from pathlib import Path
import re


def api_credentials(environment):
    api_id = environment.get("TELEGRAM_API_ID", "").strip()
    api_hash = environment.get("TELEGRAM_API_HASH", "").strip()
    if not api_id or not api_hash:
        raise ValueError(
            "Set both TELEGRAM_API_ID and TELEGRAM_API_HASH from "
            "https://my.telegram.org/apps. Official Telegram iOS credentials "
            "cannot be used as defaults for a re-signed fork."
        )
    if not re.fullmatch(r"[0-9]+", api_id) or not 0 < int(api_id) <= 2147483647:
        raise ValueError("TELEGRAM_API_ID must be a positive 32-bit integer.")
    if int(api_id) == 8:
        raise ValueError(
            "TELEGRAM_API_ID belongs to official Telegram iOS. "
            "Use your own application credentials from https://my.telegram.org/apps."
        )
    if not re.fullmatch(r"[0-9a-fA-F]{32}", api_hash):
        raise ValueError("TELEGRAM_API_HASH must contain 32 hexadecimal characters.")
    return str(int(api_id)), api_hash.lower()


def load_build_configuration(source, environment):
    api_id, api_hash = api_credentials(environment)
    configuration = json.loads(
        (source / "build-system/appstore-configuration.json").read_text(encoding="utf-8")
    )
    configuration.update({
        "bundle_id": "com.itzchelove4ik.exteragram.lite",
        "team_id": "EXTERAGRAM",
        "is_internal_build": "false",
        "is_appstore_build": "false",
        "app_specific_url_scheme": "exteragram",
        "enable_siri": False,
        "enable_icloud": False,
        "api_id": api_id,
        "api_hash": api_hash,
    })
    return configuration


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", required=True,
                        help="Check API credentials only; do not build or write files")
    parser.parse_args()
    try:
        api_credentials(os.environ)
    except ValueError as error:
        parser.exit(1, f"API configuration error: {error}\n")
    print("Telegram API credentials are configured for the fork.")


if __name__ == "__main__":
    main()
