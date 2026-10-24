#!/bin/bash
set -euo pipefail

CHERRY="$HOME/susfs-k54"
KDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KDIR"
echo "KERNEL_DIR=$KDIR"

echo "=== [SUSFS] fetching dev-sm8350/susfs4ksu@k5.4 ==="
rm -rf "$CHERRY"
git clone --depth 1 --branch k5.4 https://github.com/dev-sm8350/susfs4ksu.git "$CHERRY"
KP="$CHERRY/kernel_patches"
ls "$KP"

echo "=== [SUSFS] installing fs/ + include/linux/ sources ==="
cp -v "$KP/fs/susfs.c"         "$KDIR/fs/susfs.c"
cp -v "$KP/fs/sus_su.c"        "$KDIR/fs/sus_su.c"
cp -v "$KP/include/linux/susfs.h"     "$KDIR/include/linux/susfs.h"
cp -v "$KP/include/linux/susfs_def.h" "$KDIR/include/linux/susfs_def.h"
cp -v "$KP/include/linux/sus_su.h"    "$KDIR/include/linux/sus_su.h"

echo "=== [SUSFS] applying kernel-side hooks patch (5.4) ==="
patch -p1 --forward --batch < "$KP/50_add_susfs_in_kernel-5.4.patch" || {
  echo "::warning::retrying patch with fuzz"
  patch -p1 -l --forward --batch < "$KP/50_add_susfs_in_kernel-5.4.patch" || true
}

REJ=$(find . -name '*.rej' -print -quit)
if [ -n "$REJ" ]; then
  echo "::error::patch rejects found"
  find . -name '*.rej' | head -20
  exit 1
fi

# make sure sus_su.o is built too
if grep -q 'CONFIG_KSU_SUSFS) += susfs.o$' fs/Makefile; then
  sed -i 's|obj-$(CONFIG_KSU_SUSFS) += susfs.o$|obj-$(CONFIG_KSU_SUSFS) += susfs.o sus_su.o|' fs/Makefile
fi

echo "=== [SUSFS] FinaSU compat shims ==="
cat >> include/linux/susfs_def.h <<'SUSFSHIM'

/* ===== FinaSU compat shims (dev-sm8350 k5.4 API -> FinaSU API) ===== */
#include <linux/sched.h>
#include <linux/bits.h>
#include <linux/types.h>

#ifndef SUSFS_TASK_STATE_NO_SU
#define SUSFS_TASK_STATE_NO_SU BIT(30)
#endif

static inline void susfs_set_current_proc_no_su(void)
{
current->susfs_task_state |= SUSFS_TASK_STATE_NO_SU;
}

static inline bool susfs_is_current_proc_no_su(void)
{
return !!(current->susfs_task_state & SUSFS_TASK_STATE_NO_SU);
}
SUSFSHIM

echo "=== [SUSFS] linux 5.4 uaccess / pgtable shims ==="
cat > include/linux/ksu54_compat.h <<'C54'
#ifndef _KSU54_COMPAT_H
#define _KSU54_COMPAT_H

#include <linux/version.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/highmem.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#include <asm/pgtable.h>
#endif

#ifndef untagged_addr
#define untagged_addr(addr) (addr)
#endif

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

echo "=== [SUSFS] re-wire FinaSU sources ==="
F="$KDIR/KernelSU/kernel/feature/sucompat.c"
if [ -f "$F" ]; then
  sed -i 's|^#include <linux/pgtable.h>$|#include <linux/ksu54_compat.h>|' "$F"
  # other FinaSU files that need the shims
  for G in "$KDIR"/KernelSU/kernel/runtime/ksud_integration.c \
           "$KDIR"/KernelSU/kernel/sulog/event.c \
           "$KDIR"/KernelSU/kernel/feature/adb_root.c \
           "$KDIR"/KernelSU/kernel/hook/syscall_event_bridge.c; do
    [ -f "$G" ] || continue
    if ! grep -q 'ksu54_compat' "$G"; then
      sed -i '1i #include <linux/ksu54_compat.h>' "$G"
      echo "injected: $G"
    fi
  done
fi

echo "=== [SUSFS] done ==="
ls -l fs/susfs.c fs/sus_su.c include/linux/susfs.h include/linux/susfs_def.h include/linux/ksu54_compat.h
