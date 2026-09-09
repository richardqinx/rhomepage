---
title: "第七部分: SSA 与寄存器分配"
slug: "ssa"
lang: zh-Hans
series: register-allocation
weight: 80
created: 2026-08-17
updated: 2026-09-09
license: CC-BY-SA-4.0
---

前面几部分讨论寄存器分配时, 我们一直从一般的 live range 出发. 一个机器级虚拟寄存器可能经历多次 definition, allocator 再通过 liveness 判断某一个 definition 产生的值在什么区域有效. SSA, 即 Static Single Assignment, 把这个关系整理得更规整: 每个 SSA value 只有一个 definition, 每个 use 都明确引用这个 definition 产生的值. 这种结构首先简化了 def-use 关系, 随后又影响 live range 的形状, interference graph 的性质, phi 的处理方式以及 SSA destruction.

SSA 对寄存器分配的意义不只是 "变量改了名字". 对一个 allocator 来说, single assignment 带来的真正收益是每个 value 都有唯一的生命周期起点. 如果再结合 dominance, 很多在一般 live range 上需要额外分析的关系会获得比较严格的结构.

## 1 Single Definition, Dominance 与 Live Range

先看普通命令式形式:

```text
x = a + b
use x

x = c + d
use x
```

如果把 `x` 当作同一个名字, 它在这里显然有两个不同 definition. SSA 会把它们拆成两个 values:

```text
x1 = a + b
use x1

x2 = c + d
use x2
```

现在 `x1` 的所有 uses 都属于第一个 definition, `x2` 的所有 uses 都属于第二个 definition. 对 liveness 来说, allocator 不再需要询问 "这里使用的是 `x` 的哪一次定义"; SSA name 已经把这个问题编码进 IR.

SSA 还要求一个 value 的 definition dominate 它的普通 uses. 假设 `v` 在 basic block `D` 中定义, 并在 basic block `U` 中使用, 那么从函数入口到达这个 use 的每一条控制流路径都必须经过 `D`. 例如:

```text
        B1
        |
      v = ...
       / \
      /   \
     B2   B3
     |     |
   use v   |
      \   /
       \ /
        B4
        |
      use v
```

这里 `B1` 位于到达两个 uses 的所有控制流路径上. 因此 `v` 的生命周期有一个明确的根, 就是 `B1` 中的唯一 definition.

如果从 dominance tree 上观察一个 SSA value 的 live region, 它通常可以表示成一棵连通子树. 一个 use 要求 value 从 definition 一直沿相应的 dominance 路径保持有效, 多个 uses 对应的这些路径合起来仍然保持连通. 这条性质后面会直接导出 SSA interference graph 的 chordal structure.

需要注意 source variable 和 SSA value 的区别. 一个源语言变量可能在 SSA 中变成很多 names, 每个 name 都是独立 value. Register allocator 更关心这些 values 的 live ranges, 而不会试图让所有来自同一个源变量的 SSA names 永远使用同一个物理寄存器.

## 2 Phi 的 Use 发生在 CFG Edge 上

SSA 在控制流汇合处使用 phi. 例如:

```text
B1:
    x1 = ...
    goto B3

B2:
    x2 = ...
    goto B3

B3:
    x3 = phi(x1 from B1, x2 from B2)
    use x3
```

Phi 的 operand 和普通指令 operand 有一个根本区别. `x1` 的 use 属于 edge `B1 -> B3`, `x2` 的 use 属于 edge `B2 -> B3`. 程序从 `B1` 进入 `B3` 时选择 `x1`, 从 `B2` 进入时选择 `x2`.

```text
B1 ---- x1 ----\
                \
                 >---- B3: x3 = phi(...)
                /
B2 ---- x2 ----/
```

因此不能把 `x1` 和 `x2` 简单地都加入 `LIVE_IN[B3]`. 这样做会让两个来自互斥 predecessor edges 的 operands 在 `B3` 入口处看起来同时 live, 进而制造虚假的 interference.

Block-level liveness 在处理 phi 时通常需要保留 edge-specific 信息. 假设 successor `S` 中有一个 phi, predecessor `B` 只应该把属于 `B -> S` 这条 edge 的 phi operand 加入自己的 live-out. 来自其他 predecessors 的 operands 与 `B` 无关.

Phi result `x3` 则在 `B3` 入口处产生. 所以从数据流的角度看, 可以把 phi 想象成多条 predecessor edges 上发生的 value transfer, 最终在 successor 入口得到一个新的 SSA value.

这种语义对寄存器分配很有利. 如果 `x1`, `x2`, `x3` 没有其他 interference 阻止它们共享寄存器, allocator 可以安排 $x_1 \mapsto R_0$, $x_2 \mapsto R_0$, $x_3 \mapsto R_0$. SSA destruction 以后, 两条 edge 上都不需要实际的数据移动.

如果得到 $x_1 \mapsto R_0$, $x_2 \mapsto R_1$, $x_3 \mapsto R_0$, 那么只有 `B2 -> B3` 需要一次从 `R1` 到 `R0` 的 copy. 因此 phi 会自然形成 coalescing preference: incoming value 和 phi result 倾向于使用相同的物理寄存器.

这里同样不能只根据 phi 自身判断两个 operands 是否 interfere. `x1` 和 `x2` 可能因为程序其他位置的 liveness 而发生冲突, 也可能完全没有冲突. Phi 的 edge semantics 只是保证 allocator 不会因为 phi 这一条指令本身凭空制造冲突.

## 3 SSA Interference Graph 为什么是 Chordal Graph

SSA 给 graph coloring 带来的理论优势, 来自前面提到的 dominance structure.

把 dominance tree 看成一棵真正的树. 每个 SSA value 的 live region可以对应其中的一棵连通子树. 两个 values 发生 interference, 意味着它们的 live regions 在某个程序位置相交. 因此 SSA interference graph 可以理解为一组 dominance-tree subtrees 的 intersection graph.

例如 dominance tree 为:

```text
          A
        /   \
       B     C
      / \     \
     D   E     F
```

假设几个 values 的 live regions 大致为:

```text
v1: A - B - D

v2:     B - D - E

v3:             C - F
```

`v1` 和 `v2` 的 live regions 相交, 因此在 interference graph 中存在边. `v3` 所在的区域与前两者分离, 因而这组 live regions 本身不会生成 `v1-v3` 或 `v2-v3` 的 interference.

树的连通子树所形成的 intersection graph 是 chordal graph. 因此, 在保持 strict SSA liveness 结构的条件下, SSA interference graph 具有 chordal property.

Chordal graph 中, 所有长度至少为 4 的无弦环都会被排除. 例如:

```text
a ----- b
|       |
|       |
d ----- c
```

这是一个没有 chord 的四边形. 如果加入 `a-c`:

```text
a ----- b
|  \    |
|    \  |
d ----- c
```

环上出现了一条连接非相邻顶点的 chord.

Chordal graph 存在 perfect elimination ordering. 按这种顺序逐个删除节点时, 每个被删除节点当前的邻居都会形成 clique. 反过来按照这个顺序进行 greedy coloring, 可以得到最优 coloring. 因而对于 chordal graph 有:

$$  
\chi(G)=\omega(G)  
$$

这里 $\chi(G)$ 是 chromatic number, $\omega(G)$ 是最大 clique 大小.

这个等式和第三, 四部分讨论的一般 interference graph 差别很大. 对一般图, $\omega(G)$ 只是 $\chi(G)$ 的下界. 最大 clique 只需要 3 种颜色, 整张图仍然可能需要 4 种甚至更多颜色. 对 chordal graph, 最大 clique 已经决定了最少颜色数.

如果当前 register class 有 $K$ 个完全等价的物理寄存器, 并且 SSA interference graph 满足 $\omega(G)\le K$, 那么单纯从 graph coloring 的角度看, 存在合法的 $K$-coloring, 而且可以高效找到.

这里的限制条件需要保留. 真实 RA 还有 register classes, pre-colored nodes, physical register aliasing, fixed constraints 和 register tuples. 这些约束加入以后, "最大 clique 不超过 $K$" 已经不能单独保证最终 machine assignment 成功. Chordal property 解决的是基础 interference coloring 问题.

## 4 SSA 把很多困难推向了 Spilling

假设一个 register class 只有 $K$ 个物理寄存器, 某个位置却有 $K+2$ 个 SSA values 同时 live. 这些 values 在 interference graph 中形成至少大小为 $K+2$ 的 clique. 即使 graph 是 chordal, coloring 也不可能把 $K+2$ 个互相冲突的 values 塞进 $K$ 个寄存器.

所以在 SSA-based register allocation 中, spilling 和 coloring 可以形成比较清晰的分工. Spilling 或 splitting 负责降低某些位置的 register pressure, 随后的 coloring 再利用 SSA interference graph 的结构完成 assignment.

这一点和 Chaitin-Briggs 的组织方式有所区别. Chaitin-style algorithm 在 simplify 过程中遇到 high-degree structure 时选择 potential spill, coloring 和 spill decision 彼此交织. SSA-based allocator可以先研究哪些 values 需要从高压力区域移走, 在压力满足要求以后再利用 chordal graph 进行 coloring.

SSA 也方便 spill rewrite 保持 single-definition property. 假设:

```text
v1 = ...
...
use v1
...
use v1
```

如果 `v1` 被 spill, 可以写成:

```text
v1 = ...
store [slot], v1

...

t1 = load [slot]
use t1

...

t2 = load [slot]
use t2
```

`t1` 和 `t2` 各自只有一个 definition, 因而仍然可以作为新的 SSA values. 原来的长 live range 被分解成多个短 live ranges, allocator 可以继续对这些新 values 使用 SSA liveness.

Reload 放在哪里会影响新的 register pressure. 假设一个 spilled value 在两个分支中都有 use:

```text
        B1
       /  \
      B2  B3
      |    |
    use   use
```

一种方案是在 `B1` 中 reload 一次:

```text
        load t
          |
         / \
        B2 B3
        |   |
      use  use
```

这样两个分支共享一个 reload, 但 `t` 从 `B1` 开始就保持 live, 生命周期比较长. 另一种方案是在 `B2` 和 `B3` 中分别 reload, 产生两个较短的 SSA values. 后者可能增加动态 memory operations, 同时降低寄存器压力.

Spill placement 因而同时涉及 execution frequency 和 live range length. SSA 使新 definitions 和 uses 的关系更清楚, 却没有消除这种 cost trade-off.

## 5 Live Range Splitting 在 SSA 中如何表示

Live range splitting 在 SSA 里可以理解成主动创建新的 definitions.

假设原来:

```text
v1:
|-----------------------------------|
```

allocator 希望把它拆成三个 fragments:

```text
v1:
|-----------|

v2:
             |-----------|

v3:
                          |--------|
```

那么 `v2` 和 `v3` 可以成为新的 SSA values. 后续 uses 根据程序位置重新命名, 分别引用对应 fragment. Fragments 之间通过 copy, spill/reload 或 phi 传递值.

在直线代码里可能得到:

```text
v1 = ...
...
v2 = COPY v1
...
v3 = COPY v2
...
```

如果最后三个 fragments 都分配到同一个 physical register, 这些 copies 可以被消除. 如果中间 fragment需要进入 memory, transfer 就可能转化成 store 和 reload.

带控制流的 splitting 会更接近 SSA construction. 例如两个分支分别产生新的 fragments, 在汇合以后需要继续使用同一个逻辑值:

```text
          v1
         /  \
        /    \
      v2      v3
        \    /
         \  /
      v4 = phi(v2, v3)
```

这里 `v2` 和 `v3` 分别是不同路径上的 definitions, `v4` 在 join block 中重新把它们合并成一个 SSA value. 所以 SSA-based splitting 往往需要 dominance, renaming 和 phi placement 协同工作.

从 allocator 的角度看, splitting 的收益仍然是缩短 allocation object. 原来一个 value 跨越多个高压力区域, 拆开以后每个 fragment 可以分别选择 physical register 或 memory location, 不需要整个生命周期保持同一种 allocation decision.

## 6 Coalescing 与 SSA Structure 的关系

Phi destruction 会产生 copy, allocator 又希望通过 coalescing 删除这些 copies. 但 coalescing 会改变 SSA value 原本整齐的 live-range structure.

考虑:

```text
x3 = phi(x1, x2)
```

`x1`, `x2`, `x3` 分别拥有自己的唯一 definition. 如果 allocator 把它们全部合并为一个 allocation object, 这个联合对象会包含多个 definitions. 从物理寄存器分配角度看这完全可能是理想结果, 因为三个 values 可以共享一个 physical register; 从 SSA structural analysis 的角度看, 联合对象已经不再对应一个单一 definition 支配的 live subtree.

任意识别两个不相邻节点进行 coalescing, 还可能破坏原来的 chordal interference structure. 因此某些 SSA-based allocators 会尽量在利用完 SSA coloring 性质之后再进行更激进的 coalescing, 或者只允许满足特定条件的合并.

这里和第五部分的 IRC 有相似的问题背景. IRC 从一般 interference graph 出发, 使用 Briggs 或 George criterion 控制 coalescing 风险. SSA-based RA 拥有更规整的初始图, 因而更加有理由保护这份结构, 至少在需要利用 chordal coloring 的阶段不要随意破坏它.

Phi 本身仍然提供了很强的 coalescing preference. 因此实际设计需要在两件事之间选择时机: 一方面希望保留 SSA structure 方便 allocation, 另一方面希望尽量让 phi related values 获得同一 physical register.

## 7 SSA Destruction 与 Parallel Copy

最终机器代码不能保留抽象 phi, 因此在某个阶段需要进行 SSA destruction.

对于:

```text
B1:
    ...
    goto B3

B2:
    ...
    goto B3

B3:
    x3 = phi(x1 from B1, x2 from B2)
```

可以把它展开成两条 edge-specific transfers:

```text
B1 -> B3:
    x3 <- x1

B2 -> B3:
    x3 <- x2
```

如果 `x1` 和 `x3` 已经分配到同一寄存器, 第一条 transfer 无需生成真正的 move. `x2` 和 `x3` 同理.

一个 block 同时存在多个 phi 时, 某条 predecessor edge 上会出现一组同时发生的 assignments:

```text
a3 <- a1
b3 <- b1
c3 <- c1
```

这里需要使用 parallel copy semantics. 所有右侧值都按照 assignment 开始前的状态读取.

假设物理寄存器分配以后出现:

```text
R0 <- R1
R1 <- R0
```

如果先执行 `R0 <- R1`, 原来 `R0` 中的值已经丢失. 因此需要 temporary:

```text
TMP <- R0
R0  <- R1
R1  <- TMP
```

对于没有 cycle 的 copy dependencies, compiler 可以安排一个安全顺序. 例如:

```text
R0 <- R1
R2 <- R0
```

如果两个 source 都表示旧寄存器值, 应该先执行:

```text
R2 <- R0
R0 <- R1
```

这样旧 `R0` 在被覆盖之前已经保存到 `R2`.

因此 SSA destruction 通常先把 phi 转换成 edge-specific parallel copies, 再由 parallel-copy resolver 把它们变成串行机器指令. Coalescing 做得越好, 真正需要 resolver 处理的 copies 就越少.

## 8 Critical Edge 与 Copy Placement

Phi 的 transfers 属于 CFG edges, 所以 copy placement 还会遇到 critical edge.

假设:

```text
        B
       / \
      v   v
      S   X
      ^
      |
      P
```

`B` 有两个 successors, `S` 也有多个 predecessors, 因而 `B -> S` 是 critical edge. 如果某条 phi transfer 只属于 `B -> S`, 那么不能直接放在 `B` 末尾, 因为走 `B -> X` 时也会执行; 放到 `S` 开头也会影响从 `P -> S` 进入的路径.

常见做法是 split 这条 edge:

```text
        B
       / \
      v   v
      E   X
      |
      v
      S
      ^
      |
      P
```

新的 block `E` 只会在原来的 `B -> S` 路径上执行, 因而可以安全放置对应 copies.

这会说明 SSA destruction 在 compiler pipeline 中并不是一个纯粹的语法转换. 它可能修改 CFG, 引入 copies, 改变 liveness, 进而影响寄存器分配. 如果很早 destruction, 后面的 allocator 要处理更多 ordinary copies; 如果延迟 destruction, allocator 本身就需要理解 phi operands 的 edge semantics.

## 9 Machine SSA 与工业寄存器分配

SSA-based RA 并不等于工业编译器一定使用某一种专门的 "SSA coloring algorithm". SSA 也可以只是寄存器分配之前维持的一种 machine-level invariant.

LLVM 就很适合说明这一点. Instruction selection 以后, Machine IR 中的 virtual registers 在相当一段 pipeline 内仍然保持 SSA 性质. 一个 virtual register 通常具有唯一 definition, machine passes 可以沿 def-use chains 查询它的数据来源和使用位置.

寄存器分配逐渐改变这种状态. Coalescing 可能把多个 values 连接起来, splitting 会生成新的 fragments, spilling 会插入 stores 和 reloads, 最终 virtual registers 被改写成 physical registers. 一个 physical register 如 `RAX` 在整个函数中会反复被不同指令定义, 自然不再满足 SSA.

所以工业 allocator 经常会经历这样的变化:

```text
Machine SSA
    |
    | virtual registers with single defs
    v
Coalescing / splitting / spilling
    |
    v
General live ranges
    |
    v
Physical register assignment
    |
    v
Non-SSA physical-register code
```

LLVM 的 `LiveIntervals` 之所以需要 `VNInfo` 一类结构, 也与这种变化有关. 一旦一个 register live range 中出现多个 definitions, allocator 就需要区分不同 definitions 产生的 value numbers, 单纯依赖最初的 SSA name 已经不够.

SSA 给寄存器分配提供了一块结构比较规整的起点. Definition 和 use 的关系清楚, phi operands 具有 edge semantics, live regions 与 dominance tree 联系紧密, interference graph 也因此具有 chordal structure. 进入下一部分以后, 我们会开始把这里相对抽象的 "颜色" 逐步替换成真实 CPU 的寄存器资源, 讨论 register class, calling convention, pre-colored register, fixed operand, subregister aliasing, two-address constraint 和 register pair 等机器约束.
