/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef NRO_ADAPTER_H
#define NRO_ADAPTER_H
#include <stdint.h>
#include "../storage/readonly.h"
#define NRO_DIAGNOSTIC_CONTRACT 0x44524f31u
#define NRO_DMA ((uint8_t *)(uintptr_t)0x1017a000u)
#define NRO_IO_BYTES 8192u
enum {NRO_OPEN=1,NRO_STAT,NRO_SEEK,NRO_READ,NRO_CLOSE};
typedef struct {
 uint32_t in_call,call_kind,sequence,returns,unsafe,owned_mask,close_mask;
 int32_t raw;
} nro_observation;
typedef struct {
 void *ctx;uint32_t contract,generation,wrapper,entry,stack_bytes,deadline_ticks;
 /* Restricted existing-file diagnostic predicate, NOT generic power/timer
  * leases. CPU-only. cleanup1 may allow known drain after admission closes. */
 int (*operating)(void *,uint32_t cleanup);
 /* Required independently qualified native no-consumer witness. Neither
  * in_call0, a returned service, time elapsed nor operator policy invents it. */
 int (*quiescent)(void *,const nro_observation *);
} nro_policy;
typedef struct {int fd;uint32_t position,opened,close_attempted,entry,open,shared;} nro_slot;
typedef struct {
 uint32_t magic,rate,started,last_yield,cancel,error,stack_low,stack_high;
 uint32_t yields,yield_ticks,domain_samples,domain_error;
 uint32_t volume,cache,sd,drivers,driver_count,fds,fd_count,opens,open_count,shared;
 nro_policy policy;nro_observation observation;nro_slot slot[2];
 uint32_t stat[32];
} nro_adapter;
/* zero-init once. Nil operating/quiescent adapters refuse before native FIO.
 * Caller retains this context, exclusive DMA, worker/stack and immutable policy
 * through known drain; no free/rearm/unknown-positive-close capability. */
int nro_init(nro_adapter *,const nro_policy *);
yr_ops nro_operations(nro_adapter *);
void nro_cancel(nro_adapter *);
const yr_job *nro_pinned_job(void);
int nro_context(nro_adapter *);
int nro_domain(nro_adapter *);
#endif
