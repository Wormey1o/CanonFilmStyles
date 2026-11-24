/* Host unit test of udtrig.c (cc -Wall -Wextra -Werror). Rate 100 ticks/s, 20 ms worker loop. */
#include "../src/udtrig.h"
#include <stdio.h>
#include <string.h>
static int fails;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)
static uint32_t now;
static uint32_t run(ud_trigger *t, uint32_t style, uint32_t dialog, uint32_t elig, uint32_t ticks)
{   /* step every 2 ticks for `ticks`; return the first nonzero result */
    uint32_t r = 0;
    for (uint32_t i = 0; i < ticks; i += 2) { uint32_t x = ud_trigger_step(t, style, dialog, elig, now, 100); if (x && !r) r = x; now += 2; }
    return r;
}
int main(void)
{
    ud_trigger t;
    /* 1. boot on User Def. 1: no trigger however long */
    memset(&t, 0, sizeof t); now = 1000;
    CHECK(run(&t, 0x21, 0, 1, 1000) == 0 && !t.attempted);
    /* 2. boot on Standard, menu open, select UD1: fires after 1 s, once, slot 0x21 */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 0, 1, 200); run(&t, 0x81, 1, 1, 50);
    CHECK(run(&t, 0x21, 1, 1, 98) == 0);          /* < 1 s held */
    CHECK(run(&t, 0x21, 1, 1, 10) == 0x21 && t.attempted && t.slot == 0x21);
    CHECK(run(&t, 0x22, 1, 1, 400) == 0 && run(&t, 0x21, 1, 1, 400) == 0);   /* at most one per boot */
    /* 3. change made without a dialog (e.g. remote/property): not GUI, no trigger */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 0, 1, 300);
    CHECK(run(&t, 0x22, 0, 1, 400) == 0 && t.not_gui == 1 && !t.attempted);
    /* 4. dialog closed 0.9 s before the change still counts (within 1 s); 1.2 s does not */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 1, 1, 20); run(&t, 0x81, 0, 1, 90);
    CHECK(run(&t, 0x23, 0, 1, 200) == 0x23);
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 1, 1, 20); run(&t, 0x81, 0, 1, 120);
    CHECK(run(&t, 0x23, 0, 1, 200) == 0 && t.not_gui == 1);
    /* 5. slot left within 1 s: cancelled, no attempt; next GUI selection triggers */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 1, 1, 20);
    CHECK(run(&t, 0x21, 1, 1, 50) == 0 && run(&t, 0x81, 1, 1, 50) == 0 && t.cancelled == 1 && !t.attempted);
    CHECK(run(&t, 0x22, 1, 1, 200) == 0x22);
    /* 6. ineligible (Live View / basic zone): deferred, not an attempt; next eligible selection fires */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x81, 1, 0, 20);
    CHECK(run(&t, 0x21, 1, 0, 300) == 0 && t.deferred == 1 && !t.attempted);
    CHECK(run(&t, 0x21, 1, 1, 300) == 0);          /* staying on the slot does not re-arm */
    CHECK(run(&t, 0x22, 1, 0, 300) == 0 && t.deferred == 2);
    CHECK(run(&t, 0x21, 1, 1, 300) == 0x21 && t.attempted);
    /* 7. a non-UD change (Standard) never arms */
    memset(&t, 0, sizeof t); now = 1000;
    run(&t, 0x21, 1, 1, 20);
    CHECK(run(&t, 0x81, 1, 1, 400) == 0 && !t.pending && !t.attempted);
    /* 8. tick wrap-around */
    memset(&t, 0, sizeof t); now = 0xffffff00u;
    run(&t, 0x81, 1, 1, 100);
    CHECK(run(&t, 0x23, 1, 1, 200) == 0x23);
    /* 9. bad rate: inert */
    memset(&t, 0, sizeof t);
    CHECK(ud_trigger_step(&t, 0x21, 1, 1, 5, 10) == 0 && !t.init);
    printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
    return fails != 0;
}
