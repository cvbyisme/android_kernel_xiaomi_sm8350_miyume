#!/bin/bash
set -euo pipefail
KDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KDIR"
echo "KERNEL_DIR=$KDIR"
echo "=== [SUSFS] sanity: kernel tree already ships SUSFS 5.4 ==="
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
  [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }
  echo "OK $f ($(wc -c < "$f") bytes)"
done
grep -n TIF_PROC_UMOUNTED include/linux/susfs_def.h | head -3
grep -n susfs.o fs/Makefile | head -3

echo "=== [SUSFS] step 1: FinaSU <-> kernel API name aliases ==="
if grep -q susfs_set_current_proc_umounted_for_zygote_next include/linux/susfs_def.h; then
  echo "aliases already present, skipping"
else
python3 - <<'PYEOF'
path = 'include/linux/susfs_def.h'
s = open(path).read()
BLK = '''/* ===== FinaSU compat: no_su / zygote_next aliases =====
 * FinaSU calls the newer helper names; this 5.4 tree implements the same
 * TIF_PROC_UMOUNTED mechanism under the umounted name. Semantically
 * identical, so map one onto the other instead of editing fs/susfs.c.
 * The zygote_next variants have no separate flag on 5.4, so they collapse
 * onto the same TIF bit.
 */
#ifndef susfs_set_current_proc_no_su
#define susfs_set_current_proc_no_su() susfs_set_current_proc_umounted()
#endif
#ifndef susfs_is_current_proc_no_su
#define susfs_is_current_proc_no_su() susfs_is_current_proc_umounted()
#endif
#ifndef susfs_set_current_proc_umounted_for_zygote_next
#define susfs_set_current_proc_umounted_for_zygote_next() susfs_set_current_proc_umounted()
#endif
#ifndef susfs_is_current_proc_umounted_for_zygote_next
#define susfs_is_current_proc_umounted_for_zygote_next() susfs_is_current_proc_umounted()
#endif

'''
anchor = '#endif // #ifndef KSU_SUSFS_DEF_H'
assert s.count(anchor) == 1, 'guard anchor not unique'
s = s.replace(anchor, BLK + anchor, 1)
open(path, 'w').write(s)
print('susfs_def.h aliases appended, bytes=%d' % len(s))
PYEOF
  echo "aliases appended"
fi

echo "=== [SUSFS] step 2: linux 5.4 uaccess / pgtable shims ==="
cat > include/linux/ksu54_compat.h <<'C54'
#ifndef _KSU54_COMPAT_H
#define _KSU54_COMPAT_H
#include <linux/version.h>
#include <linux/types.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/highmem.h>
#include <linux/errno.h>
#include <linux/string.h>
/* <linux/pgtable.h> only exists since Linux 5.8 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#include <asm/pgtable.h>
#endif
/* untagged_addr() is Linux 5.7+; arm64 5.4 does no tagging on these paths */
#ifndef untagged_addr
#define untagged_addr(addr) (addr)
#endif
/* *_from_user_nofault / *_to_user_nofault are Linux 5.8+ */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
static inline int ksu54_strncpy_from_user_nofault(char *dst,
  const void __user *src,
  long count)
{
long ret;
if (count < 0)
return -EINVAL;
if (!access_ok(src, count))
return -EFAULT;
pagefault_disable();
ret = strncpy_from_user(dst, src, count);
pagefault_enable();
if (ret < 0)
return ret;
if (ret >= count) {
dst[count - 1] = 0;
return -ERANGE;
}
return ret;
}
#define strncpy_from_user_nofault(dst, src, n) \
ksu54_strncpy_from_user_nofault((char *)(dst), (const void __user *)(src), (long)(n))
static inline long ksu54_copy_from_user_nofault(void *dst,
const void __user *src,
size_t size)
{
long ret;
if (!access_ok(src, size))
return -EFAULT;
pagefault_disable();
ret = __copy_from_user_inatomic(dst, src, size);
pagefault_enable();
return ret ? -EFAULT : 0;
}
#define copy_from_user_nofault(dst, src, n) \
ksu54_copy_from_user_nofault((void *)(dst), (const void __user *)(src), (size_t)(n))
static inline long ksu54_copy_to_user_nofault(void __user *dst,
      const void *src,
      size_t size)
{
long ret;
if (!access_ok(dst, size))
return -EFAULT;
pagefault_disable();
ret = __copy_to_user_inatomic(dst, src, size);
pagefault_enable();
return ret ? -EFAULT : 0;
}
#define copy_to_user_nofault(dst, src, n) \
ksu54_copy_to_user_nofault((void __user *)(dst), (const void *)(src), (size_t)(n))
#endif /* < 5.8 */
/* __p4d_to_phys(): p4d is folded away below Linux 5.8 (5-level fixup) */
#ifndef __p4d_to_phys
#define __p4d_to_phys(p4d) __pgd_to_phys(p4d)
#endif
/* copy_to_kernel_nofault() appeared in Linux 5.8 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
static inline int ksu54_copy_to_kernel_nofault(void *dst, const void *src,
					       size_t size)
{
	return copy_from_kernel_nofault(dst, src, size);
}
#define copy_to_kernel_nofault(dst, src, n) \
	ksu54_copy_to_kernel_nofault((void *)(dst), (const void *)(src), (size_t)(n))
#endif /* < 5.8 */

#endif /* _KSU54_COMPAT_H */
C54
echo "written include/linux/ksu54_compat.h"
echo "=== [SUSFS] step 3: drop the zygote_next call FinaSU cannot satisfy on 5.4 ==="
SH="$KDIR/KernelSU/kernel/hook/setuid_hook.c"
if [ -f "$SH" ]; then
python3 - <<'PYEOF2'
p = 'KernelSU/kernel/hook/setuid_hook.c'
s = open(p).read()
old = 'static void ksu_susfs_mark_umounted(bool zygote_next)\n{\n    susfs_set_current_proc_no_su();\n    susfs_set_current_proc_umounted();\n    if (zygote_next)\n        susfs_set_current_proc_umounted_for_zygote_next();\n}'
new = ('static void ksu_susfs_mark_umounted(bool zygote_next)\n'
       '{\n'
       '    /*\n'
       '     * A 5.4 kernel side only exposes the single TIF_PROC_UMOUNTED flag,\n'
       '     * so FinaSU no_su / zygote_next markers collapse onto that bit.\n'
       '     */\n'
       '    (void)zygote_next;\n'
       '    susfs_set_current_proc_no_su();\n'
       '    susfs_set_current_proc_umounted();\n'
       '}')
if s.count(old) == 1:
    open(p, 'w').write(s.replace(old, new, 1))
    print('setuid_hook.c patched')
else:
    print('setuid_hook.c: anchor count=%d, skipped' % s.count(old))
PYEOF2
fi

SUDIR="$KDIR/KernelSU/kernel"
[ -d "$SUDIR" ] || { echo "::error::FinaSU tree not found at $SUDIR"; exit 1; }
F="$SUDIR/feature/sucompat.c"
if [ -f "$F" ] && grep -q pgtable.h "$F"; then
  sed -i "s|^#include <linux/pgtable.h>$|#include <linux/ksu54_compat.h>|" "$F"
  echo "sucompat.c: pgtable -> ksu54_compat"
fi
for G in "$SUDIR/runtime/ksud_integration.c" \
         "$SUDIR/sulog/event.c" \
         "$SUDIR/feature/adb_root.c" \
         "$SUDIR/hook/syscall_event_bridge.c" \
         "$SUDIR/preinit/preinit.c" \
         "$SUDIR/hook/arm64/patch_memory.c"; do
  [ -f "$G" ] || continue
  if ! grep -q ksu54_compat "$G"; then
    sed -i "1i #include <linux/ksu54_compat.h>" "$G"
    echo "injected: ${G#$KDIR/}"
  fi
done

echo "=== [SUSFS] step 4b: TWA_* enum is 5.10+, task_work_add takes bool on 5.4 ==="
for T in "$SUDIR/manager/dynamic_manager.c" \
         "$SUDIR/policy/allowlist.c" \
         "$SUDIR/supercall/supercall.c"; do
  [ -f "$T" ] || continue
  if grep -q 'TWA_RESUME\|TWA_NONE\|TWA_SIGNAL' "$T"; then
    sed -i 's/, TWA_RESUME)/, true)/g; s/, TWA_NONE)/, false)/g; s/, TWA_SIGNAL)/, true)/g' "$T"
    echo "TWA_* -> bool: ${T#$KDIR/}"
  fi
done
echo "=== [SUSFS] step 4c: seccomp.filter_count / seccomp_filter_release are 5.9+ ==="
APF="$SUDIR/policy/app_profile.c"
if [ -f "$APF" ] && grep -q 'filter_count' "$APF"; then
  python3 - "$APF" <<'APFEOF'
import io, sys
p = sys.argv[1]
lines = io.open(p, encoding='utf-8').read().split(chr(10))
out = []
for l in lines:
    if 'seccomp.filter_count' in l:
        out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)')
        out.append(l)
        out.append('#endif')
    elif l.strip() == 'seccomp_filter_release(fake);':
        ind = l[:len(l) - len(l.lstrip())]
        out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)')
        out.append(l)
        out.append('#else')
        out.append(ind + 'put_seccomp_filter(fake);')
        out.append('#endif')
    else:
        out.append(l)
io.open(p, 'w', encoding='utf-8').write(chr(10).join(out))
print('app_profile.c seccomp 5.4 guards added')
APFEOF
fi
echo "=== [SUSFS] step 4d: struct selinux_policy is 5.7+, backport to ss->policydb ==="
SPH="$SUDIR/selinux/sepolicy.h"
RUL="$SUDIR/selinux/rules.c"
SEC="$SUDIR/selinux/sepolicy.c"
if [ -f "$SPH" ] && ! grep -q KSU54_SELINUX_POLICY_SHIM "$SPH"; then
  python3 - "$SPH" "$RUL" <<'SEL54EOF'
import io, sys

h = sys.argv[1]
s = io.open(h, encoding='utf-8').read()
shim = (
    '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)' + chr(10) +
    '#define KSU54_SELINUX_POLICY_SHIM 1' + chr(10) +
    '#' + 'include <linux/sched.h>' + chr(10) +
    '#' + 'include "ss/services.h"' + chr(10) +
    'struct selinux_policy {' + chr(10) +
    '    struct policydb policydb;' + chr(10) +
    '};' + chr(10) +
    'extern struct selinux_state selinux_state;' + chr(10) +
    '#' + 'endif' + chr(10))
s = s.replace('struct selinux_policy *ksu_dup_sepolicy', shim + 'struct selinux_policy *ksu_dup_sepolicy', 1)
io.open(h, 'w', encoding='utf-8').write(s)
print('sepolicy.h: 5.4 struct selinux_policy shim')

r = sys.argv[2]
s = io.open(r, encoding='utf-8').read()
if 'KSU54_POLICY_FIELD' not in s:
    old = 'struct selinux_policy *backup_sepolicy;'
    new = (
        'struct selinux_policy *backup_sepolicy;' + chr(10) + chr(10) +
        '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)' + chr(10) +
        '#define KSU54_POLICY_FIELD' + chr(10) +
        'static struct selinux_policy *ksu54_current_policy(void)' + chr(10) +
        '{' + chr(10) +
        '    static struct selinux_policy shadow;' + chr(10) +
        '    shadow.policydb = selinux_state.ss->policydb;' + chr(10) +
        '    return &shadow;' + chr(10) +
        '}' + chr(10) +
        '#define KSU_POLICY_GET() ksu54_current_policy()' + chr(10) +
        '#define KSU_POLICY_SET(pol) (selinux_state.ss->policydb = (pol)->policydb)' + chr(10) +
        '#define KSU_POLICY_LOCK() mutex_lock(&selinux_state.ss->status_lock)' + chr(10) +
        '#define KSU_POLICY_UNLOCK() mutex_unlock(&selinux_state.ss->status_lock)' + chr(10) +
        '#else' + chr(10) +
        '#define KSU_POLICY_GET() rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex))' + chr(10) +
        '#define KSU_POLICY_SET(pol) rcu_assign_pointer(selinux_state.policy, (pol))' + chr(10) +
        '#define KSU_POLICY_LOCK() mutex_lock(&selinux_state.policy_mutex)' + chr(10) +
        '#define KSU_POLICY_UNLOCK() mutex_unlock(&selinux_state.policy_mutex)' + chr(10) +
        '#endif' + chr(10))
    s = s.replace(old, new, 1)
    s = s.replace('mutex_lock(&selinux_state.policy_mutex);', 'KSU_POLICY_LOCK();')
    s = s.replace('mutex_unlock(&selinux_state.policy_mutex);', 'KSU_POLICY_UNLOCK();')
    s = s.replace('rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));', 'KSU_POLICY_GET();')
    s = s.replace('rcu_assign_pointer(selinux_state.policy, pol);', 'KSU_POLICY_SET(pol);')
    io.open(r, 'w', encoding='utf-8').write(s)
    print('rules.c: policy field access guarded for 5.4')
SEL54EOF
fi
if [ -f "$SEC" ] && ! grep -q ksu54_sepolicy_backport "$SEC"; then
python3 - <<'SECPEOF'
import base64
ADD = chr(10) + base64.b64decode("Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IEdQTC0yLjAKLyogTGludXggNS40IGhhcyBubyBzdHJ1Y3Qgc2VsaW51eF9wb2xpY3kgKHNwbGl0IG91dCBpbiA1LjcpOyB0aGUgcG9saWN5IGRiCiAqIGxpdmVzIGluIHNlbGludXhfc3RhdGUuc3MtPnBvbGljeWRiIGd1YXJkZWQgYnkgcG9saWN5X3J3bG9jay4gS2VlcGluZyB0aGUKICogc2FtZSBrc3VfZHVwX3NlcG9saWN5KCkva3N1X2Rlc3Ryb3lfc2Vwb2xpY3koKSBzdXJmYWNlIGxldHMgRmluYVNVJ3MKICogYXBwbHlfa2VybmVsc3VfcnVsZXMoKSBydW4gdW5jaGFuZ2VkIG9uIDUuNC4KICovCiNpbmNsdWRlIDxsaW51eC9sb2NrZGVwLmg+CiNpbmNsdWRlIDxsaW51eC9yY3VwZGF0ZS5oPgojaW5jbHVkZSA8bGludXgvc2xhYi5oPgojaW5jbHVkZSA8bGludXgvdm1hbGxvYy5oPgojaW5jbHVkZSA8bGludXgvdmVyc2lvbi5oPgojaW5jbHVkZSAic3Mvc2VydmljZXMuaCIKI2luY2x1ZGUgInNlbGludXguaCIKI2luY2x1ZGUgInNlcG9saWN5LmgiCiNpbmNsdWRlICJrbG9nLmgiIC8vIElXWVUgcHJhZ21hOiBrZWVwCgp2b2lkIGtzdV9kZXN0cm95X3NlcG9saWN5KHN0cnVjdCBzZWxpbnV4X3BvbGljeSAqcG9sKQp7CiAgICBpZiAoIXBvbCkKICAgICAgICByZXR1cm47CiAgICBwb2xpY3lkYl9kZXN0cm95KCZwb2wtPnBvbGljeWRiKTsKICAgIGtmcmVlKHBvbCk7Cn0KCnN0cnVjdCBzZWxpbnV4X3BvbGljeSAqa3N1X2R1cF9zZXBvbGljeShzdHJ1Y3Qgc2VsaW51eF9wb2xpY3kgKm9sZF9wb2wpCnsKICAgIHN0cnVjdCBzZWxpbnV4X3BvbGljeSAqbmV3X3BvbDsKICAgIHN0cnVjdCBwb2xpY3lfZmlsZSBmcDsKICAgIHZvaWQgKmRhdGE7CiAgICBzaXplX3QgbGVuOwogICAgaW50IHJldDsKCiAgICBsZW4gPSBvbGRfcG9sLT5wb2xpY3lkYi5sZW47CiAgICBkYXRhID0gdm1hbGxvYyhsZW4pOwogICAgaWYgKCFkYXRhKQogICAgICAgIHJldHVybiBFUlJfUFRSKC1FTk9NRU0pOwoKICAgIGZwLmRhdGEgPSBkYXRhOwogICAgZnAubGVuID0gbGVuOwogICAgcmV0ID0gcG9saWN5ZGJfd3JpdGUoJm9sZF9wb2wtPnBvbGljeWRiLCAmZnApOwogICAgaWYgKHJldCkgewogICAgICAgIHByX2Vycigic2Vwb2xpY3k1NDogcG9saWN5ZGJfd3JpdGU6ICVkXG4iLCByZXQpOwogICAgICAgIGdvdG8gb3V0X2ZyZWVfZGF0YTsKICAgIH0KICAgIGxlbiAtPSBmcC5sZW47CgogICAgbmV3X3BvbCA9IGt6YWxsb2Moc2l6ZW9mKCpuZXdfcG9sKSwgR0ZQX0tFUk5FTCk7CiAgICBpZiAoIW5ld19wb2wpIHsKICAgICAgICByZXQgPSAtRU5PTUVNOwogICAgICAgIGdvdG8gb3V0X2ZyZWVfZGF0YTsKICAgIH0KCiAgICBmcC5kYXRhID0gZGF0YTsKICAgIGZwLmxlbiA9IGxlbjsKICAgIHJldCA9IHBvbGljeWRiX3JlYWQoJm5ld19wb2wtPnBvbGljeWRiLCAmZnApOwogICAgaWYgKHJldCkgewogICAgICAgIHByX2Vycigic2Vwb2xpY3k1NDogcG9saWN5ZGJfcmVhZDogJWRcbiIsIHJldCk7CiAgICAgICAga2ZyZWUobmV3X3BvbCk7CiAgICAgICAgZ290byBvdXRfZnJlZV9kYXRhOwogICAgfQogICAgbmV3X3BvbC0+cG9saWN5ZGIubGVuID0gbGVuOwogICAga3ZmcmVlKGRhdGEpOwogICAgcHJfaW5mbygic2Vwb2xpY3k1NDogZHVwIHBvbGljeWRiIG9rLCBsZW4gJXp1XG4iLCBsZW4pOwogICAgcmV0dXJuIG5ld19wb2w7CgpvdXRfZnJlZV9kYXRhOgogICAga3ZmcmVlKGRhdGEpOwogICAgcmV0dXJuIEVSUl9QVFIocmV0KTsKfQo=").decode()
P = "KernelSU/kernel/selinux/sepolicy.c"
mark = "ksu54_sepolicy_backport"
s = open(P, encoding="utf-8").read()
# neutralise the 5.7+ implementations, keep every other helper in the file
import re
s = re.sub(r"void ksu_destroy_sepolicy\(struct selinux_policy \*pol\)\s*\{.*?\n\}\n", "", s, count=1, flags=re.S)
s = re.sub(r"struct selinux_policy \*ksu_dup_sepolicy\(struct selinux_policy \*old_pol\)\s*\{.*?\n\}\n", "", s, count=1, flags=re.S)
s += ADD
s += chr(10) + "/* ksu54_sepolicy_backport appplied */" + chr(10)
open(P, "w", encoding="utf-8").write(s)
print("sepolicy.c: v5.7 helpers replaced with 5.4 policydb backport")
SECPEOF
fi
echo "=== [SUSFS] step 5: 5.4 has no seccomp syscall cache (added in 5.9) ==="
SCC="$SUDIR/infra/seccomp_cache.c"
if [ -f "$SCC" ] && ! grep -q ksu54_seccomp_stub "$SCC"; then
cat > "$SCC" <<'SCCEOF'
/* ksu54_seccomp_stub: Linux 5.4 has no seccomp syscall bitmap cache
 * (that landed in 5.9 together with struct action_cache). FinaSU only uses
 * these to pre-allow __NR_reboot for the manager uid; on 5.4 the syscall is
 * simply evaluated by the normal filter path, so both helpers are no-ops.
 */
#include <linux/fs.h>
#include <linux/seccomp.h>
#include "klog.h" // IWYU pragma: keep
#include "infra/seccomp_cache.h"

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
(void)filter;
(void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
(void)filter;
(void)nr;
}
SCCEOF
echo "seccomp_cache.c replaced with 5.4 no-op stub"
fi

echo "=== [SUSFS] step 5: 5.4 has no seccomp syscall cache (added in 5.9) ==="
SCC="$SUDIR/infra/seccomp_cache.c"
if [ -f "$SCC" ] && ! grep -q ksu54_seccomp_stub "$SCC"; then
cat > "$SCC" <<'SCCEOF'
/* ksu54_seccomp_stub: Linux 5.4 has no seccomp syscall bitmap cache
 * (that landed in 5.9 together with struct action_cache). FinaSU only uses
 * these to pre-allow __NR_reboot for the manager uid; on 5.4 the syscall is
 * simply evaluated by the normal filter path, so both helpers are no-ops.
 */
#include <linux/fs.h>
#include <linux/seccomp.h>
#include "klog.h" // IWYU pragma: keep
#include "infra/seccomp_cache.h"

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
(void)filter;
(void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
(void)filter;
(void)nr;
}
SCCEOF
echo "seccomp_cache.c replaced with 5.4 no-op stub"
fi

echo "=== [SUSFS] step 6: 5.4 fsnotify backport for pkg_observer.c ==="
POB="$SUDIR/manager/pkg_observer.c"
if [ -f "$POB" ] && ! grep -q ksu54_pkg_observer "$POB"; then
python3 - <<'POBEOF'
import base64
src = base64.b64decode('Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IEdQTC0yLjAKLyoga3N1NTRfcGtnX29ic2VydmVyOiBMaW51eCA1LjQgYmFjay1wb3J0IG9mIEZpbmFTVSBwa2dfb2JzZXJ2ZXIuYyAqLwojaW5jbHVkZSA8bGludXgvbW9kdWxlLmg+CiNpbmNsdWRlIDxsaW51eC9mcy5oPgojaW5jbHVkZSA8bGludXgvbmFtZWkuaD4KI2luY2x1ZGUgPGxpbnV4L2Zzbm90aWZ5X2JhY2tlbmQuaD4KI2luY2x1ZGUgPGxpbnV4L3NjaGVkLmg+CiNpbmNsdWRlIDxsaW51eC9zbGFiLmg+CiNpbmNsdWRlIDxsaW51eC9yY3VsaXN0Lmg+CiNpbmNsdWRlIDxsaW51eC90YXNrX3dvcmsuaD4KI2luY2x1ZGUgPGxpbnV4L3ZlcnNpb24uaD4KI2luY2x1ZGUgImtsb2cuaCIKI2luY2x1ZGUgIm1hbmFnZXIvdGhyb25lX3RyYWNrZXIuaCIKCiNkZWZpbmUgTUFTS19TWVNURU0gKEZTX0NSRUFURSB8IEZTX01PVkUgfCBGU19FVkVOVF9PTl9DSElMRCkKCnN0cnVjdCB3YXRjaF9kaXIgewogICAgY29uc3QgY2hhciAqcGF0aDsKICAgIHUzMiBtYXNrOwogICAgc3RydWN0IHBhdGgga3BhdGg7CiAgICBzdHJ1Y3QgaW5vZGUgKmlub2RlOwogICAgc3RydWN0IGZzbm90aWZ5X21hcmsgKm1hcms7Cn07CgpzdGF0aWMgc3RydWN0IGZzbm90aWZ5X2dyb3VwICpnOwoKc3RhdGljIHZvaWQga3N1X3RyYWNrX3Rocm9uZV90d19mdW5jKHN0cnVjdCBjYWxsYmFja19oZWFkICpjYikKewogICAga2ZyZWUoY2IpOwogICAgaWYgKGN1cnJlbnQtPmZsYWdzICYgUEZfRVhJVElORykKICAgICAgICByZXR1cm47CiAgICB0cmFja190aHJvbmUoZmFsc2UpOwp9CgpzdGF0aWMgdm9pZCBrc3VfZGVmZXJfdHJhY2tfdGhyb25lKHZvaWQpCnsKICAgIHN0cnVjdCBjYWxsYmFja19oZWFkICpjYjsKCiAgICBpZiAoIShjdXJyZW50LT5mbGFncyAmIFBGX0tUSFJFQUQpKSB7CiAgICAgICAgY2IgPSBremFsbG9jKHNpemVvZigqY2IpLCBHRlBfS0VSTkVMKTsKICAgICAgICBpZiAoY2IpIHsKICAgICAgICAgICAgY2ItPmZ1bmMgPSBrc3VfdHJhY2tfdGhyb25lX3R3X2Z1bmM7CiAgICAgICAgICAgIGlmICghdGFza193b3JrX2FkZChjdXJyZW50LCBjYiwgdHJ1ZSkpCiAgICAgICAgICAgICAgICByZXR1cm47CiAgICAgICAgICAgIGtmcmVlKGNiKTsKICAgICAgICB9CiAgICB9CiAgICBwcl93YXJuKCJkZWZlciB0cmFja190aHJvbmUgZmFpbGVkLCBydW4gaXQgaW5saW5lIik7CiAgICB0cmFja190aHJvbmUoZmFsc2UpOwp9CgpzdGF0aWMgaW50IGtzdV9oYW5kbGVfZXZlbnQoc3RydWN0IGZzbm90aWZ5X2dyb3VwICpncm91cCwgc3RydWN0IGlub2RlICppbm9kZSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHUzMiBtYXNrLCBjb25zdCB2b2lkICpkYXRhLCBpbnQgZGF0YV90eXBlLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgY29uc3Qgc3RydWN0IHFzdHIgKmZpbGVfbmFtZSwgdTMyIGNvb2tpZSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0cnVjdCBmc25vdGlmeV9pdGVyX2luZm8gKml0ZXJfaW5mbykKewogICAgKHZvaWQpZ3JvdXA7CiAgICAodm9pZClpbm9kZTsKICAgICh2b2lkKWRhdGE7CiAgICAodm9pZClkYXRhX3R5cGU7CiAgICAodm9pZCljb29raWU7CiAgICAodm9pZClpdGVyX2luZm87CgogICAgaWYgKCFmaWxlX25hbWUpCiAgICAgICAgcmV0dXJuIDA7CiAgICBpZiAobWFzayAmIEZTX0lTRElSKQogICAgICAgIHJldHVybiAwOwogICAgaWYgKGZpbGVfbmFtZS0+bGVuID09IDEzICYmICFtZW1jbXAoZmlsZV9uYW1lLT5uYW1lLCAicGFja2FnZXMubGlzdCIsIDEzKSkgewogICAgICAgIHByX2luZm8oInBhY2thZ2VzLmxpc3QgZGV0ZWN0ZWQ6ICV1IiwgbWFzayk7CiAgICAgICAga3N1X2RlZmVyX3RyYWNrX3Rocm9uZSgpOwogICAgfQogICAgcmV0dXJuIDA7Cn0KCnN0YXRpYyBjb25zdCBzdHJ1Y3QgZnNub3RpZnlfb3BzIGtzdV9vcHMgPSB7CiAgICAuaGFuZGxlX2V2ZW50ID0ga3N1X2hhbmRsZV9ldmVudCwKfTsKCnN0YXRpYyBpbnQgYWRkX21hcmtfb25faW5vZGUoc3RydWN0IGlub2RlICppbm9kZSwgdTMyIG1hc2ssIHN0cnVjdCBmc25vdGlmeV9tYXJrICoqb3V0KQp7CiAgICBzdHJ1Y3QgZnNub3RpZnlfbWFyayAqbTsKICAgIGludCByZXQ7CgogICAgbSA9IGt6YWxsb2Moc2l6ZW9mKCptKSwgR0ZQX0tFUk5FTCk7CiAgICBpZiAoIW0pCiAgICAgICAgcmV0dXJuIC1FTk9NRU07CiAgICBmc25vdGlmeV9pbml0X21hcmsobSwgZyk7CiAgICBtLT5tYXNrID0gbWFzazsKICAgIHJldCA9IGZzbm90aWZ5X2FkZF9pbm9kZV9tYXJrKG0sIGlub2RlLCAwKTsKICAgIGlmIChyZXQpIHsKICAgICAgICBmc25vdGlmeV9wdXRfbWFyayhtKTsKICAgICAgICByZXR1cm4gLUVJTlZBTDsKICAgIH0KICAgICpvdXQgPSBtOwogICAgcmV0dXJuIDA7Cn0KCnN0YXRpYyBpbnQgd2F0Y2hfb25lX2RpcihzdHJ1Y3Qgd2F0Y2hfZGlyICp3ZCkKewogICAgaW50IHJldDsKCiAgICByZXQgPSBrZXJuX3BhdGgod2QtPnBhdGgsIExPT0tVUF9GT0xMT1csICZ3ZC0+a3BhdGgpOwogICAgaWYgKHJldCkgewogICAgICAgIHByX2luZm8oInBhdGggbm90IHJlYWR5OiAlcyAoJWQpIiwgd2QtPnBhdGgsIHJldCk7CiAgICAgICAgcmV0dXJuIHJldDsKICAgIH0KICAgIHdkLT5pbm9kZSA9IGRfaW5vZGUod2QtPmtwYXRoLmRlbnRyeSk7CiAgICBpaG9sZCh3ZC0+aW5vZGUpOwogICAgcmV0ID0gYWRkX21hcmtfb25faW5vZGUod2QtPmlub2RlLCB3ZC0+bWFzaywgJndkLT5tYXJrKTsKICAgIGlmIChyZXQpIHsKICAgICAgICBwcl9lcnIoIkFkZCBtYXJrIGZhaWxlZCBmb3IgJXMgKCVkKSIsIHdkLT5wYXRoLCByZXQpOwogICAgICAgIHBhdGhfcHV0KCZ3ZC0+a3BhdGgpOwogICAgICAgIGlwdXQod2QtPmlub2RlKTsKICAgICAgICB3ZC0+aW5vZGUgPSBOVUxMOwogICAgICAgIHJldHVybiByZXQ7CiAgICB9CiAgICBwcl9pbmZvKCJ3YXRjaGluZyAlcyIsIHdkLT5wYXRoKTsKICAgIHJldHVybiAwOwp9CgpzdGF0aWMgdm9pZCB1bndhdGNoX29uZV9kaXIoc3RydWN0IHdhdGNoX2RpciAqd2QpCnsKICAgIGlmICh3ZC0+bWFyaykgewogICAgICAgIGZzbm90aWZ5X2Rlc3Ryb3lfbWFyayh3ZC0+bWFyaywgZyk7CiAgICAgICAgZnNub3RpZnlfcHV0X21hcmsod2QtPm1hcmspOwogICAgICAgIHdkLT5tYXJrID0gTlVMTDsKICAgIH0KICAgIGlmICh3ZC0+aW5vZGUpIHsKICAgICAgICBpcHV0KHdkLT5pbm9kZSk7CiAgICAgICAgd2QtPmlub2RlID0gTlVMTDsKICAgIH0KICAgIGlmICh3ZC0+a3BhdGguZGVudHJ5KSB7CiAgICAgICAgcGF0aF9wdXQoJndkLT5rcGF0aCk7CiAgICAgICAgbWVtc2V0KCZ3ZC0+a3BhdGgsIDAsIHNpemVvZih3ZC0+a3BhdGgpKTsKICAgIH0KfQoKc3RhdGljIHN0cnVjdCB3YXRjaF9kaXIgZ193YXRjaCA9IHsgLnBhdGggPSAiL2RhdGEvc3lzdGVtIiwgLm1hc2sgPSBNQVNLX1NZU1RFTSB9OwoKaW50IGtzdV9vYnNlcnZlcl9pbml0KHZvaWQpCnsKICAgIGludCByZXQ7CgogICAgZyA9IGZzbm90aWZ5X2FsbG9jX2dyb3VwKCZrc3Vfb3BzKTsKICAgIGlmIChJU19FUlIoZykpCiAgICAgICAgcmV0dXJuIFBUUl9FUlIoZyk7CiAgICByZXQgPSB3YXRjaF9vbmVfZGlyKCZnX3dhdGNoKTsKICAgIHByX2luZm8oIm9ic2VydmVyIGluaXQgZG9uZSIpOwogICAgcmV0dXJuIDA7Cn0KCnZvaWQga3N1X29ic2VydmVyX2V4aXQodm9pZCkKewogICAgdW53YXRjaF9vbmVfZGlyKCZnX3dhdGNoKTsKICAgIGZzbm90aWZ5X3B1dF9ncm91cChnKTsKICAgIHByX2luZm8oIm9ic2VydmVyIGV4aXQgZG9uZSIpOwp9Cg==').decode()
open("KernelSU/kernel/manager/pkg_observer.c", "w").write(src)
print("pkg_observer.c rewritten for 5.4 fsnotify API")
POBEOF
fi

echo "=== [SUSFS] verification ==="
grep -n 'susfs_set_current_proc_no_su\|for_zygote_next' include/linux/susfs_def.h
grep -n '(void)zygote_next' "$SH" || true
ls -l include/linux/ksu54_compat.h
grep -rn ksu54_compat "$SUDIR" | head -10
echo "=== [SUSFS] DONE ==="
