# Bounded EOS 450D 1.1.0 SD-boot updater source

This directory contains the project-authored GPL-2.0-or-later source for the bounded EOS 450D / Rebel XSi (firmware 1.1.0) SD-boot updater and FAT16 boot-sector helper.

> [!WARNING]
> **Unverified recovery and power-loss risk:** First-time activation performs a persistent flash-sector erase/program operation to change the camera's boot setting. It is **not** power-loss-safe, and recovery after an interrupted activation or persistent deactivation remains **unverified**. Do not run a modified updater on hardware without understanding that an interrupted flash write can leave the camera unbootable.

> [!IMPORTANT]
> **Canon firmware licence and missing proprietary inputs:** Canon's EOS 450D 1.1.0 firmware end-user agreement expressly prohibits altering or modifying Canon's firmware/updater software. The GPL-2.0 licence on this project's source does not grant rights over Canon's code. This repository contains **no** Canon `.FIR`, decoded updater, or ROM binaries, and no private target/fingerprint bindings.

## Contents

- `body.c`, `wrapper.S`, `signatures.h`: Bounded ARM946E-S C/assembly payload and signature checks.
- `boot_sector.py`: Pure in-memory FAT16 `EOS_DEVELOP` / `BOOTDISK` sector transform and restore helper (no filesystem or device I/O).
- `build.py`: Synthetic-address (`0x500000`) compile check using `arm-none-eabi-gcc` (never creates an updater or `.FIR`).
- `finalize.py`: Places the compiled payload into a locally supplied `updater1.bin` using locally supplied `ROM01.BIN` and target/fingerprint JSON bindings.
- `model.py`: Unicorn-based offline emulator matrix for the linked updater body and native flash/cache/geometry boundaries.
- `package.py`: Applies the XOR updater delta to a locally supplied `450D_110.FIR`, recalculates the outer checksum, preserves encrypted main firmware bytes, and verifies against `inspect_450d_update.py` and `fir_tool2.py`.

## Prerequisites (not included)

No tool in this directory accepts a physical card or device destination. Running `finalize.py`, `model.py`, or `package.py` requires an `arm-none-eabi-gcc` toolchain plus the user's own local copies of:

- `450D_110.FIR` (SHA-256 `ec34d11815d85e013b0d73b5d754f27bd07b7812a9f3a960dae855eae686ddf4`)
- `updater1.bin` (SHA-256 `db1db77ede14cdd860a16a774a29925502a5fa6de7010430a6b4c49c4f5d1b09`)
- `ROM01.BIN` and the pinned target/fingerprint JSON bindings (`judge-fingerprint-proposal-v1.json`, `judge-installed-target-binding-v1.json`)
- `inspect_450d_update.py` and Magic Lantern's `fir_tool2.py`
