/* Native features and fixes added to the recompiled game at fixed x86 addresses. tools/lift.py lists them:
 *   HOOKS:     run before the instruction at the address (guest registers spilled to the context), then the original
 *              continues;
 *   OVERRIDES: at a function's first instruction; return 1 when the whole call (including the return) was done here,
 *              0 to run the original.
 * The DS1 port's hooks (draw distance, Skrit messages, shadows, paper doll, expansion) are the model for more. */
#include "w32.h"
#include "ext.h"

float w32_draw_distance = 1.0f;          /* DS_DRAW_DISTANCE (main.m); not applied to DS2 yet */

int vm_committed(uint32_t addr, uint32_t size);
static int readable(uint32_t p) { return p >= 0x10000 && vm_committed(p, 1); }
/* printf of a guest format string with guest cdecl arguments starting at stack address ap (%s %d %i %u %x %c %f %%) */
__attribute__((unused)) static void guest_format(char *out, size_t cap, uint32_t fmt, uint32_t ap)
{
    size_t n = 0; const char *f = (const char *)GP(fmt);
    for (; *f && n + 1 < cap; f++) {
        if (*f != '%') { out[n++] = *f; continue; }
        char spec[16] = "%"; int k = 1; f++;
        while (*f && strchr("-+ #0123456789.l", *f) && k < 12) spec[k++] = *f++;
        if (!*f) break;
        spec[k++] = *f; spec[k] = 0; int w = 0;
        switch (*f) {
        case 's': { uint32_t p = rt_r32(G_MEM, ap); ap += 4; w = snprintf(out + n, cap - n, spec, readable(p) ? (const char *)GP(p) : "(?)"); break; }
        case 'd': case 'i': case 'u': case 'x': case 'X': case 'c': w = snprintf(out + n, cap - n, spec, rt_r32(G_MEM, ap)); ap += 4; break;
        case 'f': case 'g': { double v; memcpy(&v, GP(ap), 8); ap += 8; w = snprintf(out + n, cap - n, spec, v); break; }
        case '%': out[n] = '%'; w = 1; break;
        default: w = 0;
        }
        if (w > 0) n += (size_t)w < cap - n ? (size_t)w : cap - n - 1;
    }
    out[n] = 0;
}
void rt_hook(Ctx *c, uint32_t addr)
{
    switch (addr) {
    default:   /* development trace hooks (tools/lift.py DS_TRACE_HOOKS) */
        if (getenv("DS_HOOKTRACE")) fprintf(stderr, "hook %08x: eax %08x ecx %08x edx %08x ebx %08x esi %08x edi %08x | ret %08x args %08x %08x %08x %08x\n",
                                            addr, c->eax, c->ecx, c->edx, c->ebx, c->esi, c->edi, rt_r32(G_MEM, c->esp), rt_r32(G_MEM, c->esp + 4),
                                            rt_r32(G_MEM, c->esp + 8), rt_r32(G_MEM, c->esp + 12), rt_r32(G_MEM, c->esp + 16));
        if (getenv("DS_HOOKTRACE") && atoi(getenv("DS_HOOKTRACE")) >= 2)   /* and 80 bytes at the first two stack arguments */
            for (int k = 1; k <= 2; k++) {
                uint32_t p = rt_r32(G_MEM, c->esp + 4 * (uint32_t)k); if (p < 0x10000) continue;
                fprintf(stderr, "   arg%d:", k); for (uint32_t j = 0; j < 80; j++) fprintf(stderr, " %02x", G_MEM[p + j]); fprintf(stderr, "\n");
            }
    }
}

/* UIFrontend::TransitionToMain (0x44c2d3) ends by disabling the main menu's Multiplayer button: the GOG 2.3 release
 * shipped without multiplayer (its online service, GameSpy, is gone). The native build plays LAN and internet games
 * itself (dpnet.c), so that one call (returning to 0x44c37f) is skipped; DS2_NO_MULTIPLAYER=1 keeps the original. */
static int keep_multiplayer_button(Ctx *c)
{
    static int off = -1; if (off < 0) off = getenv("DS2_NO_MULTIPLAYER") != 0;
    if (off || rt_r32(G_MEM, c->esp) != 0x0044c37fu) return 0;
    c->esp += 4;                                          /* thiscall, no arguments: just the return */
    return 1;
}
int rt_override(Ctx *c, uint32_t addr)
{
    switch (addr) {
    case 0x007663b0u: return keep_multiplayer_button(c);
    }
    return 0;
}
