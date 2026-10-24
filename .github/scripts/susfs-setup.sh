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
src = base64.b64decode("Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IEdQTC0yLjAKLyoga3N1NTRfcGtnX29ic2VydmVyOiBMaW51eCA1LjQgYmFjay1wb3J0IG9mIEZpbmFTVSBwa2dfb2JzZXJ2ZXIuYwogKiBVcHN0cmVhbSB1c2VzIHRoZSBmc25vdGlmeSA2LjAgQVBJIChoYW5kbGVfaW5vZGVfZXZlbnQsIGFsbG9jX2dyb3VwKG9wcyxmbGFncykpLgogKiBPbiA1LjQgdGhlIGdyb3VwIGlzIGNyZWF0ZWQgZmlyc3QgYW5kIHBhc3NlZCB0byBmc25vdGlmeV9pbml0X21hcmsoKSwgYW5kIHRoZQogKiBjYWxsYmFjayBpcyBoYW5kbGVfZXZlbnQoZ3JvdXAsIGlub2RlLCBtYXNrLCBkYXRhLCBkYXRhX3R5cGUsIGZpbGVfbmFtZSwKICogY29va2llLCBpdGVyX2luZm8pLiBPYnNlcnZhYmxlIGJlaGF2aW91ciBzdGF5cyBpZGVudGljYWwuCiAqLwojaW5jbHVkZSA8bGludXgvbW9kdWxlLmg+CiNpbmNsdWRlIDxsaW51eC9mcy5oPgojaW5jbHVkZSA8bGludXgvbmFtZWkuaD4KI2luY2x1ZGUgPGxpbnV4L2Zzbm90aWZ5X2JhY2tlbmQuaD4KI2luY2x1ZGUgPGxpbnV4L3NjaGVkLmg+CiNpbmNsdWRlIDxsaW51eC9zbGFiLmg+CiNpbmNsdWRlIDxsaW51eC9yY3VsaXN0Lmg+CiNpbmNsdWRlIDxsaW51eC90YXNrX3dvcmsuaD4KI2luY2x1ZGUgPGxpbnV4L3ZlcnNpb24uaD4KI2luY2x1ZGUgImtsb2cuaCIgLy8gSVdZVSBwcmFnbWE6IGtlZXAKI2luY2x1ZGUgIm1hbmFnZXIvdGhyb25lX3RyYWNrZXIuaCIKCiNkZWZpbmUgTUFTS19TWVNURU0gKEZTX0NSRUFURSB8IEZTX01PVkUgfCBGU19FVkVOVF9PTl9DSElMRCkKCnN0cnVjdCB3YXRjaF9kaXIgewpjb25zdCBjaGFyICpwYXRoOwp1MzIgbWFzazsKc3RydWN0IHBhdGgga3BhdGg7CnN0cnVjdCBpbm9kZSAqaW5vZGU7CnN0cnVjdCBmc25vdGlmeV9tYXJrICptYXJrOwp9OwoKc3RhdGljIHN0cnVjdCBmc25vdGlmeV9ncm91cCAqZzsKCnN0YXRpYyB2b2lkIGtzdV90cmFja190aHJvbmVfdHdfZnVuYyhzdHJ1Y3QgY2FsbGJhY2tfaGVhZCAqY2IpCnsKa2ZyZWUoY2IpOwppZiAoY3VycmVudC0+ZmxhZ3MgJiBQRl9FWElUSU5HKQo7CnRyYWNrX3Rocm9uZShmYWxzZSk7Cn0KCnN0YXRpYyB2b2lkIGtzdV9kZWZlcl90cmFja190aHJvbmUodm9pZCkKewpzdHJ1Y3QgY2FsbGJhY2tfaGVhZCAqY2I7CgppZiAoIShjdXJyZW50LT5mbGFncyAmIFBGX0tUSFJFQUQpKSB7Cj0ga3phbGxvYyhzaXplb2YoKmNiKSwgR0ZQX0tFUk5FTCk7CihjYikgewpjID0ga3N1X3RyYWNrX3Rocm9uZV90d19mdW5jOwooIXRhc2tfd29ya19hZGQoY3VycmVudCwgY2IsIHRydWUpKQo7CigiZGVmZXIgdHJhY2tfdGhyb25lIGZhaWxlZCwgcnVuIGl0IGlubGluZVxuIik7CnRyYWNrX3Rocm9uZShmYWxzZSk7Cn0KCnN0YXRpYyBpbnQga3N1X2hhbmRsZV9ldmVudChzdHJ1Y3QgZnNub3RpZnlfZ3JvdXAgKmdyb3VwLCBzdHJ1Y3QgaW5vZGUgKmlub2RlLAogICB1MzIgbWFzaywgY29uc3Qgdm9pZCAqZGF0YSwgaW50IGRhdGFfdHlwZSwKICAgY29uc3Qgc3RydWN0IHFzdHIgKmZpbGVfbmFtZSwgdTMyIGNvb2tpZSwKICAgc3RydWN0IGZzbm90aWZ5X2l0ZXJfaW5mbyAqaXRlcl9pbmZvKQp7Cih2b2lkKWdyb3VwOyAodm9pZClpbm9kZTsgKHZvaWQpZGF0YTsgKHZvaWQpZGF0YV90eXBlOwoodm9pZCljb29raWU7ICh2b2lkKWl0ZXJfaW5mbzsKCmlmICghZmlsZV9uYW1lKQogMDsKaWYgKG1hc2sgJiBGU19JU0RJUikKIDA7CmlmIChmaWxlX25hbWUtPmxlbiA9PSAxMyAmJiAhbWVtY21wKGZpbGVfbmFtZS0+bmFtZSwgInBhY2thZ2VzLmxpc3QiLCAxMykpIHsKZm8oInBhY2thZ2VzLmxpc3QgZGV0ZWN0ZWQ6ICVkXG4iLCBtYXNrKTsKZSgpOwp9CnJldHVybiAwOwp9CgpzdGF0aWMgY29uc3Qgc3RydWN0IGZzbm90aWZ5X29wcyBrc3Vfb3BzID0gewouaGFuZGxlX2V2ZW50ID0ga3N1X2hhbmRsZV9ldmVudCwKfTsKCnN0YXRpYyBpbnQgYWRkX21hcmtfb25faW5vZGUoc3RydWN0IGlub2RlICppbm9kZSwgdTMyIG1hc2ssIHN0cnVjdCBmc25vdGlmeV9tYXJrICoqb3V0KQp7CnN0cnVjdCBmc25vdGlmeV9tYXJrICptOwppbnQgcmV0OwoKbSA9IGt6YWxsb2Moc2l6ZW9mKCptKSwgR0ZQX0tFUk5FTCk7CmlmICghbSkKIC1FTk9NRU07CmZzbm90aWZ5X2luaXRfbWFyayhtLCBnKTsKbS0+bWFzayA9IG1hc2s7CnJldCA9IGZzbm90aWZ5X2FkZF9pbm9kZV9tYXJrKG0sIGlub2RlLCAwKTsKaWYgKHJldCkgewpvdGlmeV9wdXRfbWFyayhtKTsKIC1FSU5WQUw7Cn0KKm91dCA9IG07CnJldHVybiAwOwp9CgpzdGF0aWMgaW50IHdhdGNoX29uZV9kaXIoc3RydWN0IHdhdGNoX2RpciAqd2QpCnsKaW50IHJldDsKCnJldCA9IGtlcm5fcGF0aCh3ZC0+cGF0aCwgTE9PS1VQX0ZPTExPVywgJndkLT5rcGF0aCk7CmlmIChyZXQpIHsKZm8oInBhdGggbm90IHJlYWR5OiAlcyAoJWQpXG4iLCB3ZC0+cGF0aCwgcmV0KTsKIHJldDsKfQp3ZC0+aW5vZGUgPSBkX2lub2RlKHdkLT5rcGF0aC5kZW50cnkpOwppaG9sZCh3ZC0+aW5vZGUpOwpyZXQgPSBhZGRfbWFya19vbl9pbm9kZSh3ZC0+aW5vZGUsIHdkLT5tYXNrLCAmd2QtPm1hcmspOwppZiAocmV0KSB7Cm1hcmsgZmFpbGVkIGZvciAlcyAoJWQpXG4iLCB3ZC0+cGF0aCwgcmV0KTsKb2RlKTsKb2RlID0gTlVMTDsKIHJldDsKfQpwcl9pbmZvKCJ3YXRjaGluZyAlc1xuIiwgd2QtPnBhdGgpOwpyZXR1cm4gMDsKfQoKc3RhdGljIHZvaWQgdW53YXRjaF9vbmVfZGlyKHN0cnVjdCB3YXRjaF9kaXIgKndkKQp7CmlmICh3ZC0+bWFyaykgewpvdGlmeV9kZXN0cm95X21hcmsod2QtPm1hcmssIGcpOwpvdGlmeV9wdXRfbWFyayh3ZC0+bWFyayk7Cj0gTlVMTDsKfQppZiAod2QtPmlub2RlKSB7Cm9kZSk7Cm9kZSA9IE5VTEw7Cn0KaWYgKHdkLT5rcGF0aC5kZW50cnkpIHsKMCwgc2l6ZW9mKHdkLT5rcGF0aCkpOwp9Cn0KCnN0YXRpYyBzdHJ1Y3Qgd2F0Y2hfZGlyIGdfd2F0Y2ggPSB7IC5wYXRoID0gIi9kYXRhL3N5c3RlbSIsIC5tYXNrID0gTUFTS19TWVNURU0gfTsKCmludCBrc3Vfb2JzZXJ2ZXJfaW5pdCh2b2lkKQp7CmludCByZXQ7CgpnID0gZnNub3RpZnlfYWxsb2NfZ3JvdXAoJmtzdV9vcHMpOwppZiAoSVNfRVJSKGcpKQogUFRSX0VSUihnKTsKcmV0ID0gd2F0Y2hfb25lX2RpcigmZ193YXRjaCk7CnByX2luZm8oIm9ic2VydmVyIGluaXQgZG9uZVxuIik7CnJldHVybiAwOwp9Cgp2b2lkIGtzdV9vYnNlcnZlcl9leGl0KHZvaWQpCnsKdW53YXRjaF9vbmVfZGlyKCZnX3dhdGNoKTsKZnNub3RpZnlfcHV0X2dyb3VwKGcpOwpwcl9pbmZvKCJvYnNlcnZlciBleGl0IGRvbmVcbiIpOwp9Cg==").decode()
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
