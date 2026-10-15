---
title: "Linux 内核 chroot 的工作原理及使用 Debian GNU/Linux Live CD 修复 GRUB"
slug: "chroot-principles-and-grub-recovery"
lang: zh-Hans
created: 2026-10-15
updated: 2026-10-15
description: "从 Linux VFS 和进程文件系统上下文理解 chroot，并通过 Debian Live 环境修复 UEFI 与 BIOS 模式下的 GRUB。"
license: CC-BY-SA-4.0
---

## chroot 的内核实现

Linux 内核通过虚拟文件系统（VFS）处理文件路径。对于 `open("/etc/passwd", O_RDONLY)` 这样的系统调用，内核需要根据进程的文件系统上下文确定根目录，再沿着目录树查找 `etc` 和 `passwd`。`chroot()` 通过修改进程的根目录，使后续绝对路径的解析从指定目录开始。

Linux 使用 `task_struct` 管理进程，其中的 `fs` 指针引用 `fs_struct`。该结构保存着进程的根目录和当前工作目录：

```
struct path root, pwd;
```

这里的 `struct path` 由两个成员组成：

```
struct path {
    struct vfsmount *mnt;
    struct dentry *dentry;
};
```

`mnt` 标识文件系统的挂载实例，`dentry` 标识目录项。两者结合起来，确定目录在 VFS 挂载树中的位置。例如，将同一个文件系统绑定挂载到两个不同目录后，底层文件可以相同，VFS 中对应的挂载路径却不同。通过 `struct path`，内核能够准确保存进程正在使用的根目录。

### chroot 系统调用如何修改根目录

在 `fs/open.c` 中，`chroot()` 的系统调用入口为：

```
SYSCALL_DEFINE1(chroot, const char __user *, filename)
```

假设程序调用：

```
chroot("/mnt/rootfs");
```

内核首先通过 `user_path_at()` 解析 `/mnt/rootfs`，取得对应的 `struct path`。随后检查该目录的访问权限、调用进程是否具备 `CAP_SYS_CHROOT` 能力，以及安全模块是否允许修改根目录。

检查通过后，执行：

```
set_fs_root(current->fs, &path);
```

这里的 `current` 指向当前任务，`current->fs` 保存任务的文件系统上下文，而 `path` 指向刚刚解析出来的目标目录。

继续进入 `fs/fs_struct.c`，可以找到 `set_fs_root()`。其中，真正改变根目录的操作是：

```
old_root = fs->root;
fs->root = *path;
```

赋值前，内核通过 `path_get()` 为新路径持有引用；赋值期间使用锁保护 `fs_struct`；赋值完成后，再通过 `path_put()` 释放旧根目录的引用。

由于 `struct path` 包含对挂载对象和目录项的引用，新根目录会在进程后续访问文件时继续保持有效。`fs->root` 更新之后，VFS 就能够使用这一新的路径对象进行绝对路径查找。

### 2 VFS 如何使用 chroot 设置的根目录

根目录的更新最终体现在 `fs/namei.c` 中的路径查找过程。

Linux 使用 `nameidata` 保存一次路径解析的状态。对于普通绝对路径，`path_init()` 会调用 `nd_jump_root()`，后者取得当前进程的根目录，并将其设置为路径查找的起点。

这一过程中的两条关键操作是：

```
nd->root = fs->root;
nd->path = nd->root;
```

第一条语句出现在 `set_root()` 中，用于取得进程的根目录。第二条语句出现在 `nd_jump_root()` 中，用于将路径查找的当前位置移动到该根目录。之后，`link_path_walk()` 等函数继续处理路径分量，通过目录项查找与文件系统操作定位最终文件。

例如，假设当前系统有以下目录结构：

```
/
├── etc/
└── mnt/
    └── rootfs/
        ├── bin/
        ├── etc/
        │   └── passwd
        └── usr/
```

进程执行：

```
chroot /mnt/rootfs /bin/sh
```

以后，再打开 `/etc/passwd`，路径查找的起点就对应原目录树中的 `/mnt/rootfs`。VFS 从这个位置依次查找 `etc` 和 `passwd`，最终访问 `/mnt/rootfs/etc/passwd`。

如果路径包含 `..`，VFS 在处理父目录遍历时还会检查根目录边界。当普通路径查找已经到达进程的根目录，继续解析父目录分量会停留在这一位置。

这使程序能够继续使用 `/etc/passwd`、`/usr/bin` 等常见绝对路径，而实际文件来自指定的根文件系统。

### 3 chroot、chdir 与 execve 之间的关系

`chroot()` 修改 `fs_struct.root`，但进程的当前工作目录由 `fs_struct.pwd` 单独保存。因此，用户空间通常在调用 `chroot()` 后，继续调用 `chdir("/")`，确保当前工作目录也进入新的根目录。

一个简化的 C 程序如下：

```
#include <unistd.h>
#include <stdio.h>

int main(void)
{
    if (chroot("/mnt/rootfs") != 0) {
        perror("chroot");
        return 1;
    }

    if (chdir("/") != 0) {
        perror("chdir");
        return 1;
    }

    execl("/bin/sh", "sh", (char *)NULL);

    perror("execl");
    return 1;
}
```

程序先通过 `chroot()` 修改根目录，再将当前工作目录切换到新的 `/`，最后执行目标根文件系统中的 `/bin/sh`。

执行 `execl()` 时，系统最终通过 `execve()` 装载新的程序映像。对于动态链接的 ELF 程序，内核还需要加载 ELF 指定的动态链接器，随后由动态链接器装载共享库。这些文件路径同样按照进程当前的根目录解析。

因此，假设目标根文件系统包含完整的 GNU/Linux 用户空间，程序就能够使用其中的 Bash、GNU C Library、软件包管理工具及其他应用程序。

这里需要理解 Linux 内核与用户空间的关系。`chroot` 中的程序继续由当前正在运行的 Linux 内核执行，所有系统调用仍然进入这个内核。目标根文件系统提供的是程序、共享库、配置文件及其他用户空间资源。

这一机制使得正在运行的 Linux 可以使用另一套兼容的 GNU/Linux 根文件系统。例如，使用 Debian GNU/Linux Live CD 启动计算机后，可以通过 `chroot` 执行硬盘中原有 Debian GNU/Linux 安装的软件程序，并借助这些程序修复磁盘上的启动引导配置。

## 为什么 chroot 需要配合 mount 使用

通过 Live CD 启动的 Linux 内核已经具备访问硬盘的能力，但原有 GNU/Linux 安装的根文件系统此时可能尚未挂载。要让 `chroot` 能够访问它，需要先使用 `mount()` 系统调用相关的用户空间工具，将磁盘文件系统接入当前 VFS 挂载树。

例如：

```
mount /dev/sda2 /mnt
```

完成后，磁盘分区 `/dev/sda2` 中的文件可以通过 `/mnt` 访问。如果执行：

```
chroot /mnt /bin/bash
```

Bash 就可以通过 `/` 访问这一文件系统的根目录。

然而，`/dev`、`/proc` 和 `/sys` 涉及正在运行的 Linux 内核提供的设备和运行信息。

`/dev` 包含磁盘、分区以及终端等设备节点。`/proc` 通过 procfs 提供进程和内核状态信息。`/sys` 通过 sysfs 暴露内核设备模型，并包含部分固件接口。

`chroot()` 自身不会自动挂载这些文件系统。因此，通常需要在进入目标根目录前进行挂载：

```
mount --rbind /dev /mnt/dev
mount -t proc proc /mnt/proc
mount --rbind /sys /mnt/sys
mount --bind /run /mnt/run
```

其中，`--rbind` 表示递归绑定挂载，能够将源目录及其子挂载一并映射到目标位置。例如，绑定 `/dev` 时可以同时保留 `/dev/pts` 等子挂载的访问关系。

这些操作使目标用户空间能够使用 Live 内核提供的设备节点和运行时接口，同时继续读取自身的程序与配置文件。

对于 GRUB 修复，这一组合十分重要：`grub-install` 需要使用原 Debian GNU/Linux 安装中的 GRUB 程序和模块，同时访问当前 Linux 内核识别出的物理磁盘、分区及 UEFI 固件接口。通过挂载原有根文件系统并进入 `chroot`，就能够在同一个运行环境中完成这些操作。

## 使用 Debian GNU/Linux Live CD 修复 GRUB

GRUB（GRand Unified Bootloader）是 GNU 项目的启动引导程序。它在 Linux 内核启动之前运行，负责读取启动配置、定位内核映像与 initramfs，并将控制权交给 Linux 内核。

在传统 BIOS 模式下，GRUB 依赖磁盘引导代码及后续核心映像完成启动。在 UEFI 模式下，固件通过 EFI System Partition（ESP）加载相应的 EFI 程序。Debian GNU/Linux 通常将 GRUB 配置保存在 `/boot/grub/grub.cfg`，通过 `grub-install` 安装引导程序，通过 `update-grub` 重新生成启动配置。

系统引导损坏后，Live CD 提供可运行的 Linux 内核及临时 GNU/Linux 用户空间。

将原有 Debian 根文件系统挂载后，可以通过 `chroot` 运行原 Debian 环境中的 GRUB 工具，恢复磁盘引导程序。

### 1 确认磁盘与启动模式

首先通过 Debian Live CD 或 Live USB 启动计算机，打开终端并取得 root 权限：

```
sudo -i
```

查看磁盘和文件系统：

```
lsblk -f
fdisk -l
```

假设原有 Debian GNU/Linux 安装使用如下分区布局：

| 分区               | 文件系统  | 用途                   |
| ---------------- | ----- | -------------------- |
| `/dev/nvme0n1p1` | FAT32 | EFI System Partition |
| `/dev/nvme0n1p2` | ext4  | 根文件系统                |
| `/dev/nvme0n1p3` | swap  | 交换空间                 |

实际修复时必须使用本机磁盘设备名称，并核对分区 UUID、文件系统类型和容量。写入错误磁盘可能破坏其他系统的引导配置。

对于 UEFI 启动的安装，还应检查 Live 系统是否以 UEFI 模式启动：

```
test -d /sys/firmware/efi &&
    echo "UEFI" || echo "Legacy BIOS"
```

如果需要恢复 UEFI 固件启动项，Live 环境应通过 UEFI 模式启动，从而使 Linux 内核能够访问固件运行时服务。

### 2 挂载原有根文件系统

假设 Debian 根分区为 `/dev/nvme0n1p2`，首先执行：

```
mount /dev/nvme0n1p2 /mnt
```

挂载后检查目标目录：

```
ls /mnt
cat /mnt/etc/fstab
```

这里需要特别关注 `/etc/fstab` 中 `/boot` 和 `/boot/efi` 的挂载配置。某些安装使用独立的 `/boot` 分区，这时应先挂载该分区，再挂载 ESP。

在当前示例中，`/boot` 位于根文件系统内部，ESP 使用 `/dev/nvme0n1p1`，因此执行：

```
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi
```

挂载关系现在对应：

```
/mnt
  ├── etc
  ├── usr
  └── boot
       ├── grub
       ├── vmlinuz-...
       ├── initrd.img-...
       └── efi   → EFI System Partition
```

对于包含独立 `/boot` 分区的安装，正确挂载所有启动相关文件系统尤为重要。否则，后续 GRUB 安装与配置生成可能操作根文件系统中被挂载点覆盖的普通目录，造成启动文件位置错误。

### 3 准备 chroot 的运行环境

在进入 `chroot` 前，需要让目标根文件系统访问设备节点与内核接口：

```
mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev

mount -t proc proc /mnt/proc

mount --rbind /sys /mnt/sys
mount --make-rslave /mnt/sys

mount --bind /run /mnt/run
```

`--make-rslave` 调整递归绑定挂载的传播关系，降低目标挂载树中的变化反向传播到 Live 环境的可能性。

对于 UEFI，还应检查 EFI 变量文件系统：

```
findmnt /sys/firmware/efi/efivars
```

如果系统确实以 UEFI 模式启动，但该文件系统尚未挂载，可以执行：

```
mount -t efivarfs efivarfs \
    /sys/firmware/efi/efivars
```

`efivarfs` 使用户空间能够通过 Linux 内核访问 UEFI 固件变量。GRUB 安装工具可能需要使用这一接口创建或更新 NVRAM 启动项。

随后进入目标根文件系统：

```
chroot /mnt /bin/bash
```

现在，Bash 的根目录已经指向硬盘上原有的 Debian 根文件系统。执行：

```
cat /etc/debian_version
ls /boot
```

会读取原有安装中的文件。接下来执行的 `grub-install` 及 `update-grub` 也会按照这个根目录解析程序、配置和模块路径。

### 4 修复 UEFI 模式下的 GRUB

在 `chroot` 内，先确认 GRUB 软件包状态：

```
dpkg -l | grep -E 'grub|shim'
```

在 x86-64 UEFI 环境下，通常需要 `grub-efi-amd64` 及相关软件包。如果目标安装缺少必要软件包，可在网络和 APT 软件源正常时进行安装：

```
apt update
apt install grub-efi-amd64
```

随后执行：

```
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=debian
```

`--target=x86_64-efi` 指定 GRUB 的目标启动平台，`--efi-directory` 指向已经挂载的 ESP，`--bootloader-id` 指定固件启动项对应的名称。

GRUB 安装程序会准备目标平台所需的引导文件，将 EFI 程序写入 ESP 的相应目录，并在固件接口可用时尝试创建或更新 NVRAM 启动项。对于启用 Secure Boot 的安装，还需要确保目标系统具有适当的签名 GRUB 与 shim 软件包，保持原有的受信任启动链。

接着重新生成 GRUB 启动配置：

```
update-grub
```

该命令通常调用 `grub-mkconfig`，使用 `/etc/default/grub`、`/etc/grub.d/` 中的配置以及 `/boot` 内的内核映像生成 `/boot/grub/grub.cfg`。

可以检查：

```
ls -l /boot/grub/grub.cfg
ls -l /boot/efi/EFI/debian/
```

如果安装了 `efibootmgr`，还可以执行：

```
efibootmgr -v
```

检查 Debian 对应的 UEFI 启动项是否已经存在。这样便完成了 EFI 引导文件和 GRUB 配置的恢复。

### 5 修复传统 BIOS 模式下的 GRUB

对于传统 BIOS 启动的安装，`chroot` 的准备流程基本相同，但 GRUB 使用不同的目标平台和安装位置。

假设原 Debian 根分区为 `/dev/sda1`，启动磁盘为 `/dev/sda`，在 Live 环境中执行：

```
mount /dev/sda1 /mnt

mount --rbind /dev /mnt/dev
mount --make-rslave /mnt/dev

mount -t proc proc /mnt/proc

mount --rbind /sys /mnt/sys
mount --make-rslave /mnt/sys

mount --bind /run /mnt/run

chroot /mnt /bin/bash
```

如果目标安装缺少 BIOS 模式的 GRUB 软件包，可以安装：

```
apt install grub-pc
```

然后执行：

```
grub-install --target=i386-pc /dev/sda
update-grub
```

`i386-pc` 是 GRUB 为传统 x86 BIOS 启动平台使用的目标名称。这里指定的 `/dev/sda` 是整块启动磁盘，GRUB 需要据此安装磁盘引导代码和核心映像。

若磁盘使用 GPT 分区表并通过 BIOS 启动，还应检查是否存在供 GRUB 使用的 BIOS Boot Partition。GRUB 需要在适当位置存放核心映像，缺少必要空间时，安装过程可能失败。此类错误需要结合磁盘分区布局处理，不能直接依赖强制安装选项绕过检查。

### 6 退出 chroot 并重新启动

完成 GRUB 安装及配置生成后，退出目标环境：

```
exit
```

回到 Live 系统的 root shell 后，执行：

```
sync
umount -R /mnt
```

`sync` 请求将待写入的数据同步到存储设备，`umount -R` 递归卸载目标目录下的挂载点。如果某个挂载点仍被进程占用，应检查是否有终端或其他程序停留在 `/mnt` 内。

最后执行：

```
reboot
```

移除 Live 介质，让计算机从已修复的磁盘启动。

## 特殊文件系统布局下的处理

如果原 Debian GNU/Linux 安装使用 LUKS 加密、LVM 或 Btrfs 子卷，必须先在 Live 环境中建立正确的块设备和文件系统挂载关系，然后才能进入 `chroot`。

例如，使用 LUKS 加密根分区时，可以先执行：

```
cryptsetup luksOpen /dev/sda3 cryptroot
```

解锁后，若映射设备直接包含根文件系统，就可以执行：

```
mount /dev/mapper/cryptroot /mnt
```

如果 LUKS 内部使用 LVM，需要先激活卷组，再挂载包含根文件系统的逻辑卷。对于 Btrfs，则可能需要根据原安装的子卷配置，使用 `subvol=` 或 `subvolid=` 挂载选项。

这些操作的目的都是让 `/mnt` 对应原安装实际使用的根文件系统视图。随后挂载 `/boot`、ESP 和内核接口，再通过 `chroot` 执行 GRUB 修复。

如果 `grub-install` 成功但仍无法启动，还需要根据实际故障检查 initramfs、根文件系统 UUID、`/etc/fstab`、LUKS 配置和 GRUB 内核启动参数。例如，原安装的磁盘 UUID 发生变化时，已经安装的 GRUB 可能能够加载 Linux 内核，但内核初始化阶段仍可能无法定位根文件系统。

## chroot 在 GRUB 修复中的作用

整个修复过程对应两次文件系统环境的建立。第一次通过 `mount` 将原 Debian 根文件系统连接到 Live 内核管理的 VFS 挂载树，使磁盘文件可以通过 `/mnt` 访问。第二次通过 `chroot` 将进程的 `fs_struct.root` 指向这个挂载路径，使原有 Debian 用户空间中的程序能够使用其正常的绝对路径。

之后，`grub-install` 使用原 Debian 的 GRUB 模块与配置，并通过 Live Linux 内核的设备接口访问实际磁盘或 ESP。`update-grub` 则使用原 Debian 的内核文件与配置重新生成启动菜单。

从内核实现到实际修复，关键关系始终相同：`mount` 将目标文件系统接入 VFS，`chroot` 改变进程的路径解析起点，`execve` 装载目标用户空间程序，而 Linux 内核继续提供执行程序所需的系统调用和设备访问能力。 这使已经无法正常启动的 GNU/Linux 安装仍然可以在 Live 环境中得到维护和修复。
