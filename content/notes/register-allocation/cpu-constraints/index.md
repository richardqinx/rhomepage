---
title: "第八部分: 真实 CPU 体系结构约束"
slug: "cpu-constraints"
lang: zh-Hans
series: register-allocation
weight: 90
created: 2026-08-18
updated: 2026-09-09
license: CC-BY-SA-4.0
---

前面的 graph coloring 和 Linear Scan 都从一个相对理想化的模型出发. 假设机器有 $K$ 个物理寄存器, 每个 virtual register 都可以从这 $K$ 个寄存器中任选一个, 相邻 live ranges 只需要保证颜色不同. 这个模型足以解释 interference, spilling, coalescing 和 splitting 的基本原理, 但真实 CPU 的 register file 很少具有这种完全对称的结构.

一条机器指令可能只接受某个 register class, 某些 operands 必须使用固定 physical register, 一组不同名字的寄存器可能实际覆盖同一片硬件存储, function call 会破坏一部分 registers, two-address instruction 又可能要求 input 和 output 使用同一个 register. 此外, 某些 operand 还需要连续寄存器, register pair, 特定对齐或特殊 subregister.

因此工业 register allocation 面对的已经不只是 "$K$ 个等价颜色上的 graph coloring". 每个 allocation object 都可能拥有自己的合法寄存器集合, 不同 physical registers 之间存在 overlap, 某些程序位置还会临时禁止一部分 registers. Register allocator 必须把这些 ISA 和 ABI 约束一起纳入 allocation.

## 1 Register Class 与不对称的颜色集合

最直接的机器约束来自 register class.

以典型 CPU 为例, integer arithmetic 使用 general-purpose registers, floating-point 和 SIMD instructions 使用 vector registers. 一个整数 virtual register 不能因为 GPR 不够用就随意放到 vector register 中, 反过来也一样. 即使底层硬件拥有很多 register bits, ISA 允许某条 instruction 使用哪些寄存器仍然受到 operand encoding 和 instruction semantics 限制.

因此对 virtual register $v$, allocator 实际面对的不是统一的 $K$ 个颜色, 而是一个合法 physical register 集合 $C(v)$. Assignment 至少必须满足 $color(v)\in C(v)$.

例如某台抽象机器有:

```text
GPR:
R0 R1 R2 R3

Vector:
V0 V1 V2 V3 V4 V5 V6 V7
```

如果 `v1` 是 integer value, 它的 candidate set 可能是 ${R0,R1,R2,R3}$. 如果 `v2` 是 vector value, candidate set 则是 ${V0,\ldots,V7}$. 即使 `v1` 和 `v2` 在同一个程序位置同时 live, 它们也未必竞争同一份物理资源, 所以简单计算 "总共有多少 live values" 已经不能准确表示 register pressure.

更复杂的情况是 register classes 可以部分重叠. 某些 instruction 接受一个较大的 class, 另一些 instruction 只接受其中的子集. 假设机器有八个 general-purpose registers, 但某条特殊 instruction 只能编码 `R0-R3`, 那么参与这条 instruction 的 operand 在那个位置附近实际受到更严格的约束.

这会改变 graph coloring 的数学模型. 经典 $K$-coloring 假设所有节点共享同一个颜色集合. 每个节点拥有自己的 candidate set 后, 问题更接近 list coloring. 两个 degree 完全相同的 virtual registers, 如果一个有 12 个候选物理寄存器, 另一个只有 2 个, allocation difficulty 显然不同.

所以工业 allocator 在判断 "这个 live range 难不难分配" 时, degree 或 live range overlap 只是其中一部分. Register class 大小, 当前被占用的 candidate registers, target instruction constraints 和 register hints 都会影响实际可分配性.

Register class 还会改变 spill 的意义. 某个大 register class 仍有很多空闲资源, 并不能帮助另一个已经超压的小 register class. Register pressure 因而通常需要按照不同 register resources 分别追踪.

## 2 Fixed Register, Pre-colored Value 与 Calling Convention

有些机器值在进入 allocator 之前就已经确定了 physical register. Graph-coloring 文献通常把这种节点称为 pre-colored node.

Calling convention 是最常见的来源之一. 函数参数, 返回值和某些特殊 runtime state 会按照 ABI 放在指定 registers 中. 例如一个返回值可能要求位于某个固定 GPR, allocator 不能随意把最终 return operand 放到另外一个寄存器然后假设调用者能够理解.

机器指令自身也会产生 fixed-register constraints. x86 的一些指令是典型例子. 整数除法会隐式使用固定的 accumulator 和 high-half registers. 传统 variable shift 指令的 shift count 可能要求位于 `CL`. 这些 instructions 让某个程序位置上的 register availability 突然发生变化.

假设有一个 live range `v` 跨过某条必须使用 `R0` 的 instruction:

```text
v:
|------------------------------|

                  fixed R0 use
                       |
                       v
-----------------------X--------
```

如果 `v` 自己被分配到 `R0`, allocator 就必须确认它和这个 fixed use 是否能够合法共存. 如果固定指令会破坏 `R0`, `v` 就不能无条件跨过该位置继续保存在 `R0`. 一种方案是选择其他 physical register, 另一种方案是在固定使用周围 split `v`.

Linear Scan 可以把这种约束表示成 physical register 的 fixed interval. Graph-based allocator 可以把 physical register 视为 pre-colored object, 再建立相应 interference. 工业实现的数据结构不同, 表达的机器事实是一样的: 某些物理资源在特定位置已经被机器语义占用.

Function call 把这种问题扩展到了 ABI 层面. 大多数 ABI 会把 registers 分成 caller-saved 和 callee-saved 两类. Caller-saved register 可以被被调用函数自由破坏, 因此一个跨 call live 的 value 如果放在这种 register 中, 当前函数需要在 call 周围保存它, 或通过其他方式保证值不丢失.

```text
v = ...
...
call foo
...
use v
```

如果 `v` 被分配到一个会被 `foo` 破坏的 caller-saved register, allocator 可能需要:

```text
store [slot], R0
call foo
load R0, [slot]
```

如果把 `v` 放进 callee-saved register, 它可以自然跨越 call, 但当前函数一旦使用这个 callee-saved register, 通常就需要在 prologue 和 epilogue 中保存和恢复它.

因此 caller-saved 和 callee-saved 并不是简单的 "坏寄存器" 和 "好寄存器". 一个很短且不跨 call 的 value 使用 caller-saved register 通常很自然. 一个跨越多个 calls 的长 live range 可能更适合 callee-saved register. 如果整个函数只为了一个很冷的 value 使用一次新的 callee-saved register, prologue/epilogue 成本又可能超过局部 spill 的成本.

Physical registers 因而开始具有不同的 assignment cost. 从这个阶段开始, register allocation 已经不能只问 "哪个颜色合法", 还要问 "合法颜色中哪个更便宜".

## 3 Subregister 与 Physical Register Aliasing

真实 register file 中另一个会破坏简单 coloring 模型的结构是 aliasing.

x86 的 `RAX`, `EAX`, `AX` 和 `AL` 是最熟悉的例子. 它们拥有不同的 architectural names 和 operand widths, 但覆盖的是同一个物理寄存器的不同部分:

```text
RAX: |------------------------------- 64 bits -------------------------------|

EAX:                                 |------------- 32 bits -----------------|

 AX:                                                 |------ 16 bits --------|

 AL:                                                        |-- 8 bits -----|
```

所以如果一个 live value 占用了 `RAX`, 另一个同时 live 的 value就不能独立占用 `EAX` 或 `AX`. 从寄存器分配角度看, 这些 names 不是互不相关的颜色.

AArch64 的 `X0` 和 `W0` 也存在类似的资源关系. SIMD ISA 中还可能出现不同宽度 register views 共享相同底层存储的情况. 对 x86 AVX 系列来说, `XMM0`, `YMM0` 和 `ZMM0` 也对应不同宽度的重叠 register views.

因此物理冲突更准确的条件不是 "两个 values 是否被分配到同一个 register name", 而是它们所占用的底层 register resources 是否 overlap. 如果用 $Units(r)$ 表示 physical register $r$ 占用的硬件资源集合, 两个同时 live 的 values $u$ 和 $v$ 至少需要满足 $Units(color(u))\cap Units(color(v))=\varnothing$.

这会让 register allocation 的 interference 检查明显复杂起来. 假设一个 value 可以分配到 `EAX`, 另一个 value 可以分配到 `RAX`. 两个 candidate names 不同, 但不能同时使用. allocator 因而通常需要维护 physical-register overlap relation 或更细的 register units, 而不是只比较 register number.

Subregister 还带来读写语义问题. 以 x86 为例, 写 `EAX` 会把 `RAX` 的高 32 位清零, 因而这种写操作不仅覆盖低 32 位. 写更小的 subregister 又可能保留其余 bits. 所以 "哪些 names alias" 和 "一次 definition 实际覆盖哪些 bits" 并不总是同一个简单问题.

后端通常通过 target-specific register description 表达这些关系. Register allocator需要知道哪些 assignments 会发生物理冲突, 后续 liveness 和 dead-def analysis 还要理解不同 subregister definitions 对 super-register value 的影响.

这一层机器语义也说明了为什么 source-level type width 不能直接决定一个 value 占用多少 register resource. 一个 32-bit value放在 `EAX` 时, 对 register allocation 来说通常已经占据了 `RAX` 对应的那份 GPR 资源, 不存在另一个同时 live 的 32-bit value 可以偷偷使用 `RAX` 的高半部分.

## 4 Tied Operand, Two-address Instruction 与 Early-clobber

前面讨论的 interference 大多来自不同 values 的生命周期重叠. ISA 还可以直接规定几个 operands 之间必须满足某种位置关系.

Two-address instruction 是典型情况. 一个三地址抽象操作可以写成:

```text
v3 = ADD v1, v2
```

某些 ISA 或具体 instruction encoding 则要求 destination 与一个 source 使用同一个 physical register:

```text
R0 = ADD R0, R1
```

在 machine IR 中, 这通常表现为 output operand 和某个 input operand tied. 如果进入这条 instruction 时有 `v1` 和 `v2`, 结果是 `v3`, allocator希望满足类似 $color(v_3)=color(v_1)$ 的 tied constraint.

如果 `v1` 在 instruction 后仍然 live, 问题就会出现. Destination 覆盖 `v1` 以后, 后续 use 会失去旧值. Compiler 可能需要提前复制:

```text
tmp = COPY v1
tmp = ADD tmp, v2
...
use v1
```

这样 `tmp` 可以和 result 共用 physical register, 原来的 `v1` 继续保存在别处.

所以 tied operand 与第五部分的普通 coalescing preference 不完全一样. 普通 COPY 两端希望同色, 失败后通常只是留下 move. Tied operand 是机器 instruction legality 的一部分, allocator 或之前的 lowering 必须保证最终满足这个关系.

Early-clobber 则产生相反方向的额外 interference. 对普通 instruction, allocator 往往可以认为所有 inputs 先被读取, output 随后才写入. 如果一个 input 在这条 instruction 后死亡, destination 有时可以复用这个 input 的 register.

Early-clobber operand 会更早写入 destination, 早到某些 inputs 尚未全部读取. 于是 destination 不能和那些 inputs 使用同一个 physical register, 即使从普通 instruction-boundary liveness 看, input 的生命周期似乎正好在这里结束.

可以用一个抽象 instruction 表示:

```text
early-def dst, use src1, use src2
```

假设 `dst` 在 instruction 执行早期就被覆盖, 而 `src2` 到更晚的阶段才读取. 那么 `dst` 和 `src2` 必须分配不同的物理资源. 这种冲突来自 instruction 内部的 operand timing, 单纯使用 "指令前 live / 指令后 live" 两个边界不足以表达.

这也是前面提到 machine position 需要细分的原因. Register allocator必须能够理解 ordinary use, early use, normal def, early-clobber def 等不同时间点, 否则会产生在抽象 liveness 上看似合法, 实际 ISA 无法执行的 assignment.

Implicit use 和 implicit def 也属于同一类机器约束. 某些 instruction encoding 没有把 register 明写在 operand list 中, 但架构语义仍然会读取或修改它. Register allocator必须把这些隐含 effects 纳入 physical-register liveness.

## 5 Register Pair, Multiple-register Operand 与组合资源

简单 coloring 还假设一个 value 对应一个 physical register. 某些机器操作需要同时占据多个寄存器.

一个常见来源是 value width 超过单个 register width. 在 32-bit target 上处理 64-bit 或更宽整数时, 一个 logical value 可能被拆成多个 machine values. 某些 ISA 或 calling convention 还会要求它们使用特定 pair 或具有特定排列关系.

另一些 instruction 本身就操作 register pairs. x86 的某些 multiply/divide 语义会把结果或输入分布在固定的一对 registers 中. 其他架构还可能要求一组 operands 使用连续 registers, even-odd pair 或满足一定 alignment.

这时 allocator 的 assignment unit 不再总是单个颜色. 假设某个 virtual object 需要一对 consecutive registers, 候选方案可能是:

```text
(R0, R1)
(R2, R3)
(R4, R5)
```

即使当前还有两个空闲寄存器, 如果它们是 `R1` 和 `R4`, 也无法满足这个 allocation object 的要求.

组合资源使 register pressure 更加具有结构性. "还有几个寄存器空闲" 不足以判断一个 tuple 是否能放下, allocator还需要知道空闲资源的具体形状. 这也是某些 target 上 fragmentation 会影响 allocation 的原因: 总空闲容量足够, 合法组合却已经不存在.

CPU 上这种问题的复杂程度因 ISA 而异. 到 GPU 部分还会看到更明显的 tuple constraints 和不同 register files, 但基本思想相同: allocator分配的不一定是单个独立 register name, 也可能是一组必须同时满足结构要求的硬件资源.

## 6 Machine Constraint 如何改变 Spill 与 Split

当 allocation 失败时, spilling 也必须服从 target ISA. 把一个 value 标记为 "memory" 并不能自动解决所有问题, 因为很多 machine instructions 不允许任意 operand直接来自 memory.

假设:

```text
v3 = ADD v1, v2
```

如果目标 instruction 要求两个 inputs 都在 registers 中, spill `v1` 后仍然必须在 use 前产生 reload:

```text
t1 = load [slot]
v3 = ADD t1, v2
```

`t1` 又形成一个新的短 live range, 仍然需要 physical register. 所以 spill 没有消除寄存器需求, 它只是把一个长时间占据资源的 value 转换成 use 附近的短期需求.

某些 ISA 允许 memory operand. 例如一条 arithmetic instruction 可能允许一个 source 直接来自内存. 这时 spill rewrite 有机会把 reload folding 进原来的 machine instruction, 减少显式 load. 这种收益完全依赖 instruction encoding 和 target cost model.

Live range splitting 同样可以围绕机器约束进行. 如果一个长 live range 大部分时间可以使用任意 GPR, 但在一个局部区域必须进入特定 register subset, allocator 可以在这个区域附近 split:

```text
general class        restricted class        general class
|----------------|----------------------|------------------|
```

不同 fragments 分别选择最合适的 physical register, 边界之间通过 COPY 连接. 如果 allocation 恰好让相邻 fragments 得到同一个 register, COPY 可以被消除.

Function call 周围也是常见 split point. 一个 value 在 call 之前和之后都需要使用, 但跨 call 保存在某个 register 中代价很高, allocator可以把 live range 在 call 附近切开. 前一段使用 caller-saved register, call 时临时进入 stack, 后一段 reload 到另一个 register. 对只跨少数 calls 的 value, 这种局部决策可能比占用 callee-saved register 整个函数更便宜.

Rematerialization 也会受到 target instruction cost 影响. 如果某个 value 是一个便宜的 immediate 或简单地址计算, 在 use 处重新生成可能比真正 reload 更合适. 对 register allocator来说, 这相当于把 memory spill cost 替换成一段 machine computation cost.

所以 machine constraints 并没有只增加 "哪些寄存器可以用" 这一层限制. 它们还会改变 spill placement, split point, copy elimination 和 rematerialization 的成本模型.

## 7 从 K-coloring 到真实 Machine Allocation

经过这些约束以后, textbook coloring 模型仍然有价值, 但需要重新理解其中的 "颜色".

对简单 graph coloring, 每个节点从同一集合 ${R_0,\ldots,R_{K-1}}$ 中选择一个颜色, interference edge $(u,v)$ 要求 $color(u)\neq color(v)$.

真实机器上, 每个 value $v$ 有自己的 candidate set $C(v)$; physical registers 之间可能 alias; 某些 instruction positions 存在 fixed uses 和 clobbers; tied operands 会要求两个 values 获得相同或相关 assignment; early-clobber 又会制造额外的局部 interference; 某些 objects 甚至需要一次分配多个 physical registers.

因此一条 interference edge 最终表达的机器条件更接近: 两个同时 live 的 allocation objects 不能占用重叠的 physical register resources. 如果两个 register names 不同但底层 units overlap, assignment 仍然非法.

Graph coloring allocator 可以通过 register classes, pre-colored nodes, special interference 和 target-specific constraints 扩展这个模型. Linear Scan 可以通过 candidate sets, fixed intervals 和位置约束实现类似功能. Priority-based allocator还可以在遇到冲突时尝试 eviction, splitting 和重新排队.

这也是接下来进入 LLVM 和 GCC 工业实现时需要注意的. LLVM Greedy 不会把整个问题真的展开成一张 textbook interference graph, 但它仍然必须回答本章的所有机器问题: virtual register 属于哪个 register class, 某个 physical register 是否与当前 live interval overlap, subregister alias 如何计算, fixed interference 在哪里, tied operand 如何满足, call clobber 如何建模, splitting 后 fragment 可以使用哪些 registers.

GCC IRA 和 LRA 则把其中一部分问题分成两个阶段. IRA 更侧重全局 allocation 和 register pressure, LRA 更靠近机器 instruction constraints, reload 和最终 hard-register assignment. 这种架构上的差异会在下一部分具体展开.
