---
title: "第四部分: 经典 Graph Coloring Register Allocation"
slug: "graph-coloring"
lang: zh-Hans
series: register-allocation
weight: 50
created: 2026-08-14
updated: 2026-09-09
license: CC-BY-SA-4.0
---

上一部分已经把寄存器分配抽象成了图着色问题. 给定 interference graph $G=(V,E)$ 和 $K$ 个可用物理寄存器, allocator 希望给每个节点分配一种颜色, 并保证相邻节点颜色不同. 真正困难的地方在于, 一般图的 $K$-coloring 很难直接求解, 而编译器还需要同时决定哪些值值得 spill, spill 之后怎样改写程序, 以及如何在有限编译时间内获得足够好的结果.

经典 graph coloring register allocation 的基本思路由 Chaitin 等人的工作奠定. 它利用一个简单的图论性质不断缩小 interference graph: 如果节点 $v$ 满足 $degree(v)<K$, 那么先暂时删除 $v$ 不会破坏剩余图的可着色性. 等剩余节点都处理完之后, 再按相反顺序恢复这些节点并选择颜色. 当图中已经找不到低 degree 节点时, allocator 需要选择一个可能被 spill 的节点来继续缩小图.

这套流程通常可以概括为 Build, Simplify, Spill, Select 和 Rewrite. 不同文献对阶段名称和细节会有一些差异, 尤其是 Chaitin 原始方法和 Briggs 后来的 optimistic coloring 在 spill 的处理时机上并不完全相同. 先从最基本的 simplify 过程开始看.

## 1 Simplify: 逐步拆掉容易着色的节点

假设目标机器有 $K=3$ 个寄存器, 当前 interference graph 是:

```text
      a
     / \
    b---c
    |
    d
```

各节点 degree 为 $degree(a)=2$, $degree(b)=3$, $degree(c)=2$, $degree(d)=1$.

因为 $d$ 满足 $degree(d)<3$, allocator 可以先把 $d$ 从图中移除, 同时把它压入一个栈中. 删除 $d$ 以后, $b$ 的 degree 从 3 降到 2. 这时图变成:

```text
      a
     / \
    b---c
```

现在 $a$, $b$, $c$ 的 degree 都是 2, 仍然小于 $K=3$. 可以继续删除其中任意一个, 例如先删 $a$, 再删 $b$, 最后删 $c$.

删除顺序可能是:

```text
d
a
b
c
```

如果每次删除都压入 stack, 最终得到:

```text
top
 |
 v
c
b
a
d
```

着色阶段会按相反顺序处理, 也就是先处理最后删除的节点.

为什么这种删除是安全的, 第三部分已经给出了基本原因. 当删除节点 $v$ 时, 如果 $degree(v)<K$, 那么它最多有 $K-1$ 个邻居. 即使这些邻居最终使用了完全不同的颜色, 也最多占掉 $K-1$ 种颜色. 等 $v$ 被放回来时, 至少还有一种颜色可用.

需要注意的是, simplify 时删除节点会不断改变其他节点的 degree. 一个最开始 degree 很高的节点, 可能随着邻居陆续删除而变成低 degree 节点. 因此算法关心的是当前简化图里的 degree, 不是最初 interference graph 中固定不变的 degree.

例如:

```text
        a
       /|\
      b c d
```

如果 $K=3$, 开始时 $degree(a)=3$, 无法利用 $degree<K$ 的保证直接删除 $a$. 但如果 $b$ 和 $c$ 因为其他原因先被 simplify, $a$ 的当前 degree 就会下降到 1, 此时也可以安全移除.

这也是 simplify 的主要价值. 算法没有直接解决整张图的 coloring, 而是利用局部容易处理的节点逐渐剥离图结构, 把真正困难的部分留到最后.

## 2 当 Simplify 停下来时

并不是所有图都能一直找到 $degree<K$ 的节点. 假设 $K=3$, interference graph 是完全图 $K_4$:

```text
      a------b
      |\    /|
      | \  / |
      |  \/  |
      |  /\  |
      | /  \ |
      |/    \|
      c------d
```

每个节点的 degree 都是 3, 因此不存在 $degree<3$ 的节点. Simplify 在这里停住了.

更一般地, 算法可能遇到一个 remaining graph, 其中所有节点都有 $degree\ge K$. 这并不能证明每个节点都必须 spill, 只能说明 simplify 所依赖的安全保证已经无法继续使用.

Chaitin-style allocator 此时会选择一个节点作为 spill candidate, 暂时把它从图中移除. 删除这个节点以后, 它的邻居 degree 会下降, simplify 往往又可以继续进行.

例如还是 $K_4$, 假设选择 $d$:

```text
      a
     / \
    b---c
```

剩余三个节点形成三角形, 在 $K=3$ 的情况下都满足 $degree=2<K$. 于是整张图又能继续 simplify.

问题就转化成了: 应该选哪个节点作为 spill candidate?

最简单的策略可以根据 degree 选择, 但实际效果通常不好. Spill 会在程序里产生额外的 load 和 store, 某个节点的动态使用频率往往比图结构本身更能决定 spill 的运行代价. 一个在冷路径上使用一次的值和一个位于内层循环中的值, 即使 degree 相同, spill 后的成本也可能相差几个数量级.

因此经典 allocator 往往会估算一个 spill cost. 一个简单模型可以把 use 和 def 的执行频率累积起来, 再结合 degree 做归一化. 教材中经常看到类似 $\frac{spillCost(v)}{degree(v)}$ 的启发式指标. 如果这个值较小, 说明节点占据了较多冲突资源, 同时 spill 代价相对较低, 因而更适合作为候选.

Spill cost 的具体公式没有唯一标准. 可以考虑 loop depth, block frequency, use 次数, def 次数, memory access cost 等因素. 工业实现还会利用 profile information 和 target-specific cost model. 图着色算法本身只要求在 simplify 卡住时能够选择一个节点继续推进, spill heuristic 决定的是这种选择对最终代码质量有多大影响.

## 3 Chaitin 的 spill 与 Briggs 的 optimistic coloring

这里需要区分两种处理 high-degree node 的方式.

较早的 Chaitin-style 思路对 spill candidate 更悲观. 如果图中没有低 degree 节点, allocator 会选择一个节点准备 spill, 修改程序, 重新计算 liveness, 再重新构造 interference graph. 这种做法能够保证新的图更容易着色, 但也可能产生不必要的 spill.

原因在第三部分已经见过. $degree(v)\ge K$ 只说明无法保证 $v$ 一定有颜色, 并没有证明最后真的没有颜色.

Briggs 提出的 optimistic coloring 利用了这一点. 当 simplify 卡住时, allocator 仍然选出一个 potential spill candidate, 但先不立刻改写程序. 它把这个节点像普通节点一样从图中删除并压栈, 然后继续 simplify. 等到 select 阶段真正恢复这个节点时, 再检查它的邻居实际使用了哪些颜色.

例如 $K=3$, 某个节点 $v$ 在 simplify 时有四个邻居:

```text
      a
      |
b ----v---- c
      |
      d
```

所以 $degree(v)=4\ge3$. 如果立刻根据 degree 判断 spill, 就会把 $v$ 写入内存.

采用 optimistic coloring 后, $v$ 先作为 potential spill 被移除. 等 select 阶段重新处理 $v$ 时, 假设邻居最终分配为 $a\mapsto R_0$, $b\mapsto R_0$, $c\mapsto R_1$, $d\mapsto R_1$. 虽然 $v$ 有四个邻居, 它们实际只占用了两种颜色, 因此 $v$ 可以使用 $R_2$.

只有当相邻节点真正覆盖了 $v$ 的全部可用颜色时, $v$ 才成为 actual spill. 比如 $K=3$, 最终相邻节点使用的颜色集合是 ${R_0,R_1,R_2}$, 那么 $v$ 就无法获得颜色.

这也是 potential spill 和 actual spill 的区别. Potential spill 是 simplify 阶段为了继续缩小图而选择的高风险节点, actual spill 则是在 select 阶段确认无合法颜色之后产生的结果.

Briggs 的这一改动看起来很小, 但它改变了算法看待 high-degree node 的方式. High degree 只参与启发式决策, 最后的 assignment 仍然由实际颜色占用决定.

## 4 Select: 从栈中恢复节点并选择颜色

Simplify 阶段结束时, interference graph 已经被逐步删除为空, 所有节点都保存在 stack 中. Select 阶段按照后进先出的顺序恢复节点.

假设有 $K=3$, 颜色为 $R_0$, $R_1$, $R_2$, stack 是:

```text
top
 |
 v
c
b
a
d
```

首先弹出 $c$. 此时图中还没有已经着色的邻居, 可以给它选择任意合法颜色, 例如 $c\mapsto R_0$.

随后弹出 $b$. 如果 $b$ 与 $c$ interfere, 那么 $R_0$ 已经被相邻节点占用, 可以选择 $b\mapsto R_1$.

接着弹出 $a$. 如果 $a$ 同时和 $b$, $c$ 冲突, 那么它看到的已使用颜色是 ${R_0,R_1}$, 因此选择 $a\mapsto R_2$.

最后恢复 $d$. 假设 $d$ 只和 $b$ 冲突, 那么它只需要避开 $R_1$, 可以使用 $R_0$ 或 $R_2$.

这个过程可以写成简单的伪代码:

```text
while stack is not empty:
    v = pop(stack)

    forbidden = colors used by colored neighbors of v
    available = legal_colors(v) - forbidden

    if available is not empty:
        color[v] = choose one color from available
    else:
        mark v as actual spill
```

在最简单的理论模型中, `legal_colors(v)` 就是全部 $K$ 个颜色. 有 register class, pre-colored registers 和 target constraints 以后, 每个节点的合法颜色集合可能不同.

Select 也可以利用 register preference. 假设 $v$ 和某个节点之间存在 COPY relation, 并且对方已经获得 $R_1$, 那么在 $R_1$ 合法的情况下, allocator 可以优先选择 $R_1$, 从而消除 move. 这种偏好不会改变合法性约束, 但会影响最终生成的机器指令数量.

在包含 optimistic coloring 的算法里, select 也是判断 potential spill 是否真正需要 spill 的阶段. 一个 high-degree node 被弹出时, allocator不再关心它最初的 degree, 只检查现在已经着色的邻居实际阻塞了哪些颜色.

## 5 Rewrite: Spill 如何改变程序

如果 select 阶段发现某个节点没有合法颜色, allocator 需要把它 spill. Spill 不能只在内部数据结构里给节点标一个 "memory" 颜色, 因为机器的大多数算术指令仍然要求 operand 位于寄存器中. Compiler 必须修改机器 IR, 在需要的位置插入 load 和 store.

假设原来有:

```text
v = ...
...
x = v + 1
...
y = v * 2
```

如果 $v$ 被 spill, 可以给它分配一个 stack slot:

```text
spill_slot[v]
```

definition 之后把值写入内存:

```text
v_tmp = ...
store v_tmp, [spill_slot]
```

每次 use 前再生成新的 temporary:

```text
load t1, [spill_slot]
x = t1 + 1

...

load t2, [spill_slot]
y = t2 * 2
```

原来 $v$ 可能拥有一个很长的 live range:

```text
v:
|-----------------------------|
```

改写以后, 新生成的 $t1$, $t2$ 往往只有很短的生命周期:

```text
t1:
       |---|

t2:
                       |---|
```

所以 rewrite 会直接改变 liveness 和 interference graph. 新 temporaries 需要重新分配寄存器, 但由于它们的 live ranges 较短, 通常比原来的长生命周期更容易着色.

因此经典 allocator 在发生 actual spill 后通常需要重新开始一轮:

```text
Build
  |
  v
Simplify
  |
  v
Select
  |
  +---- no actual spill ----> finish
  |
 actual spill
  |
  v
Rewrite
  |
  v
recompute liveness
  |
  +-------------> Build again
```

这个迭代过程可能运行多轮. 如果第一次 rewrite 生成的新 temporaries 又导致新的冲突, 下一轮 allocation 可能继续选择其他 spill. 一个好的 spill heuristic 会尽量减少这种反复和最终产生的动态内存访问.

Spill 也不一定必须真的执行 memory load. 如果一个值很容易重新计算, allocator 可以使用 rematerialization. 例如某个值只是常量 `0` 或一个便宜的地址计算, 在 use 位置重新生成它可能比从 stack load 更划算. 这部分会在后面的高级优化中展开.

## 4.6 一个完整的着色过程

下面用一个稍微复杂一点的图把 simplify, potential spill 和 select 串起来. 假设 $K=3$:

```text
       a
      /|\
     b-+-c
      \|/
       d
       |
       e
```

假设边集合为 $(a,b)$, $(a,c)$, $(a,d)$, $(b,c)$, $(b,d)$, $(c,d)$ 和 $(d,e)$. 其中 $a,b,c,d$ 构成 $K_4$, $e$ 只和 $d$ 冲突.

初始 degree 为 $degree(a)=3$, $degree(b)=3$, $degree(c)=3$, $degree(d)=4$, $degree(e)=1$.

因为 $degree(e)<3$, 先 simplify `e`. 删除以后 $degree(d)$ 从 4 降到 3. 剩余的 $a,b,c,d$ 每个 degree 都是 3, 没有节点满足 $degree<3$.

此时 allocator 根据 spill heuristic 选择 $d$ 作为 potential spill, 将它移除并压栈. 删除 $d$ 以后, 剩余图成为:

```text
    a
   / \
  b---c
```

现在三个节点的 degree 都是 2, 因此可以继续 simplify. 假设依次删除 $a$, $b$, $c$. 整个删除顺序为:

```text
e
d   <- potential spill
a
b
c
```

stack 顶部是最后删除的 $c$:

```text
top
 |
 v
c
b
a
d
e
```

Select 时先处理 $c$, 给它 $R_0$. 接着 $b$ 和 $c$ 冲突, 给 $b$ 分配 $R_1$. 然后恢复 $a$, 它同时和 $b$, $c$ 冲突, 因此获得 $R_2$.

接下来轮到 potential spill 节点 $d$. 它和 $a$, $b$, $c$ 都冲突, 而这三个节点已经分别使用了 $R_2$, $R_1$, $R_0$. 此时 $d$ 的三个颜色全部被阻塞, 所以它确实成为 actual spill.

最后恢复 $e$. 如果 $d$ 已经准备 spill, $e$ 的寄存器选择通常不会再受到 $d$ 的普通物理寄存器颜色限制, 因此可以正常获得寄存器.

这个例子中的 $K_4$ 确实需要四种颜色, 所以某个节点最终无法在三个物理寄存器中完成 assignment. 如果换成另一个 high-degree graph, potential spill 节点的邻居可能复用颜色, 那么 select 时就可能避免 actual spill.

这也说明 simplify 阶段和 select 阶段承担不同职责. Simplify 根据 degree 寻找结构上容易处理的节点, 在必要时做带风险的 potential spill 选择. Select 才看到邻居实际使用的颜色, 最终确定每个节点能否获得物理寄存器.

## 7 Chaitin-Briggs 算法真正优化了什么

纯粹的 graph K-coloring 只关心是否能找到合法颜色. Register allocator 还需要面对代码质量问题. 两个不同 coloring 都可能完全合法, 但其中一个产生更多 COPY, 另一个可能使用昂贵的 callee-saved register; 两种 spill 方案也可能产生完全不同的动态 load/store 数量.

因此经典 graph-coloring allocator 通常有几个互相配合的启发式层面. Simplify 依据 degree 保持可着色性, spill selection 依据 cost model 选择比较合适的牺牲对象, select 阶段利用 register preference 决定具体物理寄存器, coalescing 则尝试消除 COPY. 这些机制共同作用, 最终获得的是一个可接受的近似解.

这一点也能解释为什么 textbook Chaitin-Briggs 算法无法单独代表 GCC IRA 或 LLVM Greedy 这样的工业 allocator. Chaitin-Briggs 给出了 interference graph, degree, simplify 和 spill 的清晰理论框架, 工业实现还要处理 live range splitting, register classes, fixed constraints, rematerialization, eviction, scheduling interaction 等问题.

下一部分会把目前暂时搁置的 COPY 问题完整展开. 在 interference graph 中, move-related nodes 希望获得相同颜色, aggressive coalescing 又可能让图更难着色. Briggs 和 George 提出的 conservative coalescing 条件, 以及 Iterated Register Coalescing 中的 Simplify, Coalesce, Freeze 和 SelectSpill, 会把 graph coloring allocator 进一步发展成一套完整的 move-aware 算法.
