---
title: "第一部分：寄存器分配问题与基本模型"
slug: "fundamentals"
lang: zh-Hans
series: register-allocation
weight: 20
created: 2026-08-09
updated: 2026-09-09
license: CC-BY-SA-4.0
---

## 1. 从虚拟寄存器到物理寄存器

编译器进入后端以后,  会逐渐把源语言里的表达式, 变量和控制流降低成越来越接近目标机器的形式. 到了指令选择之后, 程序通常已经表现为机器指令或者准机器指令, 但这些指令里使用的寄存器仍然常常是**虚拟寄存器**.

例如, 一个中间结果可能被表示成:

```text
%v1 = ADD %v2,   %v3
%v4 = MUL %v1,   %v5
%v6 = SUB %v4,   %v1
```

这里的 `%v1`, `%v2`, `%v3` 等都可以理解为虚拟寄存器. 编译器可以创建任意多个这样的名字, 因此在这一层上, 程序暂时不需要关心目标 CPU 到底只有多少个真实寄存器.

这种设计很重要. 假如编译器从很早的阶段开始就强迫所有中间值使用真实寄存器, 那么几乎每一次代码移动, 公共子表达式消除, 循环优化, 指令选择都会受到具体寄存器数量的牵制. 虚拟寄存器提供了一层抽象, 使前面的优化阶段可以先专注于数据依赖和程序语义.

到了真正生成机器代码的时候, 这层抽象必须被消除.

假设目标机器只有:

```text
R0
R1
R2
R3
```

四个可以使用的通用寄存器, 那么所有仍然存活的虚拟寄存器最终都必须找到实际存储位置. 某些虚拟寄存器会被映射到 `R0`, 某些会映射到 `R1`. 两个生命周期互不重叠的虚拟寄存器还可以在不同时间复用同一个物理寄存器.

因此,  寄存器分配最核心的问题总结起来就是

> 给程序中的值安排物理寄存器,  使所有机器约束得到满足, 并尽可能降低由于寄存器不足带来的执行代价.

---

## 2. Register Allocation, Register Assignment 与 Spilling

"Register Allocation" 这个词在不同文献和编译器中使用得并不完全一致.

从理论上细分时, 经常会区分两个问题.

**Register Allocation** 决定某个值在某段生命周期中是否应该驻留在寄存器里.

**Register Assignment** 决定已经确定要放进寄存器的值具体使用哪一个物理寄存器.

例如:

```text
v1 → R2
v2 → R0
v3 → R2
```

这里 `v1` 和 `v3` 可以同时使用 `R2`, 前提是它们的生命周期没有发生重叠.

工业编译器中,  "register allocation" 往往用作整个过程的总称, 其中通常会同时包含分配, 具体寄存器选择, spill, live range splitting, coalescing, rematerialization 等步骤. 因此以后我们讨论 LLVM 的 Greedy Register Allocator 或 GCC IRA 时, 使用的基本也是这个宽泛含义.

真正困难的情况出现在同时需要保留的值数量超过可用物理寄存器数量时.

假设某段程序中同时存活"

```text
a
b
c
d
e
```

而当前只能使用:

```text
R0
R1
R2
R3
```

那么五个值不可能全部同时驻留在这四个寄存器中.

编译器需要让其中至少一个值暂时离开寄存器. 最经典的方法是把它保存到栈上的一个位置中:

```text
store [spill_slot],   R1
```

稍后再次需要这个值时, 再把它读取回来:

```text
load R1,   [spill_slot]
```

这个过程称为 **spilling**.

被写入内存的值通常称为 spilled value, 相应的内存位置常称为 spill slot.

因此, 寄存器分配从一开始就包含两个彼此相关的决定:

```text
哪些值值得留在寄存器里?

留下来的值应该使用哪个寄存器?
```

后面我们会看到, 很多经典算法虽然在形式上强调 "给冲突图着色", 实际的算法质量往往很大程度取决于第二层以外的问题: 什么时候 spill, spill 谁, 什么时候 split, 一个已经分配好的值是否应该被另一个值赶出寄存器.

---

## 3. 为什么不同虚拟寄存器可以共享同一个物理寄存器

寄存器分配能够成立的关键, 在于一个函数中虽然可能出现上百甚至上千个虚拟寄存器, 但它们通常不会全部同时需要保存.

考虑如下程序:

```text
v1 = a + b
v2 = v1 * 2

v3 = c + d
v4 = v3 * 4
```

假设 `v1` 在第二条指令之后再也不会使用, 那么执行到:

```text
v3 = c + d
```

时, 保存 `v1` 的寄存器已经可以重新利用.

于是完全可能得到:

```text
v1 → R0
v3 → R0
```

这两个虚拟寄存器虽然名字不同, 却可以共享一个物理寄存器.

决定它们能否共享寄存器的核心概念, 就是**活跃性**.

一个值从定义开始, 到最后一次可能被使用的程序区域, 形成它的生命周期. 只要两个值在某个程序点同时需要保持有效, 它们就存在寄存器资源上的竞争关系.

后面的第二部分会专门研究

```text
Liveness
Live Range
Live Interval
```

第三部分则进一步把这种竞争关系表示成

```text
Interference Graph
```

所以寄存器分配的知识链可以先建立成

```text
程序中的值
    ↓
什么时候仍然需要这个值
    ↓
Liveness
    ↓
哪些值会同时存活
    ↓
Interference
    ↓
哪些值不能共享寄存器
    ↓
Register Allocation
```

如果 "什么时候仍然需要一个值" 这个问题没有解决, 寄存器分配甚至无法判断两个虚拟寄存器能否安全地映射到同一个物理寄存器.

---

## 4. Register Pressure

由此自然会出现另一个贯穿整个寄存器分配领域的概念: **register pressure**, 也就是寄存器压力.

在一个程序点上, 如果有十个值同时需要保持有效, 那么可以直观地说, 这个位置产生了大约十个值的寄存器需求.

如果机器在这一类值上只有八个可用寄存器:

```text
需要的 live values：10
可用 registers：     8
```

这里就出现了明显的资源紧张.

在现代编译器中实现还要考虑 register class, 固定寄存器, 别名关系以及某些寄存器暂时不可用等情况, 因此 register pressure 不能永远简单理解为"活跃变量数量". 然而这个直觉非常重要

> 同时存活的值越多,  寄存器分配越困难。

寄存器压力还揭示了一个重要事实: 寄存器分配从来都不完全独立于前面的代码生成过程.

考虑:

```text
a = ...
b = ...
c = ...
use a
use b
use c
```

如果指令调度把 `a`, `b`, `c` 的定义都提前, 那么三个值可能会长时间同时存活.

另一种调度可能形成

```text
a = ...
use a

b = ...
use b

c = ...
use c
```

这时峰值寄存器压力会明显降低.

所以 Instruction Scheduling 会影响 Register Allocation; 反过来, 寄存器压力也会影响调度器应该怎样安排指令.

这也是工业后端中一个非常重要的主题:

```text
Instruction Scheduling
        ↕
Register Pressure
        ↕
Register Allocation
```

到了 GPU 上, 这种关系还会更强. GPU 中每个线程占用的寄存器数量可能直接限制一个计算单元能够同时驻留多少个 warp 或 wave, 因此 register pressure 会进一步影响 occupancy. 这个问题我们会留到 GPU 寄存器分配部分完整展开.

---

## 5. 寄存器分配真正优化的是什么

最容易形成的初始印象是:

> 一个好的寄存器分配器应该尽量减少 spill.

这个方向大体正确, 却还不足以描述真实的优化目标.

首先, 不同 spill 的代价差异可能非常大.

例如:

```text
for (...) {
    use x
}
```

如果 `x` 被 spill, 那么它可能在循环中产生大量动态 load.

另一个只在冷路径上使用一次的值, 即使也发生 spill, 对程序运行时间的影响可能很小.

于是编译器更关心的是:

```text
dynamic spill cost
```

也就是 spill 在实际执行中造成的成本.

这也是为什么真实编译器经常使用 block frequency, loop depth, profile information 等信息来估计某个值有多值得占据寄存器.

其次, 寄存器分配还要考虑 copy.

假设前面的机器 IR 中存在:

```text
v2 = COPY v1
```

如果最终:

```text
v1 → R3
v2 → R3
```

那么这条 copy 很可能完全消失.

这种优化叫做 **coalescing**.

于是一个 allocator 可能需要在两个选择之间权衡:

```text
减少 spill
```

以及:

```text
消除 copy
```

两者有时会互相冲突. 过度合并两个 live range 可能让它们形成一个更大的生命周期, 从而提高寄存器压力, 甚至导致新的 spill.

继续往现实机器靠近, 还会出现更多目标.

例如某个值跨越函数调用:

```text
v = ...
call foo
use v
```

如果把 `v` 放进一个 caller-saved register, 那么函数调用前后可能需要额外保存和恢复.

如果把它安排到一个 callee-saved register, 又可能导致整个函数增加保存和恢复该物理寄存器的 prologue/epilogue 开销.

因此一个寄存器选择本身也具有成本.

最终, 一个工业寄存器分配器实际上面对的是多目标优化问题:

```text
spill cost
copy cost
register preference
calling convention cost
code size
instruction constraints
compile time
```

在 GPU 中还要进一步加入:

```text
occupancy
```

因此评价寄存器分配质量时, 只数 "spill 了多少个虚拟寄存器" 通常是不够的.

---

## 6. 寄存器分配在编译器后端中的位置

从高度抽象的角度, 可以把代码生成流程理解成:

```text
LLVM IR / GIMPLE / other IR
          ↓
Instruction Selection
          ↓
Machine-level IR
          ↓
Register Allocation
          ↓
final machine instructions
          ↓
Machine Code
```

不过真正的后端流水线会复杂得多.

以典型现代编译器为例, 指令选择完成后, 机器 IR 中经常已经出现目标体系结构的指令 opcode, 同时仍然保留虚拟寄存器.

可以想象成:

```text
%0 = ADD64rr %1,   %2
%3 = IMUL64rr %0,   %4
```

这里 `ADD64rr` 和 `IMUL64rr` 已经高度接近真实机器指令, 而 `%0`、`%1`、`%2`、`%3`、`%4` 仍然需要分配.

寄存器分配完成之后,  它们可能变成:

```text
RAX = ADD64rr RBX,   RCX
RDX = IMUL64rr RAX,   RSI
```

到这个阶段, 程序已经从 "拥有任意多虚拟寄存器的机器程序" 转化为 "受真实 ISA 资源限制的机器程序".

Instruction Scheduling 和 RA 的相对顺序需要稍微谨慎处理.

现代后端中经常同时存在:

```text
Pre-RA Scheduling
Register Allocation
Post-RA Scheduling
```

Pre-RA scheduling 仍然可以较自由地移动带虚拟寄存器的指令, 同时需要关注 register pressure.

Post-RA scheduling 面对的已经是物理寄存器, 因此必须遵守更加具体的 hazard 和寄存器依赖.

不同 target, 不同编译器甚至不同优化级别都可能采用不同 pipeline.

不过这样概括地讲是没有问题的:

> 寄存器分配通常工作在已经高度机器化的 IR 上, 它负责把虚拟寄存器世界收缩到真实机器允许的物理寄存器世界中.

---

## 7. 一个完整的小例子

现在用一个很小的程序建立直觉.

假设机器只有两个可用寄存器:

```text
R0
R1
```

程序为:

```text
v1 = load a
v2 = load b

v3 = v1 + v2
v4 = v3 * v1

store v4
```

先观察 `v1`.

它在第一条指令中被定义：

```text
v1 = load a
```

之后在:

```text
v3 = v1 + v2
```

中被使用, 同时在:

```text
v4 = v3 * v1
```

中还要再次使用.

因此, 在计算完 `v3` 之后, `v1` 仍然需要继续保存.

再看 `v2`.

它只在:

```text
v3 = v1 + v2
```

中使用一次. 执行完这条指令以后, `v2` 就不再需要.

于是可以产生一种分配:

```text
v1 → R0
v2 → R1
```

执行:

```text
v3 = v1 + v2
```

以后, `v2` 已经死亡, 因此原来的 `R1` 可以拿给 `v3`:

```text
v3 → R1
```

此时:

```text
R0 = v1
R1 = v3
```

正好满足下一条:

```text
v4 = v3 * v1
```

如果乘法允许结果覆盖其中一个已经死亡的 operand, 那么甚至可以继续复用寄存器.

例如:

```text
v4 → R1
```

最后整个过程可能形成:

```text
v1 → R0
v2 → R1
v3 → R1
v4 → R1
```

四个虚拟寄存器最终只需要两个物理寄存器.

这里最重要的地方是资源复用发生的原因:

```text
v2 死亡
   ↓
R1 释放
   ↓
v3 使用 R1

v3 死亡
   ↓
R1 再次释放
   ↓
v4 使用 R1
```

所以寄存器分配真正管理的是**随程序执行位置变化的资源占用**.

---

## 8. 再加一点压力

现在稍微修改程序:

```text
v1 = load a
v2 = load b

v3 = v1 + v2
v4 = v1 * v2
v5 = v3 + v4

store v5
```

还是只有:

```text
R0
R1
```

两个物理寄存器.

执行完:

```text
v3 = v1 + v2
```

以后, 事情开始变得麻烦.

此时还需要:

```text
v1
v2
v3
```

因为下一条:

```text
v4 = v1 * v2
```

仍然要使用 `v1` 和 `v2`, 而最后的:

```text
v5 = v3 + v4
```

又要求 `v3` 继续保存.

于是这里出现:

```text
3 个 simultaneously live values
2 个 physical registers
```

寄存器资源已经无法同时容纳所有值.

一个简单策略是 spill `v3`:

```text
v3 = v1 + v2
store [slot],   v3

v4 = v1 * v2

load tmp,   [slot]
v5 = tmp + v4
```

当然, 也可能选择 spill `v1` 或 `v2`.

哪一个选择更好, 就开始涉及:

```text
谁以后还会被用多少次?
位于什么控制流路径?
是否处于循环内部?
重新计算它是否比 load 更便宜?
能否切断它的 live range?
有没有别的寄存器可以换出来?
```

这正是寄存器分配算法真正开始发挥作用的位置.

---

## 9. Spill 也未必意味着整个值都长期待在内存里

初学寄存器分配时还有一个很容易形成的简化模型:

```text
v 被 spill
    ↓
v 从此住在 stack
```

实际编译器通常会采取更加细粒度的处理.

例如一个值的生命周期很长:

```text
v:

|-------------------------------|
```

其中只有中间一小段寄存器压力特别大.

那么编译器可能把它切成:

```text
|------|       |----------|
 register        register
        \_______/
          spill
```

也就是说, 一个逻辑值的不同生命周期片段可以分别拥有不同存储位置.

这就是后面非常重要的:

> Live Range Splitting

因此现代 RA 中的 "分配单位" 可能已经细化到 live range 的某一个 fragment, 而不再始终对应完整的源语言变量.

这一点对理解 LLVM Greedy RA 尤其重要. LLVM Greedy 的很多能力都建立在 live interval splitting, eviction 和重新排队之上.

---

## 10. 源语言变量与寄存器分配对象并不是一一对应的

再往前走一步, 我们还需要逐渐摆脱"一个 C 变量对应一个寄存器"的直觉. 有人经常说 C 语言就是高级汇编, 不是这样的.

例如:

```c
int x = a + b;
x = x * 2;
x = x + c;
```

经过 SSA 化以后, 可能已经变成:

```text
x1 = a + b
x2 = x1 * 2
x3 = x2 + c
```

进入机器 IR 后, 由于 instruction selection, copy, two-address constraint, subregister, calling convention 等原因, 还可能出现更多机器级虚拟寄存器.

于是寄存器分配器真正处理的对象通常更接近:

```text
machine-level values
live ranges
virtual registers
```

源语言变量与这些对象之间未必存在简单的一对一关系.

同一个源变量可能对应多个虚拟寄存器; 同一个虚拟寄存器又可能在分配过程中被 split 成多个 live range fragment.

因此以后讨论 RA 时, 我们会尽量使用:

```text
value
virtual register
live range
live interval
```

这些机器后端层面的概念.

---

## 11. 为什么寄存器分配很难

到目前为止, 我们已经可以看到 RA 的几个基本困难.

首先, 物理寄存器数量有限, 同时存活的值却可能很多.

其次, 值之间存在复杂的生命周期重叠, 因此不能任意共享寄存器.

再次, 寄存器并不是全部等价. 一些指令只接受某类寄存器, 一些值要求 register pair, 一些机器存在 subregister alias, 一些指令隐式使用固定物理寄存器.

此外, spill 的代价与执行频率相关, copy elimination 与 spill avoidance 之间可能发生冲突, calling convention 又会影响不同物理寄存器的使用成本.

最终还需要考虑编译时间.

一个非常昂贵的全局优化算法即使能够提高极少量代码质量, 也未必适合工业编译器.

因此真实 RA 面对的是:

```text
有限寄存器资源
+
复杂生命周期
+
机器指令约束
+
多种优化目标
+
编译时间预算
```

后面我们讨论 Chaitin, Briggs, Linear Scan, LLVM Greedy, GCC IRA/LRA 时, 都可以把它们看成对这组约束的不同工程解法.

---

## 12. 第一部分需要建立的核心模型

这一部分结束后, 最重要的是在脑中形成下面这个模型:

```text
前端 / 中端
    ↓
产生程序中的计算与数据依赖
    ↓
Instruction Selection
    ↓
Machine IR + Virtual Registers
    ↓
分析哪些值在什么时候仍然存活
    ↓
判断哪些值竞争同一个寄存器资源
    ↓
Register Allocation
    ↓
Physical Registers
  ↙             ↘
成功驻留         Spill / Split
    ↓
满足具体 ISA 约束
    ↓
Machine Code
```

从资源角度看, 它还可以压缩成:

```text
Virtual Registers
        ↓
    Liveness
        ↓
Register Pressure
        ↓
有限 Physical Registers
        ↓
┌───────────────┐
│   Allocation  │
└───────────────┘
    ↓       ↓
Register   Memory
```

之后所有复杂算法, 本质上都围绕几个问题展开:

**哪些值会互相竞争?**

**哪些值最值得拥有寄存器?**

**拥有寄存器的值应该放在哪里?**

**寄存器资源不足时应该牺牲谁?**

**是否可以通过改变 live range, copy, 调度或者重新计算来缓解压力?**

第一部分到这里完成了问题建模.

第二部分开始, 我们就要进入整个寄存器分配理论真正的基础: **Liveness Analysis**。那里会正式回答一个最关键的问题——在程序的某一个位置上, 究竟怎样严格判断一个值 "还活着".
