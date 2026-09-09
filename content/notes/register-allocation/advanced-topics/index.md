---
title: "第十一部分: 高级问题与协同优化"
slug: "advanced-topics"
lang: zh-Hans
series: register-allocation
weight: 120
created: 2026-08-19
updated: 2026-09-09
license: CC-BY-SA-4.0
---

前面的章节已经把 register allocation 的主要机制拆开讨论过. Liveness 决定 value 在什么位置必须存在, interference 或 live interval 描述这些生命周期怎样竞争物理资源, allocator 再通过 coloring, priority assignment, eviction, splitting 和 spilling 完成实际分配. 到工业编译器中, 这些机制很少独立工作. Instruction scheduling 会改变 live range, instruction selection 会改变 register class 和 operand constraints, coalescing 会扩大 allocation object, spill rewrite 又会制造新的 temporaries. GPU 上还多出 occupancy 这一层反馈, register pressure 的变化可能直接改变 resident waves 或 warps 的数量.

因此后端优化中经常遇到一种共同结构: 某个 pass 在自己的局部目标上做出了更好的选择, 却把问题转移给了另一个 pass. Scheduler 提前若干 independent instructions 可以增加 ILP, 同时可能提高 register pressure. Aggressive coalescing 可以删除 COPY, 也可能让两个原本较短的 live ranges 合并成一个难以分配的长 range. Instruction selector 选择一条静态指令数更少的特殊指令, 可能引入 fixed-register constraint, 让后面的 allocator 付出额外 spill cost. 高质量 code generation 因而依赖这些阶段之间交换足够的信息, 而不是简单地把每个阶段各自优化到极致.

## 1 Instruction Scheduling 与 Register Pressure

Scheduling 对 RA 最直接的影响来自 definition 和 use 的距离. 一个 definition 被提前以后, 如果它的 uses 没有同时提前, 对应 live range 就会延长. 一个 last use 被推迟也会产生相同效果. 当很多 values 同时被拉长时, maximum register pressure 就可能上升.

考虑两种合法的 schedule:

```text
Schedule A:

a = load A
b = load B
c = load C

x = f(a)
y = g(b)
z = h(c)
```

以及:

```text
Schedule B:

a = load A
x = f(a)

b = load B
y = g(b)

c = load C
z = h(c)
```

第一种 schedule 可以让多个 memory operations 较早进入执行流水线. 对具有较长 memory latency 的机器来说, 这种安排可能增加 memory-level parallelism. 代价是 `a`, `b`, `c` 会在较长区域内同时 live:

```text
a: |-------------------|
b:    |----------------|
c:       |-------------|
```

第二种 schedule 把 definition 放得更靠近 use:

```text
a: |-----|
b:        |-----|
c:               |-----|
```

register pressure 明显下降, 但同时存在的 independent memory operations 也减少了. 所以 scheduler 面对的不是简单的 "尽量缩短 live range", 它还要考虑 latency, critical path, execution resources 和 ILP.

可以从 scheduling point 上的 live set 观察这种变化. 假设一条 ready instruction $I$ 产生若干新 definitions, 同时消费一部分已经到达 last use 的 operands. 如果暂时忽略 register class 和 multi-register value, 局部 pressure 变化可以粗略理解成 $\Delta P\approx |Def(I)|-|Kill(I)|$. 定义越多, pressure 越容易上升; 一次结束多个旧 values 的生命周期, pressure 则可能迅速下降.

实际 scheduler 不能只根据这个局部变化选择指令. 假设当前机器有 16 个可用 registers, pressure 从 8 增加到 9 可能没有任何实际后果, 从 16 增加到 17 却可能迫使 allocator 产生 spill. GPU 上还会出现更明显的离散阈值: pressure 从 64 增加到 65 可能让 register allocation 跨过硬件 granularity, 进而减少一个 resident wave. 因此 pressure-aware scheduling 更关心 peak pressure 以及它和资源阈值之间的距离.

Scheduling 和 allocation 的先后顺序也带来不同信息. Pre-RA scheduler 面对 virtual registers, 没有受到具体 physical assignment 的限制, 所以拥有更大的 instruction-motion 空间. Post-RA scheduler 已经知道真实 physical registers 和机器 hazards, 但寄存器复用也会引入新的 dependencies. 两个本来独立的 virtual values 如果最终使用同一个 physical register 的不同时间段, post-RA scheduler 就不能任意打乱这种复用关系.

这也是为什么工业后端通常同时存在 pre-RA 和 post-RA scheduling. 前者需要控制 pressure, 后者则在 allocation 已经确定以后处理更具体的机器执行问题.

## 2 Splitting, Spilling 与 Rematerialization

当 register pressure 超过可用资源时, allocator 可以改变 assignment, 也可以改变 allocation object 本身. Splitting, spilling 和 rematerialization 都属于后一类手段, 它们通过修改 value 在不同程序区域中的 location 来降低寄存器需求.

假设一个 value 有很长的生命周期:

```text
v:
|----------------------------------------------|

              high pressure
                 |--------|
```

真正困难的区域可能只有中间这一小段. 如果 allocator 把整个 `v` spill, definition 之后就写入 stack, 每个后续 use 再重新 load, 那么大量本来没有压力的区域也要承担 memory traffic. Splitting 可以把原来的 live range 切成多个 fragments:

```text
v0:
|--------------|

v1:
               |----------|

v2:
                          |--------------------|
```

`v0` 和 `v2` 仍然可以驻留 register, `v1` 在高 pressure region 内使用另一个 physical register或进入 memory. 这样一次 allocation failure 被限制在真正发生资源竞争的区域.

Split point 本身也有成本. 两个 fragments 如果 location 不同, 边界上需要 COPY, spill 或 reload. 因此 allocator 不只需要决定 "在哪里压力最大", 还要决定 transfer 放在哪里执行代价最低.

Loop boundary 是典型例子. 假设一个 transfer 可以放在 loop body 中:

```text
loop:
    ...
    COPY
    ...
```

也可以放在 loop entry:

```text
COPY
loop:
    ...
```

如果 loop 执行很多次, 两种方案的静态代码只差一个位置, 动态执行成本却可能相差几个数量级. 所以 global splitting 通常会结合 block frequency 和 loop structure, 尽量让稳定的 register assignment 覆盖热区域, 把 location change 推到较冷的边界.

Spilling 的成本也和 target ISA 密切相关. 某些机器指令允许 memory operand, 那么一个 spilled value 的 reload 有机会直接 fold 到原指令中. 另一些 ISA 要求 operand 必须位于 register, 每次 use 前都需要独立 reload temporary. 同一个 abstract spill 在不同 target 上最终可能产生完全不同的 machine instruction sequence.

Rematerialization 则利用 value 的可重新计算性. 假设:

```text
v = 42
...
use v
```

如果把 `v` 正常 spill, 可能产生:

```text
store 42, [slot]
...
t = load [slot]
use t
```

而 immediate 很容易重新生成时, 可以直接得到:

```text
t = 42
use t
```

这样 memory spill 完全消失. Frame address, constant pool address 和某些简单 arithmetic expression 也经常适合 rematerialization.

Rematerialization 并非永远便宜. 如果重新计算 `v` 需要几个 source values, 那些 sources 必须在 rematerialization point 仍然可用, 它们的 live ranges 可能因此被延长. 一个看起来只有两条指令的 recomputation 也可能增加 dependency chain 或占用 execution ports. 所以 allocator 需要比较 reload cost 和 recomputation cost, 不能只判断 "这个 definition 能不能复制".

Spill slot 本身还存在资源复用问题. 两个 spilled values 如果它们在 memory 中需要保存的时间不重叠, 可以共享同一个 stack slot:

```text
spill a:
|----------|

spill b:
             |----------|
```

这种 stack-slot coloring 和 physical-register reuse 的基本思想相同, 只是资源从 register file 换成了 stack frame. Size, alignment 和 target addressing constraints 又会给它增加新的限制.

## 3 Cost Model, Profile 与 Loop

Register allocator 很少存在唯一的合法解. 大多数时候它面对的是一批都合法但成本不同的选择. 哪个 value 应该 spill, 哪个 physical register 更合适, 哪条 COPY 值得为了它扩大 live range, 某个 split boundary 应该放在哪个 block, 最终都需要 cost model.

只统计静态 uses 很容易产生错误判断. 考虑:

```text
cold:
    use a
```

和:

```text
hot_loop:
    use b
```

两个 values 静态上各有一次 use, 动态执行频率却可能完全不同. 如果二者必须选择一个 spill, `b` 的一次 reload 可能在整个程序运行中执行数百万次.

一个抽象的 spill cost 可以把每个 use 和 def 按执行频率加权. 例如可以把 reload 部分写成 $\sum_{u\in Uses(v)}Freq(u)\cdot Cost_{\mathrm{reload}}(u)$, 再加入 definitions 对应的 spill/store cost. 真正实现还会继续修正这个模型: 某个 use 可以 fold memory operand 时 reload cost 会下降, value 可以 rematerialize 时 memory cost可能被计算成本替代, live range跨 call时不同 registers 又有不同保存成本.

没有 profile 时, loop depth 常被用作 execution frequency 的近似. 位于三层 loop 内的 instruction 通常比函数 entry 附近的一次性代码更热. 这种 heuristic 很有用, 但它始终只是结构上的预测. 一个深层 loop 可能位于极少进入的错误处理路径, 一个没有显式 loop 的 basic block 也可能因为函数被大量调用而极热.

Profile-guided optimization 能够给 allocator 更接近实际执行的 block frequency 和 edge frequency. 这会直接改变 spill placement 和 splitting. 如果一个 live range 在热路径与冷路径发生冲突, allocator可以考虑保留热路径上的 register residency, 把 reload 或 COPY 推到冷 edge.

Coalescing 同样可以使用频率信息. 一条位于函数初始化路径上的 COPY 即使保留下来也只执行一次, 为了删除它而合并两个大型 live ranges通常没有太大价值. 如果 COPY 位于一个频繁执行的 inner loop, register preference 就应该更强.

Calling convention 也具有类似结构. 一个 value跨过多个 hot calls时, 把它放在 caller-saved register可能不断产生 save/restore. 使用一个 callee-saved register虽然会增加一次 prologue/epilogue 成本, 却可能降低整个函数中的动态 traffic. 如果这些 calls 都位于冷路径, 使用 caller-saved register又可能更划算.

Cost model 无法精确预测现代 CPU 的所有行为. Out-of-order execution, cache, branch prediction, move elimination 和 memory-level parallelism 都会让一条静态 instruction 的实际成本随上下文变化. RA 阶段更实际的目标是获得可靠的相对排序. 它需要分辨明显昂贵和明显便宜的方案, 同时自身不能成为编译时间瓶颈.

## 4 Instruction Selection 与 Register Allocation

Instruction selection 决定了 allocator 最终面对什么样的机器指令. 两个完成相同语义的 instruction sequence 可以具有不同 register pressure, register classes 和 operand constraints, 所以 instruction selector 的选择会直接改变 RA 的问题形状.

例如某个 operation 可以用普通三地址 sequence 完成:

```text
t1 = ...
t2 = ...
r  = OP t1, t2
```

也可以用一条特殊 instruction:

```text
r = SPECIAL_OP ...
```

后一种方案的静态 instruction count 更少, 但如果 `SPECIAL_OP` 要求固定 register pair, 或只能使用一个很小的 register class, allocator可能需要为了它移动其他 live values. 如果这个区域已经处于高 pressure 状态, 最终 spill code 的成本可能超过节省的一两条 instructions.

Memory operand 也是 instruction selection 和 RA 联系很紧的地方. 某些 x86 指令允许一个 source 直接来自 memory. 一个将来发生 spill 的 value 如果能够直接成为 memory operand, allocator 可以省掉独立 reload. Selector 选择的 instruction form 如果不支持这种 encoding, 后面的 spiller 就失去 folding 机会.

Two-address lowering 会更加直接地产生 register preference. 抽象三地址操作:

```text
v3 = ADD v1, v2
```

如果目标机器要求 destination 与第一个 source 相同, 后端可能转换成:

```text
v3 = COPY v1
v3 = ADD v3, v2
```

当 `v1` 在 ADD 后死亡时, allocator很容易让 `v1` 和 `v3` 使用同一个 physical register, COPY 随之消失. 如果 `v1` 在后面仍然 live, 这个 COPY 可能必须真实存在. 因而 instruction selector 或 two-address lowering 选择哪一个 operand 与 destination tied, 可以根据 liveness 改变最终 copy cost.

ABI 进一步为 selection 和 allocation 设置了函数边界约束. Arguments 和 return values 有固定 register convention, caller-saved 与 callee-saved registers具有不同生命周期成本. Tail call, varargs 和特殊 calling conventions 还会进一步限制可用 physical resources.

从优化理论看, instruction selection, scheduling 和 register allocation 最好能够联合求解, 因为三个阶段会互相改变彼此的成本函数. 但把它们完全合并会使搜索空间迅速增长. 工业编译器通常仍然采用分阶段 pipeline, 再通过 register-pressure estimates, operand hints, rematerialization information 和 post-RA optimization 在阶段之间传递有限但高价值的信息.

## 5 GPU 上的 Occupancy-aware 优化

GPU 把 register pressure 的后果扩展到了并行执行资源. CPU 上一个函数多使用几个 registers通常主要影响它自己的 spilling 和 scheduling. GPU 上 per-thread 或 per-wave register usage 会决定一个 SM 或 CU 能同时驻留多少 execution contexts.

因此 GPU 的 register-pressure cost 通常是非线性的. 假设某个硬件分配 granularity 使 64 个 VGPR 可以维持 4 个 resident waves, 65 个 VGPR 则只能维持 3 个. 把 pressure 从 70 降到 66 可能完全不改变 occupancy, 从 65 降到 64 却可能产生明显差异.

这使 GPU scheduler 和 allocator 关心 occupancy threshold, 而不只关心 raw register count. 如果当前 pressure 已经远低于下一个 threshold, scheduler 可以更积极地提前 independent operations, 用较长 live ranges换取 ILP:

```text
load a
load b
load c

compute a
compute b
compute c
```

当 pressure 接近 cliff 时, 同样的 scheduler 可能更倾向于把 definition 靠近 use:

```text
load a
compute a

load b
compute b
```

这种策略降低 peak pressure, 但也减少同时进行的 independent work. 所以 GPU 上 ILP 和 occupancy 经常形成直接竞争.

Spilling 也不能脱离 occupancy 评价. 一个 allocator 可以通过 spill 把 VGPR count 从 65 压到 64, 获得一个额外 resident wave. 如果只产生少量 scratch traffic, 最终吞吐可能提高. 如果为了这一点引入大量 scratch loads/stores, 更多 occupancy 也可能无法弥补 memory cost.

AMDGPU 还存在多维 register pressure. SGPR, VGPR 和 AGPR 消耗不同资源, uniformity analysis 可以把某些 wave-uniform values 从 VGPR 转移到 SGPR. 当 VGPR 是 occupancy bottleneck 而 SGPR 仍然宽松时, 这种 scalarization非常有效. 如果 SGPR 自己已经接近限制, 继续转移只是把瓶颈换了位置.

因此 GPU pressure 更适合看成一个向量, 例如 $(P_{\mathrm{SGPR}},P_{\mathrm{VGPR}},P_{\mathrm{AGPR}})$. Hardware resource model 再把这个向量映射成能够同时驻留的 waves 数量. Scheduler, register-bank selection 和 allocator 的决策都应该围绕这个整体资源状态展开.

这也是 GPU RA 与 CPU RA 在高级优化阶段最大的差异之一. CPU 上 register count 更多表现为局部代码生成成本, GPU 上 maximum register usage 还能变成 kernel-level execution capacity.

## 6 Machine Learning Guided Register Allocation

Register allocation 长期依赖大量人工设计的 heuristics. Spill weight 决定哪些 live ranges 更值得保留, allocation priority 决定先处理谁, eviction heuristic 决定是否撤销已有 assignment, splitting heuristic 决定在哪里切开 live range, coalescing heuristic 则需要估计删除 COPY 与增加 register pressure 之间的收益. 这些决策都受到 CFG, block frequency, live-range shape, register class, call crossing 和 target architecture 的共同影响. 手工 heuristic 可以稳定运行, 但随着状态维度增加, 很难用一个简单公式完整描述 "在这种程序结构和机器上哪一个决策最终产生更快的代码". Register allocation 因而成为 machine learning 进入 compiler backend 的一个自然位置. LLVM 的 MLGO 就把 register allocation 的 Greedy eviction heuristic 作为 ML-guided optimization 的应用之一.

RA 同时有一个很适合 compiler ML 的结构: allocation quality 可以交给 learned policy 预测, machine legality 却可以继续由传统编译器精确维护. 假设 allocator 在状态 $s$ 下存在一组候选动作 $A(s)$, compiler 可以先根据 register class, interference, subregister alias, fixed-register constraint 等信息计算合法集合 $A_{\mathrm{legal}}(s)$, 模型只在这个集合中选择 $a=\pi(s)$. 这样模型可以学习 "哪一个合法选择更好", 却没有权力产生一个明显违反 ISA constraint 的 assignment. RL4ReAl 对 register type, physical-register congruence 和 interference 都建立了显式约束, 并通过限制 agent 的 action space 保证 coloring action 属于合法 register 集合.

```text
allocator state
      |
      v
feature / graph representation
      |
      v
learned policy
      |
      v
choose an action
      |
      v
compiler legality constraints
      |
      v
update allocation state
      |
      +--------------------> next decision
```

LLVM MLGO 对 Greedy allocator 的改造很好地体现了这种思路. 第九部分已经看到, Greedy 为一个 live interval 尝试 physical register 时, 如果该 register 已经被其他 virtual live ranges 占据, allocator 可以考虑 eviction. 手工 Greedy 需要根据 interfering intervals 的 spill weight, hints 和其他状态判断某个候选 register 是否值得争夺. MLGO 没有重新设计一套 register allocator, 而是在这个 decision point 引入 `RegAllocEvictionAdvisor`: Greedy 仍然负责 `LiveInterval`, `LiveRegMatrix`, candidate physical registers, splitting, spilling 和 allocation state 的维护, advisor 负责从可行 eviction choices 中作出策略选择. LLVM 的 ML eviction implementation 使用 `MLModelRunner` 接收特征, 模型输出的 decision 名为 `index_to_evict`, 然后 allocator继续执行相应的 eviction 流程.


```text
                    LLVM Greedy

LiveInterval
    |
    v
try physical register R
    |
    v
find interference
    |
    v
+-------------------------------+
| RegAllocEvictionAdvisor       |
|                               |
| allocator state -> ML model   |
|                  -> decision  |
+-------------------------------+
    |
    v
evict / reject candidate
    |
    v
Greedy continues
    |
    +--> splitting
    +--> recoloring
    +--> spilling
```

这种做法的工程价值在于可以替换一个复杂 heuristic, 同时保留几十年积累下来的 allocator infrastructure. 如果模型选择了一次收益不佳的 eviction, 结果通常表现为代码质量下降; interference checking 和 Machine IR legality 并不会因为预测模型本身缺少形式化理解而一起消失. ML model 因而更像 allocator 中的 advisor, 而不是拥有全部 machine-state authority 的 code generator. LLVM CodeGen 对 learned RA decision 也采用这种 advisor abstraction.

真正困难的是怎样表示 allocator state. 一个 eviction decision 的价值不只取决于当前 interval 和 victim 的长度. 长 live range 可能只在冷 block 中发生 conflict, spill weight 高的 interval 也可能拥有便宜的 rematerialization, 一个 victim 被 eviction 后还可能重新进入 queue 并驱逐其他 intervals. 模型需要从有限 feature vector 中捕获这些后续效应. LLVM 的 ML RA infrastructure 会向模型提供 live-range 和 interference 相关的数据, 并能够利用 MachineBlockFrequencyInfo, MachineLoopInfo 和 register-allocation state 等 CodeGen 信息. 这种 structured-feature 方法的优点是 inference 很轻, 也容易嵌入已有 allocator; 缺点是模型只能利用 compiler writer 预先选择出来的状态描述.

RL4ReAl 选择了更大的学习边界. 它没有只学习 Greedy 的某一个 heuristic, 而是把 register allocation 建模成 hierarchical multi-agent reinforcement learning. LLVM Machine IR 被转换成 interference graph, graph 中的 machine-level entities 使用 MIR2Vec 表示, 然后多个 agents 协同完成 node selection, task selection, live-range splitting 和 coloring. Coloring agent 在没有合法 register 时也负责进入 spilling decision. Splitter 选择 live range 的 split point, compiler按照这个选择真正修改程序, 更新后的 interference graph 再返回给 policy继续决策.

其控制过程可以近似理解成:

```text
interference graph
        |
        v
   Node Selector
        |
        v
   Task Selector
      /      \
     v        v
 Coloring   Splitting
    |           |
    |           v
    |      modify live range
    |           |
    +-----------+
        |
        v
updated interference graph
        |
        v
next RL decision
```

RL4ReAl 的 coloring action 并不是任意预测一个 register number. Compiler 根据 virtual register type, physical-register overlap 和 interference 计算合法 register 集合, coloring agent 从这个集合中选择 assignment; 如果集合为空则产生 spill. Splitting agent 则根据 value representation, 各 use 位置的 spill weight 和 use distances 选择 split point. 这种设计把第四部分的 coloring, 第六部分的 splitting 以及 spill selection放进了一个连续决策过程, 因而能够学习传统 allocator 中多个 heuristics 之间的相互作用. 论文在 x86-64 和 AArch64 上使用 SPEC CPU 2006/2017 进行实验, 并报告其方案能够达到或超过所比较的 LLVM production allocators.

从 ML 的角度看, RA 比普通 classification 问题更接近 sequential decision making. 假设 allocator 在时间 $t$ 做出 assignment $a_t$, 这个选择会改变后面的 interference state $s_{t+1}$; 一次不理想的 eviction 可能直到几十次 allocation decisions 后才导致 spill. 最终程序运行时间更是所有 decisions 共同作用的结果. 因此单独给每个 decision 构造一个精确的 supervised-learning label 很困难. RL 可以通过 reward 学习长期效果, 但同时引入 credit assignment 和训练成本问题. RL4ReAl 采用 hierarchical agents 和局部 reward, 其中 coloring reward与 LLVM 计算的 spill weight 联系, splitting reward则利用 splitting 前后 spill-weight state 的变化, 再配合 global reward协调不同 agents.

Machine learning 还可以把学习边界继续推向完整 assignment. VeriLocc 研究了利用 LLM 直接进行 GPU register allocation: 模型从 machine-level representation 生成 target-specific register assignments, static analysis负责跨架构表示与约束信息, 随后 verifier检查生成结果; 验证失败时重新生成 assignment. 这与 advisor 模式相比已经接近 end-to-end learned allocator, 但 correctness 仍然由独立 verifier兜底. 该工作的实验集中在 GPU GEMM 和 multi-head attention kernels, 论文报告 85%-99% 的 single-shot valid allocation rate, `pass@100` 接近 100%, 并在部分 case study 中得到超过 rocBLAS 10% 的运行时间改善. 这些结果说明 learned policy 可以探索人工 heuristic 不容易覆盖的 assignment space, 同时也说明 verifier 在生成式 allocator 中承担了不可缺少的角色.


```text
hand-written allocator
        |
        v
learn one heuristic
MLGO eviction advisor
        |
        v
learn several interacting decisions
RL4ReAl
        |
        v
predict complete assignments
VeriLocc-style generation
```

学习边界越大, 模型能够重新发现的策略越多, 需要解决的训练和工程问题也随之扩大. Eviction advisor 每次只处理 Greedy 已经构造好的局部 decision point, feature 和 action space都相对受控. 完整 learned allocator 必须面对 live-range splitting带来的动态图变化, machine constraints, architecture portability以及长序列 decision 的 reward attribution. 如果进一步直接生成完整 assignment, verifier成本和失败后的搜索策略又成为整个系统的一部分.

RA 中的 ML 还受到一个非常现实的约束: inference 本身属于 compiler compile-time. 一个运行数毫秒的模型如果在一次函数 allocation 中调用数千次, 总成本很容易超过原来的 heuristic. 同时, training distribution 与真实 workload 之间可能存在差异, architecture变化也会改变 register classes, instruction constraints 和 spill costs. 因此高质量 learned allocator 不能只追求 benchmark 上的 reward, 还需要考虑模型尺寸, inference frequency, feature extraction cost, generalization以及 fallback behavior.

从编译器架构的角度看, 最有价值的模式仍然是把精确分析和 learned decision结合起来. Liveness, interference, register class和machine legality继续由确定性算法计算, ML 处理那些具有巨大搜索空间并长期依赖人工 heuristic 的 optimization choices. 这种划分既可以像 MLGO 一样只替换 Greedy 的 eviction policy, 也可以像 RL4ReAl 一样扩大到 splitting 和 coloring, 再进一步发展成带 verifier 的完整 assignment generation. Register allocation 因此也是观察 "ML 怎样真正进入工业编译器" 的一个很好的案例: ML 并不需要替代整个 compiler backend, 它首先可以替代 backend 中最难手工调优的决策函数.

## 7 怎样评价 Register Allocation

一个 register allocator 不能只通过 "spill 了多少 virtual registers" 来评价. Spill 的动态位置, reload folding, COPY 数量, frame size, callee-saved register使用情况以及 scheduler interaction 都会影响最终代码. GPU 还需要把 register count, scratch traffic 和 occupancy一起看.

Compile-time evaluation 首先需要测 allocator 自身的开销. 对大型函数来说, interference queries, splitting, recoloring 或 graph construction 都可能显著消耗时间和内存. 一个 allocator 在 benchmark 上得到少量 runtime improvement, 如果后端编译时间增加很多, 是否值得采用取决于编译器的使用场景. JIT, interactive build 和离线 HPC compiler 对这种 trade-off 的接受程度完全不同.

Generated-code evaluation 则至少要同时观察静态和动态结果. Static metrics 可以包括 code size, COPY 数量, spill stores, reloads, stack frame size 和 callee-saved register使用数量. Runtime measurement 才能判断这些变化经过 processor pipeline 和 memory hierarchy 后是否真正有收益.

GPU 还应记录 per-thread register usage, scratch/local memory usage 和 occupancy-related resource data. 一个新的 allocator把 VGPR 从 72 降到 68 如果没有跨过任何 occupancy threshold, 这项变化本身可能意义有限. 如果从 65 降到 64 恰好增加一个 resident wave, 即使 register count只减少一个, 影响也可能更大.

Benchmark 需要覆盖不同的 allocation difficulty. Straight-line arithmetic主要测试 local assignment 和 machine constraints. 大型 CFG 更容易暴露 global liveness 和 splitting 问题. Loop-heavy code会放大 hot-path spill placement. Vectorized code可以制造宽 register class pressure. 调用密集函数则适合测试 caller/callee-saved decisions. GPU kernel还需要区分 compute-bound, memory-latency-bound 和 occupancy-sensitive workloads.

微基准可以专门隔离某个机制. 例如构造许多同时 live 的 values 测试 spill heuristic:

```text
v1 = ...
v2 = ...
v3 = ...
v4 = ...
...
use v1
use v2
use v3
use v4
```

构造一条长 global live range与大量短 local ranges可以观察 allocation order和eviction:

```text
global:
|----------------------------------------------|

local1:    |---|
local2:          |---|
local3:                |---|
local4:                      |---|
```

大量 COPY 可以测试 coalescing, fixed-register instructions 可以测试 machine constraints, loop boundary 上的冲突则可以测试 splitting是否把 transfer放到了合理位置.

真实应用 benchmark 仍然不可替代. 微基准能够证明某个机制按照预期工作, 无法告诉我们多个 heuristics结合以后是否在完整程序中稳定获益. 一个 allocator可能在多数程序上变化很小, 却在少数 high-pressure workloads上产生大幅退化. 这些 outliers 往往最有分析价值, 因为它们能暴露 cost model, splitting strategy 或 machine constraint handling 中的系统性问题.

因此评价 RA 更适合看一组相互关联的数据: compile time, code size, spills, copies, register pressure, runtime, 以及 GPU 上的 occupancy 和 scratch traffic. 最终目标仍然是机器代码的整体性能, allocator内部某一个统计数字只能解释这个结果的一部分.

到这里, register allocation 的算法, 工业实现和跨阶段优化已经形成一套相对完整体系. 第十二部分将脱离概念综述, 从一个最小 Machine IR 开始真正实现一个 register allocator: 先建立 CFG 和 liveness, 再构造 live ranges 与 interference, 完成一个可以工作的基础 allocator, 加入 spill rewrite, 最后逐步扩展到 coalescing, register classes 和更真实的机器约束.
