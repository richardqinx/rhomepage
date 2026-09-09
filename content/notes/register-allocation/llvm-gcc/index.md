---
title: "第九部分: CPU 工业寄存器分配: LLVM 与 GCC"
slug: "llvm-gcc"
lang: zh-Hans
series: register-allocation
weight: 100
created: 2026-08-18
updated: 2026-09-09
license: CC-BY-SA-4.0
---

前八部分建立的各种概念在 LLVM 和 GCC 中都有对应物, 但它们寄存器分配策略大相径庭. LLVM 的优化型 allocator 长期围绕 `LiveInterval` 工作, 保留 value 在机器代码位置上的生命周期信息, 然后针对某个 physical register 查询实际 interference. 当 assignment 失败时, Greedy 可以 eviction, splitting, recoloring, 最后才进入 spill. GCC 则把主要工作分成 IRA 和 LRA 两层. IRA 构造 allocation regions 和 conflict graph, 使用经过大量工程扩展的 Chaitin-Briggs coloring 做全局分配; LRA 接着根据 RTL instruction constraints 处理 reload, late assignment, splitting 和 rematerialization.

这两种设计恰好代表了前面几部分中的两条不同路线. LLVM Greedy 延续了 live interval 的位置化表示, 但打破了经典 Linear Scan 的单向 allocation order. GCC IRA 则保留了 graph coloring 的基本框架, 同时加入 region hierarchy, irregular register classes, cost propagation 和 live range splitting. 看清两者的内部结构之后, "工业寄存器分配为什么远比 textbook coloring 复杂" 这个问题也会具体很多.

## 1 LLVM 的 Machine Register Allocation 基础设施

LLVM 进入 Machine IR 后, operand 已经逐渐具有目标机器语义. Virtual register 属于某个 `TargetRegisterClass`, instruction operands 可以带有 tied, early-clobber, implicit use/def 等属性, function call 则通过 register mask 描述哪些 physical registers 会被破坏. 在 register allocation 以前, virtual registers 仍然可以利用 Machine SSA 提供的 single-definition 结构; RA 附近的 passes 会逐渐把 phi, two-address constraints, copies 和 physical-register requirements 转换成 allocator 能直接处理的形式.

LLVM 对 virtual register 生命周期的核心表示是 `LiveInterval`. 它建立在 `LiveRange` 上, 一个 `LiveRange` 由按照 `SlotIndex` 排序的多个 `Segment` 组成. Segment 描述一个 value 在 `[start,end)` 上 live, `VNInfo` 则表示其中某个 definition 产生的 value number. 当一个 live range 中出现多个 definitions, CFG join 或 splitting 产生的新 fragments 时, allocator 仍然可以用不同的 `VNInfo` 区分这些值. `LiveInterval` 还可以保存 subregister subranges, 因而同一个 virtual register 内部不同 lanes 的 liveness 也能够进一步细分.

`SlotIndex` 把 Machine IR 中的程序位置映射到一个有序空间. 它的粒度比 "第几条指令" 更细, 可以区分 instruction boundary, register use/def slot 以及 early-clobber def. 因此一条 live interval 不只是抽象地知道自己和另一条 interval 有冲突, 它还保留冲突发生在函数的什么位置. 这份位置信息后来直接用于 local splitting, global splitting, spill placement 和 fixed-register interference.

Physical register 一侧由 `LiveRegMatrix` 组织. 它沿 `SlotIndex` 和 register unit 两个维度记录已经建立的 assignment. Register unit 是处理 overlapping physical registers 时使用的最小 interference unit. 因此 x86 上两个不同的 architectural register names 即使发生 alias, allocator 仍然能够在共享的 register units 上检测到冲突. 这就是第八部分讨论的 subregister aliasing 在 LLVM RA 中落到数据结构后的样子.

假设 virtual register `%v1` 的 live interval 为:

```text
%v1:
      |-----------|         |------|
```

allocator 准备尝试 physical register `R0`. `LiveRegMatrix` 会查看 `R0` 及其 aliases 覆盖的 register units, 再检查 `%v1` 的 segments 是否与这些 units 上已经存在的 live ranges 重叠. 如果没有重叠, `%v1 -> R0` 可以直接建立. 如果冲突来自另一个已经分配的 virtual register, 那个 assignment 仍然可能被 eviction 或 recoloring 改变. 如果冲突来自 fixed register-unit live range, 或 `%v1` 跨越了一个不 preserve `R0` 的 register mask, 问题就不能通过简单驱逐另一个 virtual register解决. `LiveRegMatrix` 因此区分 free, virtual-register interference, fixed register-unit interference 和 regmask interference.

这一结构和经典 interference graph 有明显差别. Chaitin-Briggs 会先建立 virtual nodes 之间的冲突边, 随后主要在图结构上工作. LLVM Greedy 给 `%v1` 尝试 `R0` 时, 直接询问 "`R0` 对 `%v1` 的这些 live positions 是否可用". Interference 仍然存在, 只是它没有被统一压缩成一张完整的 virtual-register graph. 这让 allocator 在发现某个 register 只有局部位置发生冲突时, 很自然地继续考虑 splitting.

LLVM 的优化型 RA pipeline 也围绕这些数据结构组织. 省略 target-specific 插入点和与本文无关的 passes 后, 主干可以用如下示意图表示.

```text
Machine SSA
    |
    v
PHI Elimination
    |
    v
Two-Address Instruction Lowering
    |
    v
Register Coalescer
    |
    v
Independent Subregister Renaming
    |
    v
Pre-RA Machine Scheduler
    |
    v
Register Allocator
    |
    v
VirtReg Rewriter
    |
    v
Stack-slot / copy / post-RA optimizations
```

`PHIElimination` 把 phi 的 edge semantics 转换成后续 machine representation, `TwoAddressInstruction` 处理 two-address 和 tied operand 产生的问题. `RegisterCoalescer` 在正式 allocation 前先合并能够安全合并的 COPY-related live ranges. `MachineScheduler` 随后改变机器指令顺序, 它的选择会直接改变 live range shape 和 register pressure. RA 完成后, `VirtRegRewriter` 根据 `VirtRegMap` 把 MachineInstr 中剩余的 virtual-register operands 改写成 physical registers.

LLVM 同时提供 Fast, Basic, Greedy 和 PBQP 几种 allocator. Fast 面向低优化编译, 重点是降低 allocation 开销; Greedy 是优化编译的默认 allocator. Basic 提供较简单的全局 allocation 框架, Greedy 在相同基础设施上加入更完整的 eviction 和 global live range splitting. PBQP 则把 register allocation 建模成 Partitioned Boolean Quadratic Programming 问题, 通过 PBQP solver 求解 assignment. 个人很欣赏 PBQP, 因为它的数学理论足够优美, 读者可以参考原始论文, 不过后面的讨论集中在 Greedy, 因为它最能体现 LLVM CPU register allocation 的工业设计.

## 2 LLVM Greedy: 从 Priority Queue 到 Eviction

LLVM Greedy 不按照 live interval 的起始位置从前向后扫描. 待分配 intervals 存放在 priority queue 中, allocator 每次从队列中取出一个 live interval进行 assignment. 这里的 priority 也不能简单等同于 spill weight. 对原始的 single-block local ranges, 默认策略保留接近 instruction order 的顺序; 对 global ranges 和 split 后产生的 ranges, 主要按照 live-range size 从长到短处理. Priority 中还可以编码 register class 的 allocation priority, global/local 属性和 physical-register preference.

这种 allocation order 解决了经典 Linear Scan 的一个结构限制. 假设有一条很长的 global interval `a`, 以及大量短 local intervals:

```text
a:
|------------------------------------------------------|

b:      |---|
c:            |---|
d:                  |---|
e:                        |---|
f:                              |---|
```

Linear Scan 按 start position 前进时, 前面已经完成的 assignment 会逐渐形成既定状态. Greedy 可以优先处理 global 和较长 ranges, 让影响范围大的 assignment 先占据合适的 physical register, 再让局部 ranges 在剩余空间中安排. 对单 block 的简单 SSA ranges, instruction order 本身又具有很好的局部性质, 所以 LLVM 没有机械地用同一个优先级公式处理所有 intervals.

取出一个 interval 后, allocator 先根据 register class, target register order 和 register hints 建立 `AllocationOrder`. Register hint 通常来自 COPY relation 或其他 machine preference. 如果 `%v1` 与一个已经位于 `R3` 的 value 存在有利于 coalescing 的关系, `R3` 就可能被提前尝试. 对每个 candidate physical register, allocator通过 `LiveRegMatrix` 检查 interference. 找到 free candidate 后就可以在 `VirtRegMap` 和 matrix 中建立 assignment.

Physical registers 也有 cost. 第八部分讨论过 callee-saved register 第一次在函数中使用时可能引入 prologue/epilogue save/restore. Greedy 在选择 candidate 和 eviction strategy 时会考虑这种代价, 因此 "某个寄存器目前空闲" 并不自动意味着立即使用它最划算. 当一个便宜 register 与已有 virtual intervals 冲突, 驱逐这些 intervals有时反而比开始使用一个新的高成本 register 更合适.

Eviction 是理解 LLVM Greedy 的核心机制之一. 假设 `R0` 已经分配给 `b`, 新到来的 `a` 与它发生 overlap:

```text
R0:

b:          |----------------|
a:       |------------------------|
             <---- conflict ---->
```

如果 allocator认为 `a` 更值得占据 `R0`, 可以撤销 `b -> R0`, 再建立 `a -> R0`. `b` 不会因此立即 spill, 它被重新送回 allocation 流程, 后面仍然可以获得别的 physical register, 被 split, 或最终 spill. 一次 eviction 还可以同时驱逐同一个 candidate register 上的多条 interfering intervals. Greedy 会根据 victim costs, spillability 和 cascade information 控制这种行为, 避免 allocations 在几个 intervals 之间无限来回震荡.

这和 Chaitin-Briggs 中的 stack coloring 形成了不同的搜索方式. Chaitin-Briggs 先通过 simplify 得到一个 coloring order, 再在 select 阶段恢复节点. Greedy 在 assignment 过程中允许局部撤销已有结果. 当一个高价值 live range 到来时, allocator 可以重新安排先前的较弱 assignment, 因此 allocation state 本身处于持续变化中.

Spill weight 在这里主要作为成本信息参与 eviction, splitting 和 spill decision. `LiveInterval` 的 weight 会根据 uses, defs 和 block frequency 等信息计算, 反映保留该 interval 的价值. 但 queue priority 和 spill weight 是两个不同概念. 一个 global interval 可以因为长度和 allocation stage 很早进入队列, 它是否值得驱逐其他 intervals 或最终进入 memory, 则要结合另一套 cost information 判断.

## 3 LLVM Greedy: Splitting, Recoloring 与 Spilling

如果一条 live interval 找不到 free physical register, eviction 也没有得到合适解, Greedy 不会立即把整个 interval spill. 第一次 allocation failure 会把它转入 split stage 并重新排队. 其他更容易处理的 intervals 继续完成 assignment, 等这条 interval 再次进入 allocator时, 周围的 physical-register occupancy 已经稳定了许多. 此时 allocator可以更准确地看到 "冲突究竟集中在哪些程序区域", 再决定怎样 splitting.

考虑一条 global live interval:

```text
v:
|-----------------------------------------------------------|

R4 interference:
       |------|                 |---------|
```

如果 `R4` 在绝大部分生命周期中都很适合 `v`, 只有两个局部区域发生 interference, 把整个 `v` 放弃掉会损失很多 register residency. Greedy 可以把原始 interval 切成多个 child intervals, 让其中适合 `R4` 的部分继续使用 `R4`, 剩余 fragments 回到队列重新寻找 assignment:

```text
v0: |------|

v1:        |--------------------|

v2:                             |---------|

v3:                                       |---------------|
```

Splitting 不只是修改一个 interval 的 `[start,end)` 元数据. `SplitKit` 和 `SplitEditor` 会创建新的 virtual registers 和 live intervals, 重新建立 value numbers, 修改 fragment 与 Machine IR uses 的对应关系, 并处理进入或离开某个 child interval 时需要的数据传递. Split mode 还可以偏向减少动态 COPY cost 或减少静态 COPY 数量, 因此 split boundary 的选择本身就是 code-quality decision.

Global splitting 会结合 basic-block frequency 和 use blocks. 假设一个 value 在热循环中频繁使用, 在冷控制流中偶尔存活, allocator可能让热区域保持 register assignment, 把 transfer 或 spill pressure 推向较冷路径:

```text
cold          hot loop                cold

------|=========================|---------
      ^                         ^
   transfer                  transfer
```

这种策略体现了 position-based allocator 的优势. Interference 发生在 live interval 的哪些 blocks, 哪些 edge 上需要进入或离开 register region, 都直接存在于 allocator使用的数据结构里. Greedy 可以围绕一个 candidate physical register 的具体 interference pattern选择 split region.

Splitting 后生成的 child intervals重新进入 queue, 所以后续过程依然是普通 register allocation. 某个 child 可能立即找到 free register, 可能 eviction 其他 intervals, 也可能继续 split. 这使 "一个 virtual register 的 allocation" 不再是一次性决策. 原始 live range 可以逐渐被分解成一组具有不同 assignment 的 fragments.

Greedy 还保留 recoloring 作为晚期搜索手段. 当某个 interval无法获得物理寄存器时, allocator可以尝试改变周围 interfering virtual registers 的 assignment, 递归寻找另一组合法组合. Recoloring 只能够重新安排 virtual-register interference; fixed register-unit interference 和 regmask clobber 属于机器已经给定的障碍, 不能通过重新着色消失. 为了限制编译时间, recoloring 的深度和搜索规模会受到控制.

最终仍然无法安排的 interval 进入 spiller. `InlineSpiller` 会插入 spills 和 reloads, 同时尝试 stack-access folding 和 rematerialization. 如果某个 definition 足够便宜, use 位置可以重新生成这个值, allocator就没有必要把它先 store 到 stack 再 load 回来. Spill rewrite 还可能产生新的短 virtual registers, 这些 fragments继续接受后端后续处理.

把 Greedy 的主要控制流放在一起, 可以看到它与 textbook allocator 的结构差异:

```text
priority queue
      |
      v
try free physical register
      |
      +---- success ----------------------> assign
      |
      v
try eviction
      |
      +---- success ----------------------> assign
      |                                      |
      |                                      +--> requeue victims
      v
defer and requeue
      |
      v
try splitting
      |
      +---- create child intervals -------> requeue children
      |
      v
try recoloring
      |
      +---- success ----------------------> assign
      |
      v
spill / rematerialize
```

Register coalescing 与 Greedy 的关系也因此比 IRC 更分散. LLVM 有独立的 `RegisterCoalescer` 在 RA 前合并 live ranges, Greedy 自身还会使用 register hints, hint-related splitting 和 recoloring 尽量保持有利的 COPY assignment. Copy elimination 并没有集中在一个 `Simplify-Coalesce-Freeze` 状态机中, 它贯穿 coalescing pass, allocation order 和后续 repair decisions.

## 4 GCC IRA: 从 RTL Pseudo 到 Regional Graph Coloring

GCC 在机器级主要使用 RTL. Register allocation 以前, RTL 中大量值仍然由 pseudo-registers 表示, 最终需要落到 hard registers 或 memory. IRA 的 allocation entity 称为 `allocno`. 一个 allocno 表示某个 pseudo-register 在一个 allocation region 中的生命周期, 因而同一个 pseudo 可以在不同 nested regions 中对应不同 allocnos.

IRA 的 regions 形成一棵树. Root region 覆盖整个函数, 其他主要 regions 来自 natural loops. 如果函数中存在两层嵌套循环, 结构可以近似表示为:

```text
function region
|
+-- allocno(p)
|
+-- loop L1
|   |
|   +-- allocno(p)
|   |
|   +-- loop L2
|       |
|       +-- allocno(p)
|
+-- other code
```

外层 allocno 会累积下层 regions 中与同一 pseudo 相关的 cost, conflict, copy 和 hard-register information. 因而 root region 的 coloring 能够先形成整个函数范围的 global decision, 随后进入 loops 和 subloops 时再根据局部情况改善 assignment. 这种 top-down regional allocation 同时保留 global view 和 loop-local optimization 空间.

Allocno 内部还可以分解成更细的 `ira_object`. `ira_object` 保存 conflict information 和 live ranges, 并且可以对应 allocno 的某个 subword. 对一个 multi-word allocation object, IRA 因而能够在比整个 pseudo 更细的层面描述 conflicts. Live range 使用整数 program points 表示, 这些 points 位于 operand die 和 output born 等可能改变 liveness 的机器位置附近. 两个 objects 的 live ranges 相交时, IRA 据此建立 conflict relation.

IRA 在 coloring 前会同时构造几类信息. Allocno class 决定某个 allocno 可以使用哪一类 hard registers, pressure class 用于计算不同硬件资源上的 register pressure. 每个 allocno 还拥有 memory cost, hard-register cost vector, conflict hard-register costs, crossed-call 信息以及与其他 allocnos 的 copy relation. 跨 call 的 allocno 会让某些 hard-register choices 增加 save/restore cost; move-related allocnos 则可以通过修改 hard-register preference, 增加获得相同 register 的机会.

因此 IRA 的输入已经远远超过一张无权 interference graph. 可以用如下示意图简要概括.

```text
RTL pseudos
    |
    v
region tree
    |
    v
allocnos / objects
    |
    +--> live ranges
    +--> allocno conflicts
    +--> hard-register conflicts
    +--> register pressure
    +--> memory costs
    +--> hard-register costs
    +--> copy preferences
    |
    v
regional graph coloring
```

IRA 名字中的 "Integrated" 也可以从这里理解. Coalescing, hard-register preference 和 live range splitting 都被放进 regional coloring 的整体过程. Copy relation 会改变 coloring 时的 register preference, regional allocation 的不同结果又可以自然产生 live-range splitting.

IRA 的 coloring 仍然能够清楚看到 Chaitin-Briggs 的血统. Allocnos 被逐步压入 coloring stack, high-pressure 情况使用 Briggs optimistic coloring, 不会在入栈阶段就把所有 high-degree nodes立即判定为 actual spill. 弹栈时再根据已经占据的 hard registers 尝试 assignment. 如果一个 coalesced allocno无法找到合法 hard register, IRA 还可以撤销 coalescing, 将拆开的 allocnos重新送回 coloring process.

IRA 还会形成 `thread`. 一个 thread 由互不冲突且通过 copies 联系起来的 colorable allocnos 组成. 把这些 allocnos相邻压入 coloring stack, 后续分配同一个 hard register 的机会更高, 从而减少 move. 这和第五部分 IRC 追求的目标相同, 但 IRA 没有采用 `Simplify`, `Coalesce`, `Freeze` 那套 textbook worklists, copy preference 被嵌入 regional coloring 和 hard-register cost 中.

第八部分讨论的 irregular register classes 会直接修改 IRA 的 trivial-colorability 判断. 假设某个 allocno可以使用多个 general hard registers, 它同时和 8 个 allocnos发生 conflict, 但那 8 个 allocnos都只能使用 `EAX`. 只看 graph degree 会得到 8 个 neighbors, 可这些 neighbors 最多共同封锁 `EAX` 这一种 hard-register choice, 其余 general registers仍然可以使用. IRA 会结合 allocno classes 和可分配 hard-register sets 判断一组 conflicts 实际能够排除多少候选资源.

因此 GCC 虽然使用 coloring stack 和 optimistic coloring, 但颜色集合已经具有 register-class structure, 每种 hard register 还有不同 allocation cost, copies 修改 preference, regions 又让同一个 pseudo 在不同程序区域拥有不同 allocation objects. GCC 公开的 `-fira-algorithm=CB` 对应 Chaitin-Briggs coloring, 另一个选择是 priority coloring; speed-oriented regional allocation通常使用 loop regions, 并可以过滤 register pressure 较低的 loops.

Regional allocation 本身还会产生 splitting. 假设同一个 pseudo `p` 在外层代码和热循环中分别对应两个 allocnos, IRA 可能得到:

```text
outside loop          hot loop           outside loop

     R2      --->        R5       --->       R2
```

如果 loop 内使用 `R5` 的综合成本更低, IRA 可以在 region boundary 创建新的 pseudo 并插入 transfer code. 这样 `p` 的逻辑生命周期就被拆成多个具有不同 location 的 fragments. Splitting 在这里来自 region hierarchy, 与 LLVM 根据 physical-register interference pattern 主动寻找 split region 的方式不同.

IRA coloring完成后还会从 cost 角度继续改善结果. 某些 allocnos即使可以获得 hard register, memory assignment 也可能使整体成本更低; 某些已经 spill 的 allocnos释放出的 registers又可能让其他高价值 allocnos获得更便宜的 assignment. 因此 "尽可能多地 color nodes" 并不等价于 "得到最低-cost machine code". IRA 的 hard-register costs, memory costs 和 region-border move costs共同参与这些取舍.

## 5 GCC LRA: Instruction Constraints 与 Reload

IRA 做出的是全局 allocation decision, 真实 RTL instruction 还必须逐条满足 machine description 中的 operand constraints. 某个 pseudo 从全局角度适合放进 GPR, 某次具体 use 却可能要求一个更窄 register class; 某条 instruction alternative 可能允许 memory operand, 另一条要求 hard register; tied operand, early-clobber 和 address constraint 还会进一步限制局部 assignment. LRA 接在 IRA 后面处理这些问题. 它继承了过去 Reload pass 所承担的角色, 但组织方式是围绕 instruction constraints 反复修正 RTL.

假设 IRA 后有:

```text
OP p
```

而 `OP` 的合法 alternative 要求这个 operand 位于某个 restricted hard-register class. 如果 `p` 的 location 无法直接满足约束, LRA 可以生成一个 reload pseudo:

```text
r <- p
OP r
```

`r` 拥有符合 instruction constraint 的 allocno class, 后续 hard-register assignment 再给它寻找合法 register. 如果 `p` 已经位于 stack, 这就是经典意义上的 reload temporary. 如果 instruction 支持合适的 memory alternative, LRA 也可能选择另一种 encoding, 从而避免显式 reload.

LRA 的 constraint pass 需要在一条 instruction 的多个 alternatives 中做选择. 一个 alternative 可能减少 reload, 但消耗更稀缺的 register class; 另一个允许 memory, 却可能产生更昂贵的 machine instruction. 选择 alternative 后如果生成新的 reload pseudos, 这些 pseudos又需要 hard registers. 为它们腾出位置可能迫使其他 pseudos spill, 新的 spill location 又可能改变地址表达式. Address displacement 发生变化以后, 原先合法的 address constraint 还可能失效. 因而 LRA 的求解天然带有反馈, 必须迭代直到 instruction 和 address constraints 都得到满足.

可以把这种反馈关系画成:

```text
instruction constraints
        |
        v
choose alternatives
        |
        v
create reload insns / reload pseudos
        |
        v
hard-register assignment
        |
        v
spill / split / inheritance
        |
        v
stack locations and addresses
        |
        +----------------------+
                               |
                     constraints changed
                               |
                               +----> iterate
```

第一次 constraint processing 会遍历 instructions 并选择 alternatives. 后续迭代会尽量保留仍然合法的选择, 把工作集中在受到新 reload, spill 或 address change 影响的部分. 这和重新进行一次完整 IRA coloring 的成本结构不同, LRA 的目标是逐步把已经相当接近机器代码的 RTL 修正到可编码状态.

LRA 还有 inheritance optimization. 假设 spilled pseudo `p` 第一次使用时已经 reload 到某个 hard register:

```text
reload1 <- p
use reload1

...

reload2 <- p
use reload2
```

如果两次 use 之间 `p` 的值没有改变, 第一条 reload 得到的值可能仍然保存在 register 中. LRA 可以创建 inheritance pseudo, 让后一次 use 尝试继承已经存在的 register value, 从而避免再次访问 stack. 后面的 assignment 如果无法给 inheritance pseudo安排合适的 hard register, 这次 transformation 可以撤销, 恢复原来的 reload sequence.

Inheritance pass 同时会进行 EBB 范围内的 live-range splitting. 一个 global pseudo 穿过高 pressure 区域时, LRA 可以在局部插入 save/restore-style transfer, 把原来的长 live range拆开. 跨 call 的 pseudos也可以利用类似方式缩短需要保持特定 hard register 的区域. 这意味着 GCC 的 splitting 不只存在于 IRA region boundaries. IRA 处理全局和 loop hierarchy 上的分割, LRA 还会在更靠近 instruction constraints 的阶段继续调整生命周期.

Rematerialization 则处理另一类 spill cost. 对一个 spilled pseudo, 如果它的 definition可以用较便宜的 machine operation重新计算, LRA 可以在 use 附近重新生成 value, 省掉 memory reload. 候选通常需要避开 memory access 和昂贵的 div/mod 等操作, 同时保证输入 operands 已经处于可用 hard registers 中. GCC 的 `-flra-remat` 就控制这类 CFG-sensitive rematerialization.

因此 LRA 虽然名称中有 "Local", 它处理的范围远不止 basic-block-local register assignment. 它拥有 iterative constraint solving, reload-pseudo creation, hard-register assignment, EBB inheritance, splitting 和 CFG-sensitive rematerialization. 它在 GCC RA 架构中的位置可以理解成从 "IRA 已经给出一个良好的全局资源方案" 走到 "每一条 RTL instruction 都满足真实 ISA constraints" 的机器合法化阶段.

## 6 LLVM Greedy 与 GCC IRA+LRA 的结构差异

把两套 allocator 放在一起以后, 最值得比较是它们怎样保存信息以及怎样从失败的 assignment 中恢复. 如下是一个简要的表格对比二者在重要问题上的差异.

|问题|LLVM Greedy|GCC IRA + LRA|
|---|---|---|
|主要 allocation object|`LiveInterval` 及 split fragments|IRA `allocno`, conflict 可以细化到 `ira_object`|
|生命周期表示|`SlotIndex` 上的 `Segment` 和 `VNInfo`|IRA program points 上的 live ranges|
|Conflict 组织|`LiveRegMatrix` 按 physical register 和 regunit 查询|IRA 构造 allocno/object conflicts|
|全局分配方式|priority-based incremental assignment|regional Chaitin-Briggs coloring|
|已有 assignment 的调整|eviction 和 recoloring|optimistic coloring, coalescing undo, regional reassignment|
|Coalescing|独立 RegisterCoalescer + hints + recoloring|copies 和 hard-register preference 集成到 IRA coloring|
|Splitting|根据 interval interference 做 local/global splitting|IRA region splitting + LRA EBB splitting|
|Machine constraints|MachineInstr constraints, register classes, regunits, regmasks贯穿 RA|IRA 先做全局 allocation, LRA 再集中满足 RTL alternatives 和 address constraints|
|Spill 后处理|InlineSpiller, folding, rematerialization|LRA reload pseudos, inheritance, splitting, rematerialization|

LLVM 的主要优势在于 allocator一直保留精细的程序位置信息. 当 `%v` 无法使用 `R5` 时, Greedy 可以看到 `R5` 究竟在哪些 segments 上被什么对象占据, 然后决定 eviction 整条 interfering interval, 围绕局部 interference splitting, 或把某个 child fragment 留在 memory. `LiveRegMatrix` 又让同一套查询自然处理 register aliasing 和 call regmask.

GCC IRA 的主要全局视角来自 conflict graph 和 region hierarchy. Allocno 把 "一个 pseudo 在一个 region 中的生命周期" 变成 coloring entity, nested loops使 allocator能够在整个函数方案之上继续改善 hot regions. Chaitin-Briggs 的 simplify/select 思想仍然存在, 但 trivial colorability 已经扩展到 intersected register classes, coloring choice 又受到 hard-register cost vectors 和 copy preferences控制.

IRA 与 LRA 的分工还体现出 GCC 对 machine constraints 的处理层次. IRA 可以在较稳定的全局模型上处理 pressure, conflicts 和 region costs, 避免让每条 instruction alternative 都进入 graph-coloring problem. LRA 在全局方案之后处理高度 target-specific 的约束, 并通过 reload pseudos 和迭代 repair 收敛到合法 machine code. LLVM 则让 target register classes, physical-register interference, regmask 和 MachineInstr operand constraints更早地进入统一的 Machine IR allocation infrastructure.

Scheduler 与 register pressure 在两边也有直接联系. LLVM 的 optimized RA pipeline 在 Greedy 前执行 machine scheduling, 调度后的 live intervals直接成为 allocation 输入. GCC 也支持 pressure-sensitive pre-RA scheduling, `-fsched-pressure` 会在调度时控制 register pressure, 避免调度把同时 live 的值数量推过可用 hard-register capacity, 从而给后续 IRA/LRA 制造额外 spills.

从前几部分的算法谱系来看, LLVM Greedy 很难简单放进 "Linear Scan" 或 "Graph Coloring" 其中一格. 它使用 `LiveInterval` 和 position-based interference, 延续了 interval allocator 的基础设施; allocation order 已经变成 priority queue, 同时加入 eviction, global splitting 和 recoloring. GCC IRA 与 Chaitin-Briggs 的继承关系更加直接, 但 nested regions, irregular register classes, copies, hard-register costs 和 LRA 又把 textbook coloring 扩展成了一个完整的机器级 allocation system.

这两套实现最终都在解决同一组资源问题. 一个 value 应该在哪些区域占据 register, 哪个 physical register 对它最便宜, 哪些 COPY 值得消除, 哪些 conflicts 值得通过重新安排其他 values 解决, 哪些区域应该 split, 什么时候 memory traffic 比继续争夺寄存器更划算. LLVM 把这些决策更多组织在 live interval 和 incremental assignment 周围, GCC 把它们更多组织在 regional coloring 和 constraint repair 周围. 下一部分进入 GPU 后, 这些问题还会多出 occupancy 这一层反馈: 一条 live range 多占用几个 registers, 可能改变整个 SM/CU 同时能够驻留的 warps 或 waves 数量, register allocation 的目标函数也会随之发生变化.
