#!/usr/bin/env python3
"""Release helper: the SideStore source and release notes for an iPad build.

    python3 ios/ci/make_source.py <OpenPad.ipa> <out dir>

Writes <out dir>/openpad-source.json (an AltStore-format source, which
SideStore reads) and <out dir>/notes.md, and prints the release tag. The
version, minimum iPadOS and permission prompts come from the build itself, so
SideStore's checks (size, SHA-256, version, permissions) match it. Refuses a
build whose version isn't the one the plugin, the Xcode project and
CHANGELOG.md have. Standard library only.
"""

import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO = "0w3n-N/openpad"
SOURCE_URL = f"https://github.com/{REPO}/releases/latest/download/openpad-source.json"
ICON = "https://0w3n-n.github.io/openpad/icon.png"
TINT = "#3a74eb"  # the app's accent color
ABOUT = ("Notes for iPad and Apple Pencil. Folders of notebooks with colored sections and titled pages; "
         "write on PDFs, scans and photos; search your handwriting. Notes live on the iPad, and the "
         "computer running OpenPad keeps a complete copy with a readable PDF of every section. "
         "The notebook you open can be shown live on the computer, for calls and guests.")


def read(*path):
    with open(os.path.join(ROOT, *path), encoding="utf-8") as f:
        return f.read()


def versions():
    """The version each part of OpenPad says it is."""
    return {
        "openpad/__init__.py": re.search(r'__version__ = "([^"]+)"', read("openpad", "__init__.py")).group(1),
        "manifest.json": json.loads(read("manifest.json"))["version"],
        "ios/project.yml": re.search(r'MARKETING_VERSION: "([^"]+)"', read("ios", "project.yml")).group(1),
    }


def changes(version):
    """CHANGELOG.md's section for a version, without its heading (None if missing)."""
    m = re.search(rf"^## {re.escape(version)}\b[^\n]*\n(.*?)(?=^## |\Z)", read("CHANGELOG.md"), re.M | re.S)
    return m.group(1).strip() if m else None


def unwrap(md):
    """Markdown with each paragraph and list item on one line: SideStore shows
    line breaks as they are, and CHANGELOG.md wraps at 80 columns."""
    out, fenced = [], False
    for line in md.splitlines():
        s = line.strip()
        if s.startswith("```"):
            fenced = not fenced
        joins = (not fenced and s and out and out[-1] and not s.startswith(("- ", "* ", "#", "```"))
                 and not out[-1].startswith(("#", "```")))
        if joins:
            out[-1] += " " + s
        else:
            out.append(line if fenced or s.startswith("```") else s)
    return "\n".join(out)


def info_plist(ipa):
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise ValueError("not an app build: expected one Payload/<name>.app/Info.plist")
        return plistlib.loads(z.read(names[0]))


def build(ipa, now=None):
    """(tag, source, notes) for an .ipa, or ValueError if it can't be released."""
    info = info_plist(ipa)
    version = info["CFBundleShortVersionString"]
    others = versions()
    if set(others.values()) != {version}:
        raise ValueError(f"the build is {version}, but " + ", ".join(f"{k} says {v}" for k, v in others.items()))
    notes = changes(version)
    if not notes:
        raise ValueError(f"CHANGELOG.md has no section for {version}")
    notes = unwrap(notes)
    with open(ipa, "rb") as f:
        data = f.read()
    tag = f"v{version}"
    url = f"https://github.com/{REPO}/releases/download/{tag}/OpenPad.ipa"
    date = (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    release = {
        "version": version,
        "buildVersion": info["CFBundleVersion"],
        "date": date,
        "localizedDescription": notes,
        "downloadURL": url,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    app = {
        "name": info.get("CFBundleDisplayName") or info["CFBundleName"],
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": "0w3n-N",
        "subtitle": "Notes for iPad and Apple Pencil",
        "localizedDescription": ABOUT,
        "iconURL": ICON,
        "tintColor": TINT,
        "category": "utilities",
        "versions": [release],
        # The build is unsigned, so it has no entitlements; SideStore adds its own when it signs.
        "appPermissions": {
            "entitlements": [],
            "privacy": {k: v for k, v in sorted(info.items()) if re.fullmatch(r"NS\w+UsageDescription", k)},
        },
        # The same release in the older single-version form, for older SideStore and AltStore.
        "version": version,
        "versionDate": date,
        "versionDescription": notes,
        "downloadURL": url,
        "size": len(data),
    }
    source = {
        "name": "OpenPad",
        "identifier": "io.github.0w3n-n.openpad.source",
        "version": 2,
        "subtitle": "Notes for iPad and Apple Pencil",
        "description": ABOUT,
        "iconURL": ICON,
        "website": f"https://github.com/{REPO}",
        "tintColor": TINT,
        "sourceURL": SOURCE_URL,
        "apps": [app],
        "news": [],
    }
    md = (f"{notes}\n\n"
          "### On the iPad\n\n"
          "`OpenPad.ipa` is unsigned: install it with SideStore, which signs it with your Apple ID. "
          "Add this source in SideStore to get each new version there:\n\n"
          f"```\n{SOURCE_URL}\n```\n\n"
          f"Setting up SideStore the first time: [ios/README.md](https://github.com/{REPO}/blob/{tag}/ios/README.md#sideloading-with-sidestore).\n\n"
          "### On the computer\n\n"
          "```\nomarchy plugin update io.github.0w3n-n.openpad\n```\n")
    return tag, source, md


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    ipa, out = sys.argv[1], sys.argv[2]
    try:
        tag, source, notes = build(ipa)
    except (ValueError, KeyError, zipfile.BadZipFile) as e:
        sys.exit(f"Can't release {ipa}: {e}")
    with open(os.path.join(out, "openpad-source.json"), "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    with open(os.path.join(out, "notes.md"), "w", encoding="utf-8") as f:
        f.write(notes)
    print(tag)


if __name__ == "__main__":
    main()
