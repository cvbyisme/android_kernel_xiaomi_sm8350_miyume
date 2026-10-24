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
