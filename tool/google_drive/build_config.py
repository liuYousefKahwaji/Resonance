"""Write OAuth build defines from CI env without logging credential values."""
import argparse
import json
import os
from pathlib import Path

KEYS = (
    "GOOGLE_DRIVE_WINDOWS_CLIENT_ID",
    "GOOGLE_DRIVE_WINDOWS_CLIENT_SECRET",
    "GOOGLE_DRIVE_ANDROID_SERVER_CLIENT_ID",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    values = {key: os.environ.get(key, "").strip() for key in KEYS}
    if bool(values[KEYS[0]]) != bool(values[KEYS[1]]):
        raise SystemExit("Set both Windows Google OAuth client fields, or leave both empty.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(values), encoding="utf-8")
    args.output.chmod(0o600)
    print("Google Drive build configuration written; values are not logged.")


if __name__ == "__main__":
    main()
