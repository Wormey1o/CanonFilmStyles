# Source notices and credits

Canon Film Look project-authored source is licensed under the GNU General Public License, version 2 only. See [COPYING](COPYING). Third-party material retains its own notices.

- The C film renderer builds on [Soup Engine](https://github.com/jiijii0/soup-engine) by jiijii0 and contributors. Adaptations preserve upstream notices. Relevant files carry GPL-2.0-only or GPL-2.0-or-later headers.
- The Mac batch helper and portable camera Style data source carry GPL-2.0-only notices. The batch helper's SHA-256 implementation is public-domain code from Igor Pavlov, based on public-domain Crypto++ code by Wei Dai.
- `camera/sdboot-installer` contains project-authored GPL-2.0-or-later C, ARM assembly, and Python source for the bounded EOS 450D 1.1.0 SD-boot updater and FAT16 boot-marker helper. It includes no Canon `.FIR`, updater, or ROM binaries; Canon's 450D firmware agreement restricts modification of Canon's own firmware/updater files.
- Chrizz Ocampo's Portra 160 is credited in its starter recipe. The importer is designed to read [Ricoh Cookbook](https://ricohcookbook.com/) recipe cards and retain visible attribution. Recipe card artwork and photographs are supplied by the user.
- `Resources/CFLOOKS.BIN` is the project's data table of compiled film looks. The bundled calibration JSON contains derived colour and tone measurements. The source snapshot includes those data tables and the project app assets.
- Canon and Ricoh products are named for compatibility. The app obtains the compatible Picture Style converter from the user's local Canon installation. The release contains no Canon installer, ROM or firmware binary.

See the per-file notices and the [GNU GPL version 2 text](COPYING) for the applicable inherited terms.
