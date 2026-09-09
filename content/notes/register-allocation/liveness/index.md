---
title: "第二部分: 活跃性分析与生命周期"
slug: "liveness"
lang: zh-Hans
series: register-allocation
weight: 30
created: 2026-08-17
updated: 2026-09-09
license: CC-BY-SA-4.0
---

寄存器分配面对的是一种随程序位置变化的资源需求. 一个函数里可能出现几百个 virtual registers, 但 allocator 并不需要同时为它们全部准备物理寄存器. 某个 value 在完成最后一次有意义的 use 之后, 保存它的寄存器就可以重新利用. 因此, 在开始讨论 interference graph 或 Linear Scan 之前, 首先需要确定每个 value 在程序的哪些位置仍然必须保持有效. 这就是 liveness analysis.

## 1 一个 value 在什么时候是 live 的

考虑一段简单的直线代码:

```text
1: v1 = load a
2: v2 = v1 + 1
3: v3 = v2 * 2
4: return v3
```

第 1 条指令产生 `v1`. 在第 1 条和第 2 条之间, `v1` 必须被保存, 因为第 2 条指令还要读取它. 第 2 条执行完以后, 后续已经没有 `v1` 的 use, 因而 `v1` 可以死亡. 从这个位置开始, 覆盖 `v1` 所使用的物理寄存器不会再改变程序结果.

更严格地说, 对某个程序位置 $p$ 和 value $v$, 如果从 $p$ 出发存在一条可执行的控制流路径, 路径后面会读取当前的 $v$, 并且在这次读取之前没有新的 definition 取代它, 那么 $v$ 在 $p$ 处是 live 的. 这个定义包含 "存在一条路径" 这一条件, 所以 liveness 属于 may analysis. 编译器不能因为某条路径执行概率很低就忽略它, 只要该路径在语义上可能发生, 对应的 value 就必须得到保留.

这也解释了为什么 liveness 是 backward dataflow analysis. 判断某个 value 当前是否 live, 要看它未来是否还有 use. 信息传播方向因此和程序执行方向相反. 如果 CFG 中有 `B1 -> B2 -> B3`, 程序沿箭头向前执行, liveness 则从后继 block 向前驱 block 传播.

对一条机器指令来说, operand 通常可以分成 def 和 use. 例如:

```text
v3 = ADD v1, v2
```

`v1` 和 `v2` 是 uses, `v3` 是 def. `v1` 和 `v2` 必须在指令读取它们时仍然 live, `v3` 则从这次 definition 开始产生新的值. 如果这条 ADD 是 `v1` 的最后一次 use, 那么这个 use 可以带有 kill 的含义. Kill 描述 value 生命周期在这里结束, 并不对应一条真实的 "删除寄存器" 指令.

反过来, 一个 definition 也可能产生从来没有被使用过的 value. 例如:

```text
v1 = ADD v2, v3
v4 = MUL v2, v3
```

如果之后没有任何指令读取 `v1`, 那么第一条指令对 `v1` 的 definition 是 dead def. 在较早的优化阶段, 这种代码通常会被 DCE 删除, 但机器级变换仍然可能临时产生 dead definitions, 所以后端的 liveness 表示也需要能够处理它们.

这里最好始终把 liveness 理解成 value 的性质, 不要和源语言变量的作用域混在一起. 例如:

```text
x = 1
use x
x = 2
use x
```

两次 assignment 虽然都写着 `x`, 对数据流来说却产生两个不同 values. SSA 会把它们直接写成 `x1` 和 `x2`. 即使 IR 当前没有处于 SSA form, liveness 分析真正关心的也仍然是哪一个 definition 产生的值在后面还会被读取.

## 2 从 Basic Block 到数据流方程

在没有分支的代码中, 从函数尾部向前逐条扫描就能得到 liveness. 有了 CFG 以后, 一个 block 的出口可能通向多个 successors, 这时通常先在 basic block 粒度求出边界信息, 再把结果展开到 block 内部.

对 basic block $B$, 先定义 $\mathrm{USE}(B)$ 和 $\mathrm{DEF}(B)$. $\mathrm{DEF}(B)$ 包含 block 内产生的 definitions. $\mathrm{USE}(B)$ 包含那些在 block 内第一次使用时还没有在本 block 中被定义的 values, 也就是 upward-exposed uses.

例如:

```text
B:
    v3 = v1 + v2
    v4 = v3 * v5
```

这里 `v1`, `v2`, `v5` 都需要从 block 外部带进来, 所以它们属于 $\mathrm{USE}(B)$. `v3` 虽然在第二条指令里被使用, 但它已经在第一条指令中定义, 因此不属于 $\mathrm{USE}(B)$. 对这个 block 有 $\mathrm{USE}(B)={v1,v2,v5}$, $\mathrm{DEF}(B)={v3,v4}$.

随后定义 $\mathrm{LIVE\_IN}(B)$ 和 $\mathrm{LIVE\_OUT}(B)$. 前者表示进入 $B$ 时必须仍然有效的 values, 后者表示离开 $B$ 时仍然必须有效的 values. 对普通 CFG, 经典 liveness 方程是:

$$  
\begin{aligned}  
\mathrm{LIVE\_IN}(B) &= \mathrm{USE}(B)\cup\left(\mathrm{LIVE\_OUT}(B)-\mathrm{DEF}(B)\right), \  
\mathrm{LIVE\_OUT}(B) &= \bigcup_{S\in\mathrm{succ}(B)}\mathrm{LIVE\_IN}(S).  
\end{aligned}  
$$

第一条方程可以直接按程序语义理解. 进入一个 block 时需要保留的 value 有两种来源. 一种是 block 自己马上会读取, 且在读取之前没有本地 definition 的 value. 另一种是 block 后面的代码还会使用, 同时当前 block 没有重新定义它的 value. 如果一个 value 在 $\mathrm{LIVE\_OUT}(B)$ 中, 但 $B$ 自己会重新定义它, 那么从 $B$ 入口带入的旧值就不需要为了后续 use 继续保留.

第二条方程来自控制流分叉. 如果 $B$ 有两个 successors $S_1$ 和 $S_2$, 某个 value 只要在其中任意一个 successor 入口需要保持, 离开 $B$ 时就必须保存. 假设 $\mathrm{LIVE\_IN}(S_1)={a,b}$, $\mathrm{LIVE\_IN}(S_2)={b,c}$, 那么 $\mathrm{LIVE\_OUT}(B)={a,b,c}$.

用一个 CFG 走一遍会更清楚:

```text
          B1
         /  \
        v    v
       B2    B3
        \    /
         v  v
          B4
```

对应代码为:

```text
B1:
    v1 = load a
    v2 = load b
    if cond goto B2 else B3

B2:
    v3 = v1 + v2
    goto B4

B3:
    v3 = v1 - v2
    goto B4

B4:
    v4 = v3 * 2
    return v4
```

暂时假设 `cond` 是进入 `B1` 之前已经存在的 value. 对 `B4`, 返回以后没有继续需要保留的 virtual register, 所以 $\mathrm{LIVE\_OUT}(B4)=\varnothing$. `B4` 在定义 `v4` 之前需要 `v3`, 因而 $\mathrm{LIVE\_IN}(B4)={v3}$.

`B2` 和 `B3` 的唯一 successor 都是 `B4`, 所以它们的 live-out 都是 `{v3}`. 两个 blocks 都会在内部重新定义 `v3`, 同时读取 `v1` 和 `v2`, 因而它们的 live-in 都是 `{v1,v2}`. `B1` 的两个 successors 入口都需要 `v1` 和 `v2`, 所以离开 `B1` 时这两个 values 都必须保留. `B1` 本身定义 `v1` 和 `v2`, 因而进入 `B1` 之前只需要 `cond`.

如果 CFG 没有环, 按适当顺序传播这些集合通常很快就能得到结果. Loop 会形成循环依赖. 一个 loop header 的 live-in 可能影响 back edge predecessor 的 live-out, 后者又继续影响 loop header. 因此编译器通常从空集开始反复应用数据流方程, 直到所有集合都不再变化.

```text
initialize LIVE_IN and LIVE_OUT to empty sets

repeat:
    for each block B:
        new_out = union of LIVE_IN of B's successors
        new_in  = USE[B] union (new_out - DEF[B])

        update LIVE_IN[B] and LIVE_OUT[B]

until no set changes
```

这个过程会达到 fixed point. 函数中的 relevant values 数量有限, 每个 live set 也只是这个有限集合的子集. 在标准 liveness analysis 中, 信息从空集开始单调传播, 一个 value 加入某个集合以后, 只有有限种状态可供继续扩展, 所以迭代最终会稳定.

工业实现通常使用 worklist 避免反复扫描完全不受影响的 blocks. 对 backward analysis 来说, 如果某个 block 的 `LIVE_IN` 改变, 真正可能因此需要重新计算的是它的 predecessors. 选择合适的遍历顺序也会影响收敛速度, 但不会改变 fixed point 的语义结果.

## 3 Instruction-level Liveness 与 Live Range

Basic block 边界上的 liveness 只是第一步. 寄存器分配通常还需要知道一条具体机器指令前后有哪些 values live. 得到 $\mathrm{LIVE\_OUT}(B)$ 后, 可以从 block 尾部向前逐条扫描. 对普通指令 $I$, 有 $LiveBefore(I)=Use(I)\cup(LiveAfter(I)-Def(I))$.

考虑:

```text
1: v1 = load a
2: v2 = load b
3: v3 = v1 + v2
4: v4 = v3 * v1
5: store v4
```

从末尾开始, 第 5 条指令之前需要 `{v4}`. 穿过第 4 条指令以后, `v4` 的旧值不需要保留, 但这条指令需要 `v3` 和 `v1`, 所以第 4 条之前是 `{v1,v3}`. 再穿过第 3 条, `v3` 被该指令定义, 而 `v1`, `v2` 是 operands, 所以第 3 条之前是 `{v1,v2}`. 继续向前可以得到完整结果:

```text
                 live before

1: v1 = load a      {}
                    |
                    | {v1}
                    v

2: v2 = load b      {v1}
                    |
                    | {v1, v2}
                    v

3: v3 = v1 + v2     {v1, v2}
                    |
                    | {v1, v3}
                    v

4: v4 = v3 * v1     {v1, v3}
                    |
                    | {v4}
                    v

5: store v4         {v4}
                    |
                    | {}
```

这里可以直接看到物理寄存器复用发生在哪里. `v2` 在第 3 条指令完成以后已经死亡, 所以它占据的寄存器随后可以交给 `v3`. `v3` 在第 4 条指令读取以后也不再需要, 如果目标指令允许 result 覆盖某个已经死亡的 operand, 还可以进一步复用同一个 physical register.

真实 machine instruction 内部有时还需要更细的位置划分. 普通三地址指令可以粗略看成先读取 uses, 再产生 defs, 但 two-address instruction, tied operand 和 early-clobber 会让 def/use 边界更加敏感. 例如:

```text
R0 = ADD R0, R1
```

旧 `R0` 是 input, 新 `R0` 是 output. Allocator 必须知道旧值什么时候读完, 新值什么时候可以开始覆盖同一个物理存储. LLVM 的 `SlotIndex` 就是用更细的 machine positions 表示这种关系, 后面讨论 LLVM LiveIntervals 时会再看它的具体设计.

把一个 value 所有 live 的程序位置收集起来, 就得到它的 live range. 在直线代码中可以简单画成:

```text
instruction:
1    2    3    4    5    6

v1:
     |----------------|
```

CFG 中的 live range 则是一组控制流位置, 不一定适合看成一根连续的横线. 某个 value 可能只在一个分支上需要保持:

```text
          B1
         /  \
        /    \
       B2    B3
       |      |
     live    dead
        \    /
         \  /
          B4
```

因此 live range 首先是控制流语义上的对象. 只有把机器程序的 positions 线性编号之后, 才会得到便于 Linear Scan 或其他 allocator 使用的 interval representation.

## 4 Live Interval, Segment 与 Lifetime Hole

假设机器程序已经建立线性位置编号, 某个 value 在 `[4,12)` 和 `[20,28)` 两段位置 live. 可以表示成:

```text
v1:
[4, 12)        [20, 28)
```

这两个连续区域通常称为 segments. 中间不 live 的部分是 lifetime hole. 一个现代 `LiveInterval` 因而可以包含多个 segments, "interval" 这个名字并不意味着它只能表示一个单独的数学区间.

Live range 和 live interval 可以从抽象层次上区分. Live range 表示 value 在 CFG 上所有需要保持的程序位置. Live interval 是 allocator 为这些位置建立的线性化数据结构. 如果算法只保留最早 definition 和最后 use, 把整个生命周期粗略表示成一个 `[start,end)`, 实现会很简单, 但也会丢掉 holes.

例如:

```text
v1: |--------|          |--------|

v2:           |--------|
```

`v2` 正好位于 `v1` 的 lifetime hole 中. 两个 values 在这些位置上可以共享物理寄存器. 如果把 `v1` 粗略表示成:

```text
v1: |----------------------------|
```

allocator 就会认为 `v1` 和 `v2` 发生了整段 overlap, 从而产生不必要的资源冲突.

Linear Scan 的高级版本因此会维护 multiple segments 和 inactive intervals. LLVM Greedy 同样依赖精细的 live interval information 来判断物理寄存器冲突和选择 splitting points. 与之相对, 经典 Chaitin-style allocator 会进一步把这些位置信息压缩成 interference graph, 只保留两个 allocation objects 是否曾经发生过冲突.

Liveness 也直接决定 register pressure. 如果某个位置同时 live 的 values 是 `{a,b,c,d}`, 并且四个 values 都竞争同一个 register class, 那么这一位置至少产生 4 个寄存器单位的需求. 如果 target 只有三个可用寄存器, allocator 就需要通过 spilling, splitting, rematerialization 或其他变换降低实际寄存器占用. Instruction scheduling 改变 definitions 和 uses 之间的距离时, live ranges 也会随之伸长或缩短, 因而 register pressure 和 RA 从来没有完全脱离代码调度.

下一步把 liveness 转换成 interference relation时, allocator关心的就是哪些 values 曾经在同一个程序位置同时需要相同物理资源. Graph coloring 会把这种关系记录成边, Linear Scan 和 LLVM Greedy 则更直接地利用 live interval overlap. 两种路线的数据结构不同, 但它们都建立在这一部分得到的生命周期信息上.
