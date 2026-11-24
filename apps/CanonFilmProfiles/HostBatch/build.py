#!/usr/bin/env python3
"""Build the Mac host helper using the portable files in this checkout."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
CORE = "batch/core"
ENGINE = "image"
READER = "storage/native-readonly/read511-v1"
STORAGE = "storage/storage"
SOURCES = (
    "batch/host/batch_host.c",
    f"{CORE}/batch.c",
    f"{ENGINE}/codec/codec.c",
    f"{ENGINE}/quality/quality_core.c",
    f"{READER}/read511.c",
    f"{STORAGE}/sha256.c",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scratch", type=Path, help="new build directory")
    args = parser.parse_args()
    scratch = args.scratch.resolve()
    scratch.mkdir()

    flags = ["-std=c11", "-O2", "-g", "-fwrapv"]
    includes = [CORE, f"{ENGINE}/codec", f"{ENGINE}/quality", READER, STORAGE]
    command = ["/usr/bin/clang", *flags, *[f"-I{ROOT / directory}" for directory in includes]]
    obj = str(scratch / "batch_host.o")
    built = scratch / "batch_host"
    subprocess.run([*command, "-Wall", "-Wextra", "-Werror", "-c", str(ROOT / SOURCES[0]), "-o", obj], check=True)
    subprocess.run([*command, obj, *[str(ROOT / src) for src in SOURCES[1:]], "-o", str(built)], check=True)

    source_pins = {}
    for directory in ("batch", ENGINE, "storage"):
        for file in sorted((ROOT / directory).rglob("*")):
            if file.is_file() and file.suffix in (".c", ".h", ".inc"):
                source_pins[file.relative_to(ROOT).as_posix()] = sha256(file.read_bytes()).hexdigest()
    (scratch / "source-pins.json").write_text(json.dumps({
        "compiler": subprocess.check_output(["/usr/bin/clang", "--version"], text=True).splitlines()[0],
        "compilerFlags": flags,
        "license": "GPL-2.0-only",
        "licenseFile": "COPYING",
        "hostSources": source_pins,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(built)


if __name__ == "__main__":
    main()
