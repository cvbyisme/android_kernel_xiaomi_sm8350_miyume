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
for G in "$SUDIR/runtime/ksud_integration.c" \
         "$SUDIR/sulog/event.c" \
         "$SUDIR/feature/adb_root.c" \
         "$SUDIR/hook/syscall_event_bridge.c" \
         "$SUDIR/preinit/preinit.c"; do
  [ -f "$G" ] || continue
  if ! grep -q ksu54_compat "$G"; then
    sed -i "1i #include <linux/ksu54_compat.h>" "$G"
    echo "injected: ${G#$KDIR/}"
  fi
done

echo "=== [SUSFS] verification ==="
grep -n 'susfs_set_current_proc_no_su\|for_zygote_next' include/linux/susfs_def.h
grep -n '(void)zygote_next' "$SH" || true
ls -l include/linux/ksu54_compat.h
grep -rn ksu54_compat "$SUDIR" | head -10
echo "=== [SUSFS] DONE ==="
