---
title: "从 xv6 的初始化到 Linux 的 init_task"
slug: "from-xv6-init-to-linux-init-task"
lang: zh-Hans
weight: 10
created: 2026-09-14
updated: 2026-09-14
license: CC-BY-SA-4.0
---

操作系统启动通常从一段受严格控制的执行环境开始。处理器完成体系结构相关的早期准备以后进入内核，内核随后建立内存管理、异常处理、调度器、文件系统以及设备管理等基础设施。对于 xv6 这样的教学操作系统，这一过程具有很清楚的线性结构。初始化函数按照依赖关系排列，内核逐步把各个子系统建立起来，随后创建第一个用户进程并进入调度循环。

Linux 的初始化过程保留了同样的基本依赖关系，只是系统规模扩大以后，启动过程被拆分为更多阶段。内存管理具有 early boot、page allocator、slab 等不同层次，调度器需要建立 per-CPU runqueue，RCU、timer、IRQ、workqueue、VFS、namespace 等机制也存在各自的初始化要求。在这些复杂结构开始建立以前，Linux 首先面对一个更基础的问题：执行初始化代码的 CPU 本身需要一个合法的任务上下文。

这个问题在 `start_kernel()` 的开头已经显现出来：

```c
void start_kernel(void)
{
        ...
        set_task_stack_end_magic(&init_task);
        ...
}
```

这里出现的 `init_task` 是 Linux 启动机制中的一个重要对象。调度器此时尚未完成初始化，普通任务创建路径也没有进入正常工作状态，内核已经拥有了一个完整的 `task_struct`。启动 CPU 后续执行的大量初始化代码，都建立在这个最初的任务上下文之上。

## xv6 的线性初始化结构

xv6 的启动代码很好地展示了操作系统各个基础设施之间的依赖关系。物理内存分配器、页表、进程表、文件系统和设备依次建立，在这些组件达到可用状态以后，内核创建第一个用户进程，调度器开始运行。

这种组织方式与 xv6 的进程模型和整体规模密切相关。早期初始化代码能够在一个简单的内核执行环境中运行，对“当前进程”这一抽象的依赖相对有限。进程系统本身也可以作为初始化过程中的一个普通子系统建立起来。等进程结构和调度机制准备完成以后，内核再进入正式的进程调度阶段。

Linux 中，任务上下文已经渗透到大量通用内核机制之中。内存管理代码会访问 `current->mm` 和 `current->active_mm`，锁调试会记录当前任务，RCU 需要识别当前执行上下文，文件系统需要从当前任务获取 `fs`、`files` 和 credentials，namespace、signal、调度统计等机制也都围绕 `task_struct` 组织。启动代码在初始化这些组件的时候，已经需要一个能够被 `current` 找到的任务对象。

因此，Linux 将一个任务对象预先放进内核映像之中。这个对象就是 `init_task`。

## 静态构造的第一个任务

正常运行阶段，Linux 中的新任务通常经过 `fork`、`clone` 或内核线程创建路径产生。这条路径需要完成一系列工作，包括分配 `task_struct`、准备内核栈、初始化调度状态、分配 PID、处理地址空间、文件表、信号、凭据以及 namespace，并最终把任务纳入调度器。

这些工作本身已经依赖相当多的内核基础设施。`task_struct` 的动态分配依赖内存管理和 slab allocator，PID 分配需要 PID 子系统，调度属性初始化需要 scheduler 数据结构，很多路径还会涉及锁、RCU 和 per-CPU 状态。Linux 启动最初阶段无法通过这一整套机制创建第一个任务。

`init_task` 因此采用静态初始化：

```c
struct task_struct init_task = {
        ...
};
```

它的存储空间已经包含在内核映像中。链接器完成内核映像布局以后，这个对象就拥有确定的地址。CPU 进入通用 C 启动代码时，不需要调用 allocator，也不需要执行 `copy_process()`，便能够直接访问这个任务。

`init_task` 周围还有一组同样提前建立的对象，包括 `init_mm`、`init_fs`、`init_files`、初始 credentials、初始 namespace、signal 和 sighand 等结构。它们共同构成了一个最小的内核执行环境。

这种组织方式体现了操作系统自举中的一个常见设计：动态管理机制建立以前，先通过静态对象提供最低限度的运行状态；动态管理机制进入正常工作状态以后，后续对象再通过常规分配和创建路径产生。

## `current` 与启动 CPU

Linux 内核中的 `current` 表示当前 CPU 正在执行的任务。普通进程运行时，`current` 指向对应的 `task_struct`；内核线程运行时，同样通过这个接口获得自身任务结构。

在 x86 等体系结构上，当前任务信息与 per-CPU 状态相联系。启动 CPU 的当前任务在很早阶段就被设置为 `init_task`，于是进入 `start_kernel()` 以后存在这样的关系：

```text
boot CPU
   |
   v
current
   |
   v
init_task
```

这使 `start_kernel()` 中执行的代码已经处于一个正式的 task context 中。随后建立的调度器、RCU、内存管理、VFS 和其他基础设施可以直接围绕 `current` 工作。

这一点对于 Linux 的代码组织十分重要。早期启动阶段和正常运行阶段能够共享同一套任务抽象。启动期间 `current` 指向 `init_task`，普通任务建立以后 `current` 指向当前调度到 CPU 上的任务。很多通用代码因此可以从 very early boot 一直延续到系统正常运行。

## 初始内核栈

`start_kernel()` 开头的：

```c
set_task_stack_end_magic(&init_task);
```

操作的是 `init_task` 已经存在的内核栈。Linux 会在内核栈边界位置写入一个固定的 magic value，后续通过检查这个值判断栈边界是否遭到覆盖。

这行代码出现得很早。随着初始化继续进行，函数调用层次逐渐增加，异常、中断、锁和调度相关代码开始参与执行，内核栈使用情况也会越来越复杂。提前建立 stack end marker，可以让后面的栈检查覆盖整个主要启动阶段。

从这里还可以看到 `start_kernel()` 所处的位置。它已经越过了最原始的汇编启动环境，CPU 拥有可用的内核栈、基本地址映射以及一个能够被 `current` 识别的任务对象。`start_kernel()` 随后负责在这一基础上建立通用内核设施。

## `init_task` 与 `init_mm`

`init_task` 的内存管理字段具有典型的内核线程特征：

```c
.mm        = NULL,
.active_mm = &init_mm,
```

普通用户进程通过 `mm_struct` 描述自己的用户虚拟地址空间，`task->mm` 指向这个对象。纯内核执行上下文没有独立的用户地址空间，因此可以令 `mm` 为空。

CPU 在运行期间仍然需要有效的页表和地址空间上下文，因此 Linux 另外维护 `active_mm`。对于 `init_task`，这个字段指向静态建立的 `init_mm`。

`init_mm` 与 `init_task` 共同构成启动阶段的重要基础对象。前者提供早期地址空间语义，后者提供当前任务语义。内存管理代码因此能够在系统初始化早期就通过正常的数据结构表达当前 CPU 的运行状态。

## PID 0 与 swapper

`init_task` 对应 Linux 的 PID 0，传统名称为 `swapper`。在 boot CPU 上也经常能够看到 `swapper/0` 这样的名称。

PID 0 的生命周期与普通进程不同。它来自静态内核映像，在正式 PID 创建路径建立以前已经存在。启动 CPU 从进入通用内核代码开始就在这个任务上下文中执行，随后调度器把它纳入自己的数据结构。

整个过程可以表示为：

```text
体系结构启动代码
        |
        v
准备初始栈与最低限度运行环境
        |
        v
current = &init_task
        |
        v
start_kernel()
        |
        v
调度器初始化
        |
        v
CPU 0 idle task
```

这一生命周期具有连续性。承担 early boot 的任务结构后来继续作为 boot CPU 的 idle task 存在。

## `sched_init()` 与 boot idle task

当 `start_kernel()` 执行到调度器初始化阶段时，系统开始建立每个 CPU 的 runqueue、调度类状态、调度统计和其他内部数据结构。

对于 boot CPU，当前任务已经存在，因此调度器可以直接使用 `init_task`。初始化代码会设置它的调度属性，并把它登记为 boot CPU 的 idle task。

这个过程可以表示为：

```text
静态 init_task
      |
      v
early boot current
      |
      v
sched_init()
      |
      v
boot CPU idle task
```

其他 CPU 在 SMP 启动阶段同样需要 idle thread。它们通常在相应的 CPU bring-up 过程中创建自己的 idle task。boot CPU 已经拥有 `init_task`，因此无需再通过普通线程创建路径重新生成一个 idle thread。

这种安排使启动 CPU 从最早的内核执行阶段一直保持同一个任务身份，直到系统进入正常调度状态。

## 其他操作系统中的初始执行上下文

Linux 所处理的自举问题同样存在于其他通用内核和微内核中。只要操作系统采用线程调度模型，就需要解决一个基本顺序问题：调度器和普通线程创建机制尚未完成初始化时，启动 CPU 已经开始执行内核代码。不同系统会使用不同的数据结构承载这段初始执行流。

FreeBSD 使用 `proc0` 和 `thread0` 表达这一环境。FreeBSD 将进程级状态和线程级执行状态分开组织，`proc0` 提供最初的进程环境，`thread0` 表示启动阶段正在运行的内核线程，同时还存在 `vmspace0` 等初始对象提供地址空间状态。随着初始化继续推进，`thread0` 被纳入正常的调度体系。Unix 和 BSD 传统中的 `swapper`、process 0 等概念也在这套结构中延续下来。

NetBSD 的结构与此类似，并进一步以 LWP，也就是 Lightweight Process，作为调度执行实体。系统中存在预先建立的 `proc0` 和 `lwp0`，其中 `lwp0` 在启动阶段代表当前正在处理器上执行的内核上下文。普通 LWP 创建机制建立以后，后续线程通过正常路径产生。Linux 将大量进程和线程语义集中在 `task_struct` 中，NetBSD 则通过 `proc` 与 `lwp` 的分工表达类似的运行状态。

Windows NT 采用更加明确的处理器、线程和进程分层。NT 调度器调度的是 thread，每个处理器拥有自己的 processor control block，其中维护当前线程、下一线程以及 idle thread 等状态。启动处理器在调度器完全进入工作状态以前，也需要一个 initial thread 来承载当前执行流。这个线程与初始系统进程以及 boot processor 的处理器控制结构建立关联，随后成为内核调度体系中的合法线程。NT 的 idle execution context 同样具有每 CPU 属性，因此启动阶段建立的初始线程环境与之后的处理器 idle 状态存在直接联系。

Zircon 对这一过程表达得尤其直接。其早期线程初始化代码会从 boot CPU 的 per-CPU 数据中取得预留的线程对象，然后调用类似 `ConstructFirstThread()` 的路径，把“当前已经在 CPU 上执行的状态”构造成一个正式的 `Thread`。这一操作发生在普通线程创建路径全面投入使用以前。随后该 bootstrap thread 可以通过 `BecomeIdle()` 转换成 boot CPU 的 idle thread，并进入 idle loop。

Zircon 的执行路径可以表示为：

```text
boot CPU 已经开始执行
        |
        v
预留 Thread 对象
        |
        v
ConstructFirstThread()
        |
        v
bootstrap thread
        |
        v
完成早期内核初始化
        |
        v
BecomeIdle()
        |
        v
CPU 0 idle thread
```

这一生命周期与 Linux 的 `init_task` 非常接近。两者都利用一个预先存在的线程对象承接已经运行起来的 boot CPU，再让该对象进入正常调度体系，并最终承担 boot CPU 的 idle execution context。

seL4 等微内核也需要建立初始线程和 idle thread。它们通常围绕 TCB，也就是 Thread Control Block，组织调度状态。内核会为各个 CPU 准备 idle TCB，并在启动过程中构造 initial thread。对象名称和调度模型有所差异，自举约束依然存在：第一个可调度执行实体需要通过一条能够绕开普通动态线程创建依赖的路径建立起来。

这些实现共同反映了一个很基础的启动顺序：

```text
CPU 已经开始执行内核代码
        |
        v
建立初始执行上下文
        |
        v
初始化 allocator / scheduler / VM
        |
        v
普通线程创建路径可用
        |
        v
创建后续线程和进程
```

## 从 PID 0 到 PID 1

当 Linux 完成足够多的底层初始化以后，`start_kernel()` 会进入 `rest_init()`。此时内核已经具备正常创建任务所需的主要基础设施，因此可以开始生成真正通过动态任务创建路径产生的线程。

`rest_init()` 首先创建 `kernel_init`，使其获得 PID 1。随后内核创建 `kthreadd`，通常获得 PID 2。任务系统由此从一个静态存在的 PID 0 扩展到正常的动态任务体系。

其关系大致为：

```text
init_task
PID 0
swapper
   |
   +---- kernel_init
   |        PID 1
   |
   +---- kthreadd
            PID 2
```

PID 1 最初仍然在内核态执行。它继续承担后续初始化工作，包括 SMP、部分内存管理、设备模型以及 initcall 等。条件具备以后，PID 1 再通过 `exec` 进入用户空间，执行 `/init`、`/sbin/init` 或其他配置的 init 程序。

与此同时，PID 0 的职责已经逐渐转向 CPU idle。`rest_init()` 完成关键任务创建以后，boot CPU 会进入 `cpu_startup_entry()` 所驱动的 idle loop。调度器在 runqueue 中存在可运行任务时切换到相应任务，没有可运行任务时则重新回到这个 idle execution context。

## 静态初始对象构成的自举环境

`init_task` 很少孤立存在。Linux 的 early boot 依赖一组预先建立的静态对象，它们共同提供动态内核机制形成以前所需的运行环境。

其中包括 `init_task`、`init_mm`、`init_fs`、`init_files`、初始 namespace、初始 credentials 以及各种体系结构相关的 boot CPU 数据。它们在编译、链接或 very early boot 阶段已经拥有确定的存储位置和基本状态。

随着启动过程推进，这些对象逐渐接入正常内核子系统：

```text
静态内核映像
        |
        v
init_task / init_mm / init_fs / init_files / ...
        |
        v
形成最低限度内核执行环境
        |
        v
建立内存管理与 per-CPU 基础设施
        |
        v
初始化 scheduler / RCU / IRQ / timer
        |
        v
正常任务创建路径可用
        |
        v
创建 PID 1、PID 2 和其他内核线程
        |
        v
执行 initcall 与设备初始化
        |
        v
PID 1 进入用户空间
```

在这条启动链中，`init_task` 始终与 boot CPU 的执行状态关联。它从静态内核映像中的一个 `task_struct` 开始，随后成为 `current` 所指向的启动任务，再被调度器接纳为 CPU 0 的 idle task。`rest_init()` 创建出 PID 1 和 `kthreadd` 以后，新的任务开始沿正式的 Linux 任务创建路径进入系统。

boot CPU 此后进入 idle loop。runqueue 为空时，处理器运行 `init_task` 所对应的 idle context；出现可运行任务以后，调度器完成上下文切换并执行相应线程。启动 Linux 内核时最早出现的那个 `task_struct`，就这样继续留在 CPU 0 的调度结构中。
