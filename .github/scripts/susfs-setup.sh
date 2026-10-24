#!/bin/bash
set -euo pipefail

CHERRY="$HOME/susfs-k54"
KDIR="$(pwd)"

echo "=== [SUSFS] fetching dev-sm8350/susfs4ksu@k5.4 ==="
rm -rf "$CHERRY"
mkdir -p "$CHERRY"
curl -sSL --retry 5 -o /tmp/susfs54.tar.gz \\
  https://codeload.github.com/dev-sm8350/susfs4ksu/tar.gz/refs/heads/k5.4
tar -xzf /tmp/susfs54.tar.gz -C "$CHERRY" --strip-components=1
KP="$CHERRY/kernel_patches"
ls "$KP"

echo "=== [SUSFS] installing fs/ + include/linux/ sources ==="
cp -v "$KP/fs/susfs.c"        "$KDIR/fs/susfs.c"
cp -v "$KP/fs/sus_su.c"       "$KDIR/fs/sus_su.c"
cp -v "$KP/include/linux/susfs.h"     "$KDIR/include/linux/susfs.h"
cp -v "$KP/include/linux/susfs_def.h" "$KDIR/include/linux/susfs_def.h"
cp -v "$KP/include/linux/sus_su.h"    "$KDIR/include/linux/sus_su.h"

echo "=== [SUSFS] applying kernel-side hooks patch (5.4) ==="
# fs/Makefile already gets susfs.o via the patch; make sure sus_su.o too
if ! grep -q 'sus_su.o' fs/Makefile; then
  sed -i 's|^obj-$(CONFIG_KSU_SUSFS) += susfs.o$|obj-$(CONFIG_KSU_SUSFS) += susfs.o sus_su.o|' fs/Makefile || true
fi
patch -p1 --forward --batch < "$KP/50_add_susfs_in_kernel-5.4.patch" || {
  echo "::warning::5.4 patch had rejects, trying fuzzy"
  patch -p1 -l --forward --batch < "$KP/50_add_susfs_in_kernel-5.4.patch" || true
}

if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
  echo "::error::patch rejects found:"
  find . -name '*.rej' -exec sh -c 'echo "--- $1"; head -30 "$1"' _ {} \;
  exit 1
fi

echo "=== [SUSFS] FinaSU compat shims ==="
cat >> include/linux/susfs_def.h <<'SUSFSHIM'

/* ===== FinaSU compat shims (dev-sm8350 k5.4 API -> FinaSU API) =====
 * FinaSU calls susfs_{set,is}_current_proc_no_su(); the k5.4 tree only
 * defines TASK_STRUCT_NON_ROOT_USER_APP_PROC. Give FinaSU its own spare
 * bit in task_struct->susfs_task_state (nothing else in fs/susfs.c touches
 * this field, so BIT(30) is safe).
 */
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

/* ---- <linux/pgtable.h> is Linux 5.8+, alias to the 5.4 assembly one ---- */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)
#include <asm/pgtable.h>
#endif

#include <linux/sched.h>
#include <linux/uaccess.h>
#include <linux/mm.h>

/* ---- untagged_addr() is Linux 5.7+ ---- */
#ifndef untagged_addr
#define untagged_addr(addr) (addr)
#endif

/* ---- *_from_user_nofault / *_to_user_nofault are Linux 5.8+ ---- */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0)

#ifndef pagefault_disable
#define pagefault_disable() preempt_disable()
#endif
#ifndef pagefault_enable
#define pagefault_enable() preempt_enable()
#endif

/* 5.4 has strncpy_from_unsafe() (kernel addr) but not the __user variant.
 * access_ok() + pagefault shim is the closest safe equivalent. */
static inline __attribute__((always_inline)) int
ksu54_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr, long count)
{
long ret;

if (count < 0)
return -EINVAL;
if (!access_ok(unsafe_addr, count))
return -EFAULT;

pagefault_disable();
ret = strncpy_from_user(dst, unsafe_addr, count);
pagefault_enable();

if (ret < 0)
return ret;
if (ret >= count) {
/* not NUL terminated, mimic upstream behaviour */
dst[count - 1] = 0;
return -ERANGE;
}
return ret;
}
#define strncpy_from_user_nofault(dst, src, n) \\
ksu54_strncpy_from_user_nofault(dst, src, n)

static inline __attribute__((always_inline)) long
ksu54_copy_from_user_nofault(void *dst, const void __user *src, size_t size)
{
long ret = 0;

if (!access_ok(src, size))
return -EFAULT;

pagefault_disable();
ret = __copy_from_user_inatomic(dst, src, size);
pagefault_enable();

if (ret)
return -EFAULT;
return 0;
}
#define copy_from_user_nofault(dst, src, n) \\
ksu54_copy_from_user_nofault(dst, src, n)

static inline __attribute__((always_inline)) long
ksu54_copy_to_user_nofault(void __user *dst, const void *src, size_t size)
{
long ret = 0;

if (!access_ok(dst, size))
return -EFAULT;

pagefault_disable();
ret = __copy_to_user_inatomic(dst, src, size);
pagefault_enable();

if (ret)
return -EFAULT;
return 0;
}
#define copy_to_user_nofault(dst, src, n) \\
ksu54_copy_to_user_nofault(dst, src, n)

#endif /* < 5.8 */

#endif /* _KSU54_COMPAT_H */
C54

echo "=== [SUSFS] force-including compat header into FinaSU build ==="
# inject into KernelSU Kbuild so every FinaSU object sees the shims
if ! grep -q 'ksu54_compat' "$KDIR/KernelSU/kernel/Kbuild" 2>/dev/null; then
  sed -i '1i ccflags-y += -include $(srctree)/include/linux/ksu54_compat.h' \\
    "$KDIR/KernelSU/kernel/Kbuild" || true
fi

echo "=== [SUSFS] re-wire FinaSU sources ==="
F="$KDIR/KernelSU/kernel/feature/sucompat.c"
if [ -f "$F" ]; then
  # linux/pgtable.h -> 5.4 compat chain
  sed -i 's|^#include <linux/pgtable.h>$|#include <linux/ksu54_compat.h>|' "$F"
fi

echo "=== [SUSFS] done, patched files ==="
grep -n 'pgtable\|ksu54_compat' "$F" || true
ls -l fs/susfs.c fs/sus_su.c include/linux/susfs.h include/linux/susfs_def.h include/linux/ksu54_compat.h
