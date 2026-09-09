---
title: "前言"
slug: "preface"
lang: zh-Hans
series: register-allocation
weight: 10
created: 2026-08-09
updated: 2026-09-09
license: CC-BY-SA-4.0
---

最近一直在进行的工作就是推进我的新编译器, 虽然在现在这个时代一个人实现一个功能完备性能又很好的大型软件几乎不可能, 但是我目前至少在让后端尽可能支持更多的功能以及对代码有更好的优化. 完整的代码暂时没有公开, 但是欢迎各位去看我的生成代码质量比较好的竞赛编译器: [rcc-project](https://github.com/Richard-Qin-X/rcc-project)

说到后端, 寄存器分配无疑是最重要的环节之一, 但是翻了一下知乎, 没有发现系统地讲解寄存器分配的文章, 而且我对编译原理这门课也有一些意见, 花大量篇幅讲代码怎么到 AST 在现在的意义并不大, 中后端的内容太少而且过于 textbook, 与现实脱节太严重, 尤其是深度学习的兴起, MLIR 和 异构平台代码生成更重要了. 于是决定写一系列文章, 系统性地介绍一下**寄存器分配的基本概念, 经典算法, 现代机器模型, CPU 工业实现, GPU 寄存器分配**, 以及一个 **综合与实践** 环节 (一个自己动手实现简单寄存器分配算法的教程).

具体的结构等这个系列写完之后我会放在这篇文章里. 

相信通过这个系列的文章, 读者能够比较好地理解活跃性分析与生命周期, 冲突图, 图着色寄存器分配, 贪心分配, 以及现代编译器 LLVM 和 GCC 的后端架构和重要算法, 还有 GPU 的一些知识.

我觉得最值得期待的就是 **综合与实践** 部分, 毕竟光看理论和自己动手还是不一样的. 我已经在我的新编译器里手写了一个 PBQP, 当然在这个部分我不会介绍这种几千行代码的复杂算法, 我会尽量设计一个比较简单的场景和算法, 让读者能用几百行代码完成.

还有一些比较值得关注的就是 **GPU 寄存器分配**, 传统编译原理课程中讲的寄存器分配主要是针对 CPU, 而 GPU 寄存器分配与 CPU 在约束和优化目标上有一些明显不同. 很多人会疑惑的一点就是 GPU 寄存器这么多分配就不重要了吧, 然而事实上只要存储速度跟不上计算速度寄存器分配就永远是焦点, GPU 上尤其特殊的一点是, 寄存器分配直接影响 occupancy.

假设一个 SM 有固定数量的寄存器

```
SM register file
      │
      ├── Block 0
      │    ├── Thread 0: 64 regs
      │    ├── Thread 1: 64 regs
      │    └── ...
      │
      ├── Block 1
      └── ...
```

如果每个线程需要的寄存器越多, 一个 SM 同时能够驻留的线程 / warp / block 就可能越少. 比如粗略地说

```
SM 有 65536 个寄存器

每线程 32 registers
→ 理论上可容纳 65536 / 32 = 2048 threads

每线程 64 registers
→ 理论上只可容纳 1024 threads
```

当然实际 occupancy 还同时受到 warp 数, block 数, shared memory 等硬件限制.

所以 GPU register allocator 往往面对一个很有意思的权衡

```
多用寄存器
   ↓
更少 spill，单线程执行可能更快
   ↓
但 occupancy 可能降低

少用寄存器
   ↓
occupancy 可能提高
   ↓
但可能产生 spill
   ↓
访问 local memory，代价可能很高
```

这里的 local memory 不是片上寄存器旁边的一小块高速内存, 在 CUDA 中，它通常属于显存层次, 虽然可能被 cache, 因此 register spilling 往往比较昂贵.

另外在本篇文章结束前聊一个比较有意思的发现, 现在没有人专门做GCC和LLVM寄存器分配的 benchmark 对比. 而且这件事有点反常, register allocation 学术论文非常多, 但 production allocator vs production allocator 的标准化 benchmark 基础设施却很弱. 我个人觉得一方面的原因是二者后端根本不接受一种形式的 IR, 导致没有办法很公平地对比二者的后端, 目前学术论文主要是在 LLVM 内实现一个特定的 allocator 和 production allocator 进行对比.

有趣的是, 连 GCC IRA 的主要作者 Vladimir Makarov 在 Reddit 上讨论 LLVM 和 GCC RA 时, 更多也是给经验判断. 他指出真实 RA 的表现受到 splitting, rematerialization, target constraints, coalescing 等大量细节影响, 他个人经验是 graph-coloring 在复杂 CFG 上可能表现更好, 并举 SPEC perl 一类程序作为例子.

另外, 根据我找到的一些 benchmark 来看, GCC 表现普遍强于 LLVM, 不论是编译时间还是代码生成的质量, 而我看到知乎上很多人说 LLVM 明显比 GCC 快, 我觉得这一点有失偏颇. 在大型 C++ 项目中链接的速度也很重要, 而 LLVM 的 LLD 远强于 GNU 的 ld, 论据如下:

| target         |   GNU ld |     LLD |
| -------------- | -------: | ------: |
| ffmpeg debug   |   1.72 s |  0.35 s |
| mysqld debug   |   8.50 s |  0.68 s |
| clang debug    | 104.03 s |  5.28 s |
| chromium debug | 209.05 s | 16.70 s |
而且还有一个很有意思的证据, mold 又进一步把 LLD 拉开了.

mold 当前公布的大型程序 benchmark 是:

| Program      | GNU ld | GNU gold |   LLD |      mold |
| ------------ | -----: | -------: | ----: | --------: |
| MySQL 8.3    | 10.84s |    7.47s | 1.64s | **0.46s** |
| Clang 19     | 42.07s |   33.13s | 5.20s | **1.35s** |
| Chromium 124 |      — |   27.40s | 6.10s | **1.52s** |
所以我觉得没必要批评 GCC 已经被 LLVM 击败了, 真正导致编译慢的是 GNU 的 Binutils, 它要背大锅. 一个比较值得尝试的方向是 GCC + LLD 或者 GCC + mold.
