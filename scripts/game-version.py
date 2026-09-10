#!/usr/bin/env python3
"""Print the Necesse game version baked into a Server.jar (for example ``1.3.3``).

The dedicated server has no version file and no manifest attribute; the version lives as a string
constant in ``necesse/engine/GameInfo.class`` (the class that prints "Loading dedicated server on
version X.Y.Z" at startup). This script reads that class straight out of the jar, walks its
constant pool and returns the one bare ``<major>.<minor>[.<patch>]`` constant it holds, after
checking that the matching ``Version X.Y.Z`` constant is there too. Anything other than exactly one
candidate is an error: the publish workflow then refuses to push game-version tags rather than guess.

Usage: game-version.py <path to Server.jar>
Exit codes: 0 = version printed on stdout; 1 = jar/class unreadable or no unambiguous version.
"""

import re
import struct
import sys
import zipfile

GAME_INFO_CLASS = "necesse/engine/GameInfo.class"
VERSION_RE = re.compile(r"\d+\.\d+(?:\.\d+)?")

# Constant pool tags and the size of their payload (after the tag byte). Long/Double take two slots.
_FIXED_SIZE = {3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}


def utf8_constants(class_bytes):
    """Return every CONSTANT_Utf8 entry of a class file's constant pool, in order."""
    if class_bytes[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("not a Java class file")
    (count,) = struct.unpack(">H", class_bytes[8:10])
    pos, index, out = 10, 1, []
    while index < count:
        tag = class_bytes[pos]
        if tag == 1:
            (length,) = struct.unpack(">H", class_bytes[pos + 1 : pos + 3])
            out.append(class_bytes[pos + 3 : pos + 3 + length].decode("utf-8", "replace"))
            pos += 3 + length
        elif tag in _FIXED_SIZE:
            pos += 1 + _FIXED_SIZE[tag]
            if tag in (5, 6):
                index += 1
        else:
            raise ValueError("unknown constant pool tag %d" % tag)
        index += 1
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    jar_path = argv[1]
    try:
        with zipfile.ZipFile(jar_path) as jar:
            constants = utf8_constants(jar.read(GAME_INFO_CLASS))
    except (OSError, zipfile.BadZipFile, KeyError, ValueError) as exc:
        print("game-version: cannot read %s from %s: %s" % (GAME_INFO_CLASS, jar_path, exc), file=sys.stderr)
        return 1

    candidates = sorted({c for c in constants if VERSION_RE.fullmatch(c)})
    if len(candidates) != 1:
        print(
            "game-version: expected exactly one bare version constant in %s, found %d: %s"
            % (GAME_INFO_CLASS, len(candidates), ", ".join(candidates) or "none"),
            file=sys.stderr,
        )
        return 1
    version = candidates[0]
    if "Version %s" % version not in constants:
        print(
            "game-version: found %s but not the matching 'Version %s' constant; the class layout changed, refusing to guess"
            % (version, version),
            file=sys.stderr,
        )
        return 1
    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
