/* TrapGunnerRecomp — netplay host-simulation catalog (vanilla title policy).
 *
 * psxrecomp refuses online/LAN play unless the title registers a trusted
 * host qualification catalog (runtime/include/netplay_host_catalog.h). This
 * file declares one portable profile for the unmodified game: both peers must
 * run the *same* executable (the framework separately checks build, BIOS,
 * disc and config identity), on arm64 or x64, with the framework's compiled
 * simulation backend. Bump TG_HOST_PROFILE_REVISION whenever a change could
 * alter deterministic simulation across hosts.
 *
 * Validated: two local instances (127.0.0.1 UDP, rollback) on macOS arm64.
 * SPDX-License-Identifier: MIT
 */
#include "netplay_host_catalog.h"
#include "netplay_host_profile.h"
#include <string.h>

#define TG_HOST_PROFILE_NAME     "trapgunner-vanilla"
#define TG_HOST_PROFILE_REVISION 1u

static PSXHostProfileRule tg_rule;

static int tg_host_profiles(const PSXModNetplayHostStartup *ctx, PSXHostProfileCatalog *out)
{
    /* Qualification tag: fixed 32-byte id for "Trap Gunner SLUS-00679 vanilla
     * rev 1". It is local policy, never accepted from a peer. */
    static const uint8_t qual[32] = {
        'T','G','R','C','-','S','L','U','S','-','0','0','6','7','9','-',
        'v','a','n','i','l','l','a','-','r','e','v','0','0','0','0','1' };
    if (!ctx || !out) return 0;
    memset(&tg_rule, 0, sizeof tg_rule);
    strncpy(tg_rule.profile, TG_HOST_PROFILE_NAME, sizeof tg_rule.profile - 1);
    tg_rule.revision = TG_HOST_PROFILE_REVISION;
    tg_rule.priority = 1;
    tg_rule.flags = PSX_HOST_PROFILE_PORTABLE;
    memcpy(tg_rule.qualification, qual, sizeof qual);
    tg_rule.implementation_count = 1;
    tg_rule.implementations[0].backend = ctx->compiled_backends;
    tg_rule.implementations[0].architectures =
        (1u << PSX_HOST_ARCH_ARM64) | (1u << PSX_HOST_ARCH_X64);
    tg_rule.implementations[0].required_features = 0;
    out->rules = &tg_rule;
    out->count = 1;
    return 1;
}

__attribute__((constructor)) static void tg_register_host_profiles(void)
{
    (void)psx_mod_register_vanilla_host_profiles(tg_host_profiles);
}
