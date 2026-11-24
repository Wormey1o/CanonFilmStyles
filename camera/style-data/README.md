# Camera Style data components

These portable modules come from the tested v3 Camera Styles workflow. The selection gate receives a sampled style, GUI activity flag, clock and caller-supplied eligibility flag. It waits for a qualifying slot selection to settle and allows one install attempt per boot. A deferred selection consumes no attempt.

The data loader accepts both supported sizes of the style file and copies it into a caller-owned buffer using read-only callbacks. It checks observed identity, exact length, and the end of the file. The caller validates file contents and decides what to do after the reader is closed.

Run the standalone tests with a C11 compiler.

```sh
cc -std=c11 -Wall -Wextra -Werror src/udtrig.c test/test_udtrig.c -o /tmp/canon-trigger-check
/tmp/canon-trigger-check
cc -std=c11 -Wall -Wextra -Werror -I src src/caller.c test/test_caller.c -o /tmp/canon-caller-check
/tmp/canon-caller-check
```

See the [Camera Styles guide](../../apps/CanonFilmProfiles/CAMERA_STYLES.md). These modules build on the host without camera dependencies.
