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

**Camera styles** maps recipes to Canon User Def. slots. Choose **Export for EOS Utility…** to generate colour Picture Styles and a manual slot guide. Building registered colour records for the optional extension card file uses an arm64-compatible converter from a separate EOS Utility or Picture Style Editor installation. Follow the [Camera Styles guide](apps/CanonFilmProfiles/CAMERA_STYLES.md) for compatibility, exports and setup. Use **Copy to card** to update and eject an already provisioned compatible card. Fresh-card extension setup requires a separate camera activation and is outside this release. Effects card installation and experimental native boot package export require the separate maintainer camera resources.

## Develop

- `apps/CanonFilmProfiles/Sources/CanonFilmProfiles` houses the SwiftUI app.
- `apps/CanonFilmProfiles/Sources/ProfileCore` houses recipes, effects, output formats and Camera Styles calculations.
- `apps/CanonFilmProfiles/Sources/RecipeCardImport` reads and parses recipe cards.
- `apps/CanonFilmProfiles/Sources/FilmProfileEngine` contains the C renderer and JPEG/CR2 preview code.
- The [Mac batch helper](apps/CanonFilmProfiles/HostBatch/README.md) uses portable C and runs in a separate process.
- The [camera Style data components](camera/style-data/README.md) contain two portable modules from the tested camera route and their host tests.

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
