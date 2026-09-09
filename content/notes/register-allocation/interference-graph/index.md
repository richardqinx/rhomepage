---
title: "第三部分: Interference Graph 与冲突模型"
slug: "interference-graph"
lang: zh-Hans
series: register-allocation
weight: 40
created: 2026-08-14
updated: 2026-09-09
license: CC-BY-SA-4.0
---

上一部分已经解决了 liveness 问题. 对任意一个程序位置, 我们可以判断哪些值仍然需要保留, 也可以进一步构造 live range 或 live interval. 寄存器分配接下来需要把这些位置相关的信息转化成寄存器之间的约束. 对经典 graph coloring allocator 来说, 这个约束通常通过 Interference Graph 表示.

## 1 从 liveness 到 interference

假设虚拟寄存器 $a$ 和 $b$ 在某个程序位置同时 live, 并且它们都需要使用同一类物理寄存器. 在这个位置上, 两个值必须同时保持有效, 因此 allocator 不能把它们分配到同一个物理寄存器. 我们称 $a$ 和 $b$ 之间存在 register interference.

Interference Graph, 简称 IG, 就是把整个函数中的这种关系收集成一张无向图. 图中的节点代表 virtual register 或 allocator 实际处理的 live range, 边表示两个节点之间存在 interference. 例如有关系 $a-b$, $a-c$, $b-c$, $c-d$, 对应的图可以画成:

```text
      a
     / \
    b---c---d
```

假设目标机器有 $R_0$, $R_1$, $R_2$ 三个完全等价的物理寄存器. 一种合法分配是 $a\mapsto R_0$, $b\mapsto R_1$, $c\mapsto R_2$, $d\mapsto R_0$. 虽然 $a$ 和 $d$ 最终使用了同一个物理寄存器, 但图中没有 $a-d$ 这条边, 所以它们没有要求不同寄存器的生命周期重叠.

从这个角度看, interference graph 是 liveness 的一种压缩. Liveness 保留了 "在哪个位置有哪些值同时 live" 这样的位置信息, IG 只记录 "哪两个值曾经发生过必须占用不同寄存器的冲突". 一旦图构建完成, allocator 可以暂时忽略冲突究竟发生在函数的哪一条指令附近, 直接研究节点之间的约束关系. 这很适合经典图着色算法, 但也意味着图本身会丢失冲突位置, 持续长度和执行频率等信息.

如果某个程序位置的 live set 是 ${a,b,c}$, 那么三个值必须同时存在, 因而产生 $(a,b)$, $(a,c)$ 和 $(b,c)$ 三条边. 它们在图中形成一个大小为 3 的 clique:

```text
    a
   / \
  b---c
```

如果这三个值都只能使用同一个 register class, 那么这个位置至少需要三个物理寄存器才能让它们全部驻留在寄存器中. 因此某个位置的 simultaneously live values 会直接反映在 interference graph 的 clique 结构上.

这里还需要把 "同时 live" 和 "竞争同一资源" 放在一起理解. 假设一个整数值只能使用 GPR, 一个浮点值只能使用完全独立的 FPR, 即使两者生命周期重叠, 它们也没有争夺同一个物理存储资源. 在最简单的理论模型里, 我们暂时假定所有节点属于同一个 register class, 所有物理寄存器也完全等价. 到真实机器约束部分再放宽这个假设.

## 2 如何从 liveness 构造冲突图

概念上最直接的方法是检查每个程序位置的 live set, 然后把其中的值两两连接. 如果某个位置有 $n$ 个 live values, 这种方法可能需要考虑 $O(n^2)$ 对关系. 经典实现通常利用 definition 来更直接地建立边.

考虑一条普通三地址指令 $d=f(a,b)$. 假设这条指令执行完以后, $x$, $y$ 仍然 live, 同时新产生的 $d$ 也开始存活. 从这一时刻开始, $d$ 必须和 $x$, $y$ 共存, 因而需要建立 $(d,x)$ 和 $(d,y)$ 两条 interference edge.

对普通指令可以概括成下面的关系:

$$  
d\in DEF(I),\ v\in LIVE\_OUT(I),\ d\neq v  
\quad\Longrightarrow\quad  
(d,v)\in E  
$$

这里 $E$ 是 interference graph 的边集. 这就是经常看到的 $DEF\times LIVE\_OUT$ 构图规则.

为什么在 definition 的位置处理就足够捕获冲突, 可以从两个重叠的 live ranges 来理解. 假设 $a$ 已经处于 live 状态, 随后某条指令定义了 $b$, 并且 $a$ 在这条指令以后仍然需要保存. $b$ 从 definition 开始进入生命周期时, $a$ 还没有死亡, 因此两者的冲突会在 $b$ 的 definition 处暴露出来.

例如:

```text
1: a = ...
2: ...
3: b = ...
4: ...
5: use a
6: use b
```

执行完第 3 行以后, $a$ 仍然 live, $b$ 已经产生, 所以构图时会建立 $a-b$.

现在手工走一遍稍完整的例子:

```text
1: a = load x
2: b = load y
3: c = a + b
4: d = c * a
5: e = d + b
6: return e
```

根据上一部分的 liveness 分析, 各指令边界可以得到:

| 位置  | Live before   | Live after    |
| --- | ------------- | ------------- |
| 1   | $\varnothing$ | ${a}$         |
| 2   | ${a}$         | ${a,b}$       |
| 3   | ${a,b}$       | ${a,b,c}$     |
| 4   | ${a,b,c}$     | ${b,d}$       |
| 5   | ${b,d}$       | ${e}$         |
| 6   | ${e}$         | $\varnothing$ |

第 1 行定义 $a$, 指令之后没有其他旧值需要和 $a$ 共存, 因此不增加边. 第 2 行定义 $b$, 此时 $a$ 仍然 live, 增加 $(a,b)$. 第 3 行定义 $c$, 指令之后 $a$ 和 $b$ 都仍然 live, 增加 $(c,a)$ 和 $(c,b)$. 第 4 行定义 $d$, 此时 $b$ 仍然 live, 增加 $(d,b)$. 第 5 行定义 $e$, 指令之后没有其他需要共存的虚拟寄存器.

最终得到:

```text
      a
     / \
    b---c
    |
    d

e
```

其中 $a$, $b$, $c$ 形成三角形. 如果目标机器只有两个可用寄存器, 这个子图无法完成 2-coloring. 如果有三个寄存器, 可以令 $a\mapsto R_0$, $b\mapsto R_1$, $c\mapsto R_2$, 而 $d$ 只和 $b$ 冲突, 所以可以使用 $R_0$ 或 $R_2$.

从这个例子也可以看到一个细节. Interference edge 只表示两个值在某些位置必须使用不同资源, 它不记录冲突持续了多久. $a$ 和 $b$ 可能只重叠一条指令, 也可能在整个循环中长期重叠, 图上都只是同一条 $a-b$ 边. 以后决定 spill 谁时, allocator 还需要其他信息来补充这张图.

## 3 Live range overlap, COPY 与 coalescing

在简单模型中, 两个 live ranges 有实质性的重叠, 它们就会 interfere. 例如:

```text
a: |-------------|
b:       |-------------|
```

这里 $a$ 和 $b$ 在中间一段同时 live, 如果竞争同一个 register class, 就需要不同物理寄存器. 如果生命周期完全错开:

```text
a: |-------|
b:           |-------|
```

两者可以复用同一个寄存器.

边界接触的情况需要更精确地看指令语义. 最典型的例子是:

```text
b = COPY a
```

假设这条 COPY 是 $a$ 的最后一次 use. 执行 COPY 时需要读取 $a$, COPY 之后旧的 $a$ 已经死亡, 新的 $b$ 开始继续保存这个值. 如果最后分配成 $a\mapsto R_0$, $b\mapsto R_0$, 那么这条指令会变成类似:

```text
R0 = COPY R0
```

随后可以删除.

这说明构图时不能因为 source 和 destination 在 COPY 附近发生生命周期交接, 就机械地建立 $a-b$ interference edge. 一旦存在这条边, coloring 会强制 $color(a)\neq color(b)$, allocator 也就失去了通过寄存器分配消除这条 COPY 的机会.

经典 graph-coloring allocator 对 COPY 通常会做特殊处理. 假设有 `b = COPY a`, 构造 $b$ 的冲突边时会把 source $a$ 从相关 live set 中排除, 同时记录 $a$ 和 $b$ 之间的 move relation:

```text
for COPY d <- s:
    live = LIVE_OUT - {s}

    for v in live:
        addEdge(d, v)

    recordMove(s, d)
```

于是图中同时存在两种不同性质的关系. Interference edge 表示两个节点不能使用同一个颜色, move relation 表示 allocator 希望两个节点尽量获得同一个颜色. 后者就是 register coalescing 的基础.

看到 COPY 以后直接把两个节点合并也不安全. 假设 $Adj(a)={x,y}$, $Adj(b)={z,w}$. 如果把 $a$ 和 $b$ 合并为节点 $ab$, 新节点可能拥有 $Adj(ab)={x,y,z,w}$. 合并扩大了邻居集合, 节点的 degree 可能上升, 原本容易着色的图也可能因此变难.

所以 coalescing 需要解决一个实际的权衡: 删除 move 可以减少机器指令, 合并 live ranges 又会改变 interference structure. 第五部分中的 Briggs criterion 和 George criterion, 都是在判断一次 coalescing 是否足够安全.

COPY 还说明了为什么真实实现需要比 "每条指令一个离散位置" 更精细的位置模型. use 发生在什么时候, def 什么时候开始生效, two-address operand 或 early-clobber 会不会提前覆盖某个寄存器, 都可能影响两个生命周期是否真正需要同时占据不同资源. LLVM 的 SlotIndex 之类的数据结构就是为了表达这类细粒度位置关系.

## 4 K-coloring 与 degree

在理想模型里, 假设有 $K$ 个完全等价的物理寄存器, 每个 virtual register 恰好占一个寄存器, 所有 virtual registers 都可以使用这 $K$ 个寄存器. 令 interference graph 为 $G=(V,E)$, 颜色集合为 $C={R_0,R_1,\ldots,R_{K-1}}$. Register assignment 就是在寻找映射 $color:V\rightarrow C$, 满足下面的约束:

$$  
(u,v)\in E  
\quad\Longrightarrow\quad  
color(u)\neq color(v)  
$$

这就是 graph K-coloring 与寄存器分配之间的经典对应关系.

一般图的 K-colorability 在 $K\ge 3$ 时是 NP-complete 问题. 对真实编译器来说, 函数中的 virtual registers 可能很多, allocator 还要同时考虑 spill cost, copy elimination, target constraints 和编译时间, 因此经典算法依赖启发式过程, 很少尝试直接求一般图的精确最优 coloring.

在 Chaitin-style allocator 中, 节点 degree 是最常用的结构信息之一. $degree(v)=|Adj(v)|$, 表示 $v$ 和多少个其他节点发生 interference.

如果 $degree(v)<K$, 那么在其他节点完成着色以后, $v$ 一定至少还剩一个可用颜色. 假设 $v$ 最多有 $K-1$ 个邻居. 即使这些邻居恰好分别使用了 $K-1$ 种不同颜色, 也只能占掉 $K-1$ 种颜色, 颜色集合中仍然至少剩下一种.

例如 $K=4$, 且 $degree(v)=3$. 三个邻居最坏可以分别使用 $R_0$, $R_1$, $R_2$, 此时 $R_3$ 仍然可以分给 $v$. 这就是 simplify 操作能够成立的原因: allocator 可以暂时删除一个 $degree<K$ 的节点, 先处理剩余图, 最后再把这个节点放回来.

当 $degree(v)\ge K$ 时, allocator失去了上述保证, 但节点仍然可能成功着色. Degree 统计邻居数量, 邻居最终可能复用颜色. 假设 $K=3$, $v$ 有三个邻居 $a$, $b$, $c$, 因此 $degree(v)=3$. 如果最后 $a\mapsto R_0$, $b\mapsto R_0$, $c\mapsto R_1$, 那么三个邻居实际只占用了两个颜色, $v$ 仍然可以使用 $R_2$.

这也是 optimistic coloring 的基础. 当图中已经找不到 $degree<K$ 的节点时, allocator 可以选择一个 high-degree node 作为 potential spill candidate, 暂时将它移除并继续 simplify. 到 select 阶段恢复这个节点时, 再看相邻节点真正占用了多少种颜色. 如果相邻节点只使用了 $R_0$ 和 $R_1$, 节点仍然可以获得 $R_2$; 如果它的所有合法颜色都已经被占用, 此时才产生 actual spill.

Potential spill 因此只是 simplify 阶段做出的一个风险选择. 它表示 allocator 暂时无法保证该节点以后一定能着色. 最后的 register assignment 仍然有机会成功.

## 5 Clique, degree 与 register pressure

Interference graph 和 register pressure 有直接联系, 但这两个概念描述的维度不同.

如果某个程序位置同时有 $m$ 个 values live, 并且它们竞争相同寄存器资源, 这些节点会形成一个大小为 $m$ 的 clique. 如果机器只有 $K$ 个寄存器而某处出现了大小为 $K+1$ 的 clique, 这组 values 不可能全部同时获得寄存器.

不过一个节点的 degree 不能直接理解成它所在位置的 register pressure. 假设 $v$ 生命周期很长, 在前半段与 $a$, $b$ 同时 live, 后半段与 $c$, $d$ 同时 live:

```text
early:
{v, a, b}

late:
{v, c, d}
```

那么 $Adj(v)={a,b,c,d}$, 所以 $degree(v)=4$. 但程序中没有任何位置出现 ${v,a,b,c,d}$ 五个值同时 live. 这段程序的相关峰值 pressure 可能只有 3.

Degree 是一个节点在整个生命周期中累计遇到的冲突数量. Register pressure 是某个具体程序位置上的瞬时资源需求. 长 live range 很容易拥有较高 degree, 因为它可能先后与很多互不重叠的短 live ranges 发生冲突.

这也是仅按 degree 选择 spill candidate 容易出现问题的原因. 假设 $a$ 和 $b$ degree 相近, $a$ 只在冷路径中使用一次, $b$ 位于热循环中并被反复读取, spill 两者的动态成本显然不同. 经典 allocator 往往将使用频率和图结构结合起来, 例如考虑类似 $\frac{spillCost(v)}{degree(v)}$ 的指标. 工业实现还会继续加入 block frequency, loop depth, rematerialization cost 和 target-specific instruction cost 等信息.

最大 clique 与图的 chromatic number 也不能简单等同. 一个大小为 $m$ 的 clique 至少需要 $m$ 种颜色, 因此 clique number 为 coloring 提供了下界. 对一般图来说, 即使没有大小为 $K+1$ 的 clique, 整张图仍然可能无法使用 $K$ 种颜色完成 coloring. 所以仅根据某一个位置的峰值 simultaneously live count, 无法完整解决一般 graph-coloring allocation.

## 6 Spill 和 splitting 如何改变冲突结构

如果当前 interference graph 很难着色, allocator 并不一定要一直在原图上寻找更复杂的颜色组合. Spill 和 live range splitting 都会改变程序的生命周期结构, 从而产生一张不同的冲突图.

假设原来有一个很长的 live range:

```text
v:
|------------------------------|
```

如果把整个 $v$ spill 到 stack, 原来对 $v$ 的 use 可能被改写成:

```text
load t1, [slot]
use t1

...

load t2, [slot]
use t2
```

原来的长生命周期被若干短 temporary 取代:

```text
t1:
|---|

t2:
                    |---|
```

`t1` 只和第一个局部区域里的 values 冲突, `t2` 只和第二个区域里的 values 冲突. 因为 rewrite 已经改变 def/use 和 liveness, 原来的 interference graph 也需要重新计算. 传统 graph-coloring allocator 因此经常形成这样的迭代过程:

```text
Build graph
    |
    v
Simplify / Color
    |
    v
Choose spill
    |
    v
Rewrite program
    |
    v
Recompute liveness
    |
    +------> Build graph again
```

Live range splitting 做得更细. 假设 $v$ 前半段与 $a,b,c$ 冲突, 中间与 $d,e,f$ 冲突, 后半段与 $g,h$ 冲突. 如果始终把 $v$ 当作一个节点, 它会有 $Adj(v)={a,b,c,d,e,f,g,h}$. 如果把生命周期拆成三个 fragments:

```text
v1:
|---------|

v2:
           |----------|

v3:
                       |--------|
```

那么可以得到更局部的冲突集合, 例如 $Adj(v_1)={a,b,c}$, $Adj(v_2)={d,e,f}$, $Adj(v_3)={g,h}$. 三个 fragments 可以分别做 allocation decision, 甚至分别使用不同物理寄存器, 中间通过 copy 或 memory location 连接.

这类操作说明 register allocation 的输入结构本身是可以被修改的. 现代 allocator 经常通过 splitting, rematerialization, spill rewrite 等方式重新塑造 live ranges, 再解决一个更容易的局部 allocation problem.

## 7 真实机器对简单 coloring 模型的扩展

前面的 K-coloring 模型假设每个节点拥有同一组颜色. Register class 一出现, 这个假设就开始放宽. 假设机器有 $GPR={R_0,R_1,R_2,R_3}$ 和 $FPR={F_0,F_1,F_2,F_3}$, 整数 virtual register 只能选择 GPR, 浮点 virtual register 只能选择 FPR. 不同节点因此会拥有不同的 candidate set.

还可能出现部分重叠的候选集合. 例如 $Candidates(a)={R_0,R_1,R_2}$, $Candidates(b)={R_1,R_2,R_3}$. 这时 allocator 除了处理 $a$ 与 $b$ 是否 interfere, 还需要处理各自允许选择哪些颜色.

Pre-colored register 又引入固定颜色. 某些 ABI 或指令约束会要求一个值位于指定物理寄存器. 如果节点 $p$ 已经固定为 $color(p)=RAX$, 任何与 $p$ 冲突的节点都必须避开 $RAX$. 如果有:

```text
RAX = COPY v
```

allocator 反而会希望在合法的情况下直接令 $v\mapsto RAX$, 从而消除这条 COPY. 所以工业 assignment 同时包含硬约束和 register preference.

Register aliasing 会让颜色本身发生重叠. x86 的 `RAX`, `EAX`, `AX`, `AL` 等寄存器共享底层硬件状态. 即使它们名字不同, 也不能被当成四个完全独立的颜色. 某些 value 还会占用 register pair 或 register tuple, 例如一个值可能要求 $(R_2,R_3)$ 两个连续寄存器, GPU vector value 也可能要求连续 VGPR tuple. 连续性, 对齐和 subregister constraint 都需要额外的 target-specific 表示.

因此 textbook K-coloring 提供的是 register interference 的基本模型. 当机器约束逐渐加入以后, 实际问题会演化成带有不同 candidate sets, fixed assignments, aliasing, tuples 和 assignment costs 的受约束资源分配问题.

## 8 显式冲突图与按需 interference query

经典 Chaitin-Briggs allocator 通常会显式保存 interference graph. 对每个节点维护 $Adj(v)$ 和 $degree(v)$, simplify 时删除节点并更新邻居 degree, select 时查看已经着色的邻居使用了哪些颜色. 这种结构和算法本身非常契合.

显式图也有成本. 如果函数中有 $N$ 个 virtual registers, interference edge 在最坏情况下可以接近 $O(N^2)$. 而且图只告诉 allocator 两个值曾经冲突过, 不能直接告诉它们在哪段 live range 上发生重叠.

使用 live intervals 的 allocator 可以采用另一种方式. 假设:

```text
a:
[2, 10)      [20, 30)

b:
      [8, 15)
```

因为区间 $[2,10)$ 和 $[8,15)$ 有交集, allocator 可以在真正需要检查时发现 $a$ 与 $b$ interfere. 这种方式把时间位置信息保留下来, 对 splitting 和局部冲突查询更方便, 同时避免预先物化整张全局图.

LLVM Greedy Register Allocator 大量使用 LiveIntervals 和按需 interference checking, 整体结构和 textbook Chaitin allocator 有明显差异. GCC IRA 保留了更直接的 conflict 和 coloring 体系, 但也围绕 allocno, object, region 等抽象扩展了经典图模型.

因此后面看到 "interference" 时需要区分两个层次. 一层是数学上的关系: 两个 live ranges 不能同时占用同一份物理寄存器资源. 另一层是实现选择: compiler 可以把这种关系显式存成 graph edge, 也可以利用 live range 数据结构在需要时计算.

下一部分将沿着显式 interference graph 继续, 进入 Chaitin 和 Briggs 的经典 Graph Coloring Register Allocation. Build 阶段已经在这一部分基本解决, 接下来要研究 simplify 如何依靠 $degree<K$ 逐步缩小图, 图无法继续 simplify 时如何选择 potential spill, 以及 select 阶段为什么仍然可能把 high-degree 节点成功着色.
