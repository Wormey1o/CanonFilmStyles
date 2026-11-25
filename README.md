# Canon Film Look

Canon Film Look is an unsupported community project for experimenting with film recipes on a Mac and using Canon Picture Styles on an EOS 450D or Rebel XSi. The app is called **Canon Film Profiles**.

## Build and use

You need macOS 14 or later, Python 3.10 or later, and Apple's Xcode Command Line Tools. The package was tested on Apple silicon.

```sh
cd apps/CanonFilmProfiles
python3 build_app.py
open "dist/Canon Film Profiles 0.6.4.app"
```

The script builds Swift and C source and signs the bundle locally. It creates a fresh bundle and keeps existing ones. In the app, create a recipe or import a recipe card. Choose **Open photo…** to preview the look on a JPEG or supported 450D CR2 preview. Use **Export** for recipe files and LUTs. Open **Native processing → Idle batch grain** to process copies of local JPEGs on the Mac.

## Put a look on a stock EOS 450D

1. In **Canon Film Profiles** on your Mac, open **Camera styles** and assign a colour recipe to **User Def. 1**. Click **Export for EOS Utility…** to save `User Def. 1.pf2` to your Mac.
2. Connect the camera by USB to a computer that runs Canon's EOS Utility for the 450D. In EOS Utility, load the file into the camera's **User Def. 1** slot.
3. Select **User Def. 1** in the camera's **Picture Style** menu and take a JPEG. Use `SLOTS.txt` for white balance and for built-in Monochrome recipes you enter by hand.

> **What a Picture Style carries:** `.pf2` files carry a Canon colour and tone translation. White balance mode and shift are entered by hand and do not follow stock slot changes. Built-in Monochrome is entered by hand. Grain, clarity, and shading stay outside the Picture Style workflow.

[Step-by-step Camera Styles setup and Canon software requirements](apps/CanonFilmProfiles/CAMERA_STYLES.md#put-your-first-look-on-a-stock-450d)

**Already have the Camera Styles extension?** Use **Copy to card** to update recipes on its prepared card. Building registered colour records for that card uses the converter from a separate, compatible Canon installation. Returning to ordinary shooting with a known-good ordinary card is verified on the tested 450D body, while persistent deactivation and recovery after interrupted activation remain unverified. Effects card installation and experimental native boot package export require the separate maintainer camera resources.

## Develop

- `apps/CanonFilmProfiles/Sources/CanonFilmProfiles` houses the SwiftUI app.
- `apps/CanonFilmProfiles/Sources/ProfileCore` houses recipes, effects, output formats and Camera Styles calculations.
- `apps/CanonFilmProfiles/Sources/RecipeCardImport` reads and parses recipe cards.
- `apps/CanonFilmProfiles/Sources/FilmProfileEngine` contains the C renderer and JPEG/CR2 preview code.
- The [Mac batch helper](apps/CanonFilmProfiles/HostBatch/README.md) uses portable C and runs in a separate process.
- The [camera Style data components](camera/style-data/README.md) contain two portable modules from the tested camera route and their host tests.
- The [SD-boot updater source](camera/sdboot-installer/README.md) contains the project-authored GPL-2.0-or-later source for the bounded 450D 1.1.0 updater and FAT16 boot-marker helper (no Canon binaries or private bindings; Canon firmware licence restrictions and unverified interrupted-activation recovery apply).

Portable checks can run directly from the app directory.

```sh
swift run -c release ProfileChecks
swift run -c release RecipeCardChecks
swift run -c release LUTExportChecks "$PWD"
swift run -c release NativeRecipeChecks
swift run -c release BatchGrainChecks HostBatch/batch/contract/golden.cbatch
```

`SOURCE_MANIFEST.json` inventories the staged source snapshot. Build locally after changing files. The source can be explored and modified with the editor and developer tools you already use.

## Credits

Thanks to the photography and camera software communities whose recipes, research and code made this possible. [Source notices and credits](NOTICE.md) · [GPLv2 text](COPYING)
