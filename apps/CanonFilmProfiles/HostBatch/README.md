# Mac batch helper

The Mac app builds and signs this portable C helper as part of `build_app.py`. The helper reads validated manifests and produces derivatives for the **Idle batch grain** tool. Source JPEGs are read-only. Export wanted output from its temporary run folder.

Use baseline 4:2:2 JPEGs with standard Huffman tables, width divisible by 16 and height divisible by 8. The codec rejects common 4:2:0 and progressive JPEGs.

The source directory contains the batch state machine, the adapter for bounded reads, and the prepared JPEG codec and grain implementation. The initial source inventory is recorded in the checkout's source manifest. The build records hashes of the source files it compiles and the app records the signed helper digest.

Build a standalone copy for inspection from this directory. The build directory must be new.

```sh
python3 build.py /tmp/canon-batch-local
/tmp/canon-batch-local/batch_host inspect batch/contract/golden.cbatch
```

The golden manifest is a wire-format fixture. Inspecting it requires no source photo. Run `BatchGrainChecks` from the app package with this manifest to compare C and Swift format expectations. The helper's source notices and [GPLv2 text](../../../COPYING) apply.
