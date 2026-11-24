/* Mac-only profiling no-ops; the camera pipeline's pixels are unchanged. */
#ifndef CFP_HOST_PROFILE_H
#define CFP_HOST_PROFILE_H
enum { P_SETUP,P_INPUT,P_DECODE,P_LOOK,P_ENCODE,P_WRITE,P_VERIFY,P_COUNT };
static inline unsigned profile_phase(unsigned next) { (void)next;return 0; }
static inline unsigned profile_enter(unsigned next) { (void)next;return 0; }
static inline void profile_leave(unsigned previous) { (void)previous; }
#endif
