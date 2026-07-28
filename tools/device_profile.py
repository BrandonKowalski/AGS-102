#!/usr/bin/env python3
"""Read and validate BaseOS H700 device profiles."""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROFILES = ROOT / "devices.json"
REQUIRED_FIELDS = {
    "id",
    "model",
    "stockmod_prefix",
    "baseos_device",
    "model_string",
    "bootlogo_width",
    "bootlogo_height",
    "panel_rotation_ccw",
    "wifi",
    "bluetooth",
}
# Counter-clockwise angle the splash is turned through to land upright on a panel
# that is mounted turned relative to how the device is held. Named for the
# operation rather than the mounting so the direction cannot be read backwards:
# the RG28XX needs 90, matching the vendor bootlogo (see docs/04-boot-splash.md).
PANEL_ROTATIONS = (0, 90, 180, 270)


def die(message: str) -> "None":
    raise SystemExit(f"device-profile: {message}")


def load_profiles(path: Path = DEFAULT_PROFILES) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        die(f"cannot read {path}: {error}")
    if data.get("schema") != 1 or not isinstance(data.get("targets"), list):
        die(f"unsupported profile schema in {path}")

    targets = data["targets"]
    ids: set[str] = set()
    prefixes: set[str] = set()
    for profile in targets:
        missing = REQUIRED_FIELDS - profile.keys()
        if missing:
            die(f"profile is missing {', '.join(sorted(missing))}")
        target = profile["id"]
        if not target or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789" for c in target):
            die(f"invalid target id: {target!r}")
        if target in ids:
            die(f"duplicate target id: {target}")
        prefix = profile["stockmod_prefix"].upper()
        if prefix in prefixes:
            die(f"duplicate StockMod prefix: {prefix}")
        # Optional extra substring that also identifies this target's firmware,
        # for images that arrive hand-named rather than as a vendor release.
        alias = profile.get("filename_alias")
        if alias is not None:
            if not isinstance(alias, str) or not alias.strip():
                die(f"{target}: filename_alias must be a non-empty string")
            if alias.upper() in prefixes:
                die(f"duplicate filename alias: {alias}")
            prefixes.add(alias.upper())
        if not isinstance(profile["wifi"], bool) or not isinstance(profile["bluetooth"], bool):
            die(f"{target}: capability values must be booleans")
        for key in ("bootlogo_width", "bootlogo_height"):
            if not isinstance(profile[key], int) or profile[key] <= 0:
                die(f"{target}: {key} must be a positive integer")
        if profile["panel_rotation_ccw"] not in PANEL_ROTATIONS:
            expected = ", ".join(str(angle) for angle in PANEL_ROTATIONS)
            die(f"{target}: panel_rotation_ccw must be one of: {expected}")
        ids.add(target)
        prefixes.add(prefix)
    return targets


def get_profile(target: str, path: Path = DEFAULT_PROFILES) -> dict:
    for profile in load_profiles(path):
        if profile["id"] == target:
            return profile
    known = " ".join(profile["id"] for profile in load_profiles(path))
    die(f"unknown target {target!r}; expected one of: {known}")


def matches_profile(filename: str, profile: dict) -> bool:
    """Is this firmware filename this target's?

    Vendor and StockMod releases alike are named `<MODEL>-...`, which the
    stockmod_prefix pins. `filename_alias` is an escape hatch for images that
    arrive hand-named -- someone's own dump of a card, say -- and is expected to
    become unnecessary once an official release exists for the target.
    """
    upper = filename.upper()
    if upper.startswith(profile["stockmod_prefix"].upper()):
        return True
    alias = profile.get("filename_alias")
    return bool(alias) and alias.upper() in upper


def find_image(directory: Path, profile: dict) -> Path:
    if not directory.is_dir():
        die(f"firmware directory does not exist: {directory}")
    matches = sorted(
        path.resolve()
        for path in directory.iterdir()
        if path.is_file()
        and path.suffix.lower() == ".img"
        and matches_profile(path.name, profile)
    )
    if not matches:
        die(f"{profile['id']}: no {profile['stockmod_prefix']}*.img in {directory}")
    if len(matches) != 1:
        names = ", ".join(path.name for path in matches)
        die(f"{profile['id']}: ambiguous firmware images: {names}")
    return matches[0]


def shell_profile(profile: dict) -> None:
    mapping = {
        "PROFILE_TARGET": profile["id"],
        "PROFILE_MODEL": profile["model"],
        "PROFILE_STOCKMOD_PREFIX": profile["stockmod_prefix"],
        "PROFILE_BASEOS_DEVICE": profile["baseos_device"],
        "PROFILE_MODEL_STRING": profile["model_string"],
        "PROFILE_BOOTLOGO_WIDTH": profile["bootlogo_width"],
        "PROFILE_BOOTLOGO_HEIGHT": profile["bootlogo_height"],
        "PROFILE_PANEL_ROTATION_CCW": profile["panel_rotation_ccw"],
        "PROFILE_WIFI": int(profile["wifi"]),
        "PROFILE_BLUETOOTH": int(profile["bluetooth"]),
    }
    for key, value in mapping.items():
        print(f"{key}={shlex.quote(str(value))}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiles", type=Path, default=DEFAULT_PROFILES)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list")
    shell_parser = subparsers.add_parser("shell")
    shell_parser.add_argument("target")
    find_parser = subparsers.add_parser("find")
    find_parser.add_argument("directory", type=Path)
    find_parser.add_argument("target")
    arguments = parser.parse_args()

    if arguments.command == "list":
        print(" ".join(profile["id"] for profile in load_profiles(arguments.profiles)))
    elif arguments.command == "shell":
        shell_profile(get_profile(arguments.target, arguments.profiles))
    elif arguments.command == "find":
        print(find_image(arguments.directory, get_profile(arguments.target, arguments.profiles)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.exit(0)
