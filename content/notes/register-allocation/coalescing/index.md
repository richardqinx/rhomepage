---
title: "第五部分: Coalescing 与 Iterated Register Coalescing"
slug: "coalescing"
lang: zh-Hans
series: register-allocation
weight: 60
created: 2026-08-14
updated: 2026-09-09
license: CC-BY-SA-4.0
---

第四部分暂时把 interference graph 当成了一张只包含硬约束的图: 两个节点之间有边, 就必须分配不同颜色. 真实机器 IR 中还大量存在另一类关系, 即 COPY 或 move. 对于一条 `b = COPY a`, allocator 希望 $a$ 和 $b$ 最终获得同一个物理寄存器, 这样 COPY 就可以消失. 这使寄存器分配同时面对两种方向相反的约束: interference 希望两个节点分开, move 希望两个节点靠拢.

COPY 的来源很多. SSA destruction 会把 phi 转换成边上的 copy, calling convention 会在参数寄存器和普通虚拟寄存器之间产生 copy, instruction selection 和 two-address lowering 也会引入 move. Live range splitting 本身还会制造新的 copy, 用于连接同一个逻辑值的不同 fragments. 因此 allocator 如果完全忽略 move, 最终机器代码里往往会保留大量本可消除的寄存器间复制.

让 COPY 两端获得同一个颜色的操作称为 register coalescing. 问题在于, coalescing 会合并两个 live ranges, 也会合并它们各自的 interference relation. 一次看起来很有收益的 move elimination, 可能让 interference graph 变得更难着色. Iterated Register Coalescing, 简称 IRC, 就是在 simplify, coalesce, freeze 和 spill 之间反复切换, 尽量消除 move, 同时控制 coalescing 对 colorability 的破坏.

## 1 为什么不能看到 COPY 就直接合并

考虑:

```text
v = COPY u
```

如果 $u$ 和 $v$ 没有 interference edge, 最直观的想法就是把两个节点合成一个节点 $uv$. 合并之后所有对 $u$ 或 $v$ 的引用都视为对同一个节点的引用, 如果最终 $uv\mapsto R_1$, 原来的 COPY 就会变成 `R1 = COPY R1`, 随后删除.

但 "没有 interference edge" 只说明 $u$ 和 $v$ 的生命周期允许共享寄存器, 并不能保证整张图仍然存在一个让它们共享颜色的 $K$-coloring.

假设 $K=3$, 有三个节点 $a$, $b$, $c$ 两两冲突, 因而形成一个三角形. 此外 $u$ 和 $a,b$ 冲突, $v$ 和 $b,c$ 冲突, $u$ 与 $v$ 之间存在 COPY, 但没有 interference edge:

```text
       u           v
      / \         / \
     a---b-------?   c
      \___________/

a, b, c form a triangle

u interferes with a, b
v interferes with b, c
u <---- COPY ----> v
```

更准确地列出边就是:

```text
a -- b
b -- c
a -- c

u -- a
u -- b

v -- b
v -- c
```

三角形 $a,b,c$ 在三个寄存器下必须使用三种不同颜色. 假设 $a\mapsto R_0$, $b\mapsto R_1$, $c\mapsto R_2$. 那么 $u$ 与 $a,b$ 冲突, 所以只能使用 $R_2$; $v$ 与 $b,c$ 冲突, 所以只能使用 $R_0$. 原图完全可以 3-color, 只是 $u$ 和 $v$ 必须使用不同颜色.

如果强行把 $u$ 和 $v$ 合并成 $w$, 那么 $w$ 会同时与 $a$, $b$, $c$ 冲突. 合并后的 $a,b,c,w$ 构成 $K_4$, 需要四种颜色. 原来能够在三个寄存器中完成分配的图, 经过这次 coalescing 后就无法再 3-color.

所以 coalescing 需要一个保守条件. allocator 希望确认这次合并不会明显破坏后续 coloring 的机会, 然后才真正把两个节点收缩成一个.

这种策略通常称为 conservative coalescing.

## 2 Briggs criterion 与 George criterion

Briggs criterion 从合并之后节点的 high-degree neighbors 数量出发. 假设准备合并 $u$ 和 $v$, 目标机器有 $K$ 个颜色. 先取两个节点当前邻居集合的并集 $Adj(u)\cup Adj(v)$, 再观察其中有多少节点满足 $degree(t)\ge K$. 如果这样的 high-degree neighbors 少于 $K$ 个, Briggs 认为这次合并足够保守.

也就是说, Briggs 检查的是 $Adj(u)\cup Adj(v)$ 中 significant nodes 的数量, 其中 significant 通常指 $degree\ge K$ 的节点. 条件可以在正文里写成: 如果 $\left|{t\in Adj(u)\cup Adj(v)\mid degree(t)\ge K}\right|<K$, 那么允许 coalesce.

它背后的考虑和 simplify 一致. 合并后的节点即使当前 degree 很高, 其中许多邻居如果本身属于 low-degree nodes, 后续 simplify 时还可能陆续被删除. 真正容易把合并节点困住的是那些 $degree\ge K$ 的邻居. 如果这种邻居还不到 $K$ 个, 合并后的结构通常仍然保留足够好的可着色性.

刚才那个失败的例子正好可以用 Briggs criterion 检查. 在 $K=3$ 时, $a,b,c$ 都至少有 3 个邻居, 所以它们都是 significant. 对 $u$ 和 $v$ 做邻居并集后, high-degree neighbors 至少包含 ${a,b,c}$, 数量正好是 3, 不满足 "少于 $K$" 的要求, 因此 Briggs 会拒绝这次 coalescing.

George criterion 更适合处理一个普通 virtual register 与 pre-colored physical register 的 coalescing. 例如有:

```text
v = COPY RAX
```

如果可以把 $v$ 合并到 pre-colored 的 `RAX` 节点, COPY 就能删除. 但 `RAX` 的颜色已经固定, 不能像普通节点一样参与随后的 simplify 和重新着色.

设 $u$ 是 pre-colored node, 准备将普通节点 $v$ 合并到 $u$. George 的思路是逐个检查 $v$ 的邻居 $t$. 如果 $t$ 本身是 low-degree, 即 $degree(t)<K$, 那么它以后比较容易处理; 如果 $t$ 已经和 $u$ interfere, 合并不会给 $u$ 增加一条新的约束; 对 pre-colored 邻居也可以按固定颜色约束处理. 只有那些 high-degree, 尚未和 $u$ 冲突, 并且会因为合并而成为 $u$ 新邻居的节点, 才真正增加风险.

在经典 IRC 的写法中, 对每个 $t\in Adj(v)$ 检查类似条件: $degree(t)<K$, 或者 $t$ 已经是 pre-colored, 或者 $(t,u)\in E$. 如果所有邻居都通过检查, 就可以把 $v$ 合并进 $u$.

Briggs 更像是从合并后的整体邻域判断风险, George 更关注这次合并究竟给一个已有节点增加了哪些新的困难约束. 在 IRC 中, 当一端是 pre-colored node 时通常使用 George-style test; 两端都是普通节点时通常使用 Briggs-style conservative test.

## 3 Coalescing 会怎样修改图

假设经过 conservative test 后决定把 $v$ 合并到 $u$. allocator 不能只记录 "以后让它们用同一个颜色", 因为从这一刻开始, 其他图操作需要把它们看成同一个逻辑节点.

如果原来:

```text
Adj(u) = {a, b}
Adj(v) = {b, c}
```

合并以后大致得到:

```text
Adj(uv) = {a, b, c}
```

同时所有原来指向 $v$ 的 interference relation 都要转移到代表节点 $u$ 上. $u$ 和 $v$ 各自关联的 move 也要合并, 因为新的联合节点仍然可能与其他节点存在 COPY relation.

经典实现通常不会真的把所有数据结构里的 `v` 文本替换成 `u`. 它会保留一个 `alias` 关系. 如果 $v$ 被合并进 $u$, 可以记录 $alias[v]=u$. 后面如果又把其他节点合并到 $v$, 查询时通过 `GetAlias(v)` 一直沿 alias 链找到当前代表节点.

例如:

```text
v3 -> v2
v2 -> v1
```

那么:

```text
GetAlias(v3) = v1
```

最终 coloring 完成以后, coalesced nodes 直接继承其代表节点的颜色. 如果 $v$ 被合并到 $u$, 最后有 $color(u)=R_2$, 那么自然得到 $color(v)=R_2$.

Coalescing 还会改变 degree. 当 $v$ 的边转移给 $u$ 后, 某些邻居可能新增与 $u$ 的 interference, 某些边则已经存在, 不需要重复计算. 合并后的 $u$ 也可能从 low-degree 变成 high-degree, 因而从一个适合 freeze 的节点转移到 spill candidate 集合. 这说明 coalescing 和 simplify 不能各自独立运行一次, 两者需要反复交替.

## 4 为什么需要 Freeze

假设一个节点 $v$ 满足 $degree(v)<K$. 按照第四部分的 simplify 原理, 它可以安全移出图. 但如果 $v$ 还参与 COPY, 立刻 simplify 会错过后面进行 coalescing 的机会.

因此 IRC 会进一步区分 low-degree nodes. 没有活跃 move relation 的 low-degree node 可以进入 `simplifyWorklist`; 仍然 move-related 的 low-degree node进入 `freezeWorklist`. 后者暂时保留在图中, 让算法先尝试处理它关联的 COPY.

这里的 move-related 可以理解成节点仍然参与某个尚未决定命运的 move. 假设 $moveList(v)$ 保存所有与 $v$ 有关的 moves, 那么只要其中还有 move 位于 `worklistMoves` 或 `activeMoves`, $v$ 就仍然被视为 move-related.

问题是, 某些 COPY 经过 conservative test 后暂时不能 coalesce, 图里又可能没有别的可合并 move. 如果所有 low-degree nodes 都因为 move relation 停在 `freezeWorklist`, allocator 就无法继续 simplify.

Freeze 的作用是在这种时候主动放弃某些 COPY 的 coalescing 机会.

假设有:

```text
v = COPY u
```

当前无法安全 coalesce, 但 $v$ 是 low-degree node. Freeze $v$ 时, allocator 会把与 $v$ 相关的尚未处理 move 标记为 frozen. 这相当于接受 "这条 COPY 以后可能保留下来" 这个结果. 一旦这些 move 不再被视为待 coalesce, $v$ 就可能变成 non-move-related node, 随后进入 `simplifyWorklist`.

Freeze 不会给两个节点建立 interference edge, 也没有强制它们最终使用不同颜色. 它只是停止主动追求这条 move 的合并. 如果最后 coloring 恰好让两端获得同一个寄存器, COPY 仍然有可能被后续清理掉. IRC 在这里放弃的是 coalescing 的算法保证和继续等待的成本.

这样一来, low-degree node 的状态大致会在两种工作集合之间转换:

```text
low degree + not move-related
        |
        v
simplifyWorklist

low degree + move-related
        |
        v
freezeWorklist
```

而 $degree\ge K$ 的普通节点通常进入 `spillWorklist`. 名字里的 `spillWorklist` 同样不意味着这些节点已经确定要 spill, 它们仍然只是 potential spill candidates.

## 5 Iterated Register Coalescing 的整体流程

IRC 的核心设计是让 Simplify, Coalesce, Freeze 和 SelectSpill 在同一个循环中不断改变图的状态. 一次 coalescing 可能降低或提高某些节点的处理优先级, simplify 会降低邻居 degree, degree 下降以后原来不安全的 coalescing 又可能变得安全, freeze 又可以解除 move relation 对 simplify 的阻塞. 所以算法不断在这些操作之间循环, 直到所有节点都被移出当前图.

一个典型的顶层结构可以写成:

```text
Build
MakeWorkList

while simplifyWorklist is not empty
   or worklistMoves is not empty
   or freezeWorklist is not empty
   or spillWorklist is not empty:

    if simplifyWorklist is not empty:
        Simplify()

    else if worklistMoves is not empty:
        Coalesce()

    else if freezeWorklist is not empty:
        Freeze()

    else:
        SelectSpill()

AssignColors()

if spilledNodes is not empty:
    RewriteProgram()
    restart allocation
```

这个优先顺序体现了算法的偏好. 有安全可 simplify 的节点时先 simplify; 有待处理 COPY 时尝试 coalesce; coalescing 暂时无法推进时才 freeze; 只有这些方法都不能推进图时才选择 potential spill.

`Simplify()` 和第四部分基本一致. 从 `simplifyWorklist` 中拿一个节点 $n$, 压入 `selectStack`, 然后删除它对当前图的影响. 每个邻居的 degree 减 1. 如果某个邻居原本恰好满足 $degree=K$, 减少以后变成 $K-1$, 它从 high-degree 变成 low-degree, 这可能改变它所在的 worklist.

如果这个邻居已经没有待处理 moves, 可以进入 `simplifyWorklist`. 如果仍然 move-related, 则进入 `freezeWorklist`. 同时 degree 的下降还可能让与它关联的 `activeMoves` 重新满足 conservative coalescing 条件, 因此这些 moves 可以重新进入待尝试状态.

`SelectSpill()` 则从 `spillWorklist` 中根据 spill heuristic 选择一个节点 $m$. 它不会立刻生成 load/store, 只是把 $m$ 移到 simplify 流程中, 相当于接受它可能在 AssignColors 阶段失败. 这就是上一部分讲过的 optimistic coloring 在 IRC 中的体现.

## 6 一个 move 在 IRC 中会经历哪些状态

IRC 不只维护节点 worklists, move 本身也有状态.

新构建出来, 还等待尝试 coalescing 的 move 放在 `worklistMoves`. 当 `Coalesce()` 取出一条 move $x\leftarrow y$ 时, allocator 先通过 alias 找到当前真正的两个代表节点 $u=GetAlias(x)$ 和 $v=GetAlias(y)$.

如果 $u=v$, 说明之前的其他 coalescing 已经间接把两端合成了同一个节点. 这条 move 可以直接放入 `coalescedMoves`.

如果 $u$ 和 $v$ 已经存在 interference edge, 那么它们不能共享颜色, move 进入 `constrainedMoves`. 这种 COPY 无法通过 coalescing 消失.

如果两端没有 interference, 并且通过 George 或 Briggs 的 conservative test, allocator 执行 `Combine(u,v)`, move 同样进入 `coalescedMoves`.

还有一种情况是两端目前没有 interference, 但 conservative test 暂时失败. 这并不意味着以后永远不能合并. 随着 simplify 删除邻居, degree 可能下降, 原来危险的 coalescing 可能变得安全. 因此 IRC 把这种 move 放进 `activeMoves`, 暂时等待图结构变化.

最后, Freeze 主动放弃某条 move 的 coalescing 尝试时, 它会进入 `frozenMoves`.

于是这些集合表达了 move 的不同命运:

|集合|含义|
|---|---|
|`worklistMoves`|等待尝试 coalescing|
|`activeMoves`|当前不安全, 等待图变化|
|`coalescedMoves`|两端已经合并|
|`constrainedMoves`|两端存在硬冲突, 无法合并|
|`frozenMoves`|allocator 主动停止尝试合并|

这里 `activeMoves` 的存在很有意义. 如果一次 conservative test 失败就永久放弃 move, simplify 后降低 degree 所带来的新机会就利用不上. IRC 中的 "Iterated" 很大程度上就体现在这种重新激活上.

## 7 节点 worklist 如何随着 degree 和 move 状态变化

节点也不是从初始化开始就固定属于某个集合. Build 完成后, allocator 通常根据 degree 和 move relation 把普通节点分成三类.

如果 $degree(n)\ge K$, 节点进入 `spillWorklist`. 如果 $degree(n)<K$ 且仍然 move-related, 进入 `freezeWorklist`. 如果 $degree(n)<K$ 且已经没有待处理 moves, 进入 `simplifyWorklist`.

假设一个节点 $n$ 最初满足 $degree(n)=K$, 所以位于 `spillWorklist`. 某个邻居被 simplify 后, $degree(n)$ 下降到 $K-1$. 这时 $n$ 已经具有低 degree. 如果它还参与待处理 COPY, 它会转入 `freezeWorklist`; 如果没有, 就转入 `simplifyWorklist`.

反过来, coalescing 也可能让一个 low-degree node 的邻居集合扩大. 如果合并后的代表节点 degree 升到 $K$ 或以上, 它可能重新进入 high-degree 状态.

因此 IRC 的数据结构本质上维护着一个不断变化的分类系统. Degree 描述 coloring 风险, move-related 描述 coalescing 机会, 两者共同决定一个节点当前应该被 simplify, freeze, 还是暂时作为 spill candidate 保留.

## 8 用一个小例子走一遍 Simplify, Coalesce 和 Freeze

假设 $K=3$, 当前有节点 $a,b,c,d,e$, 并存在两条 COPY:

```text
b = COPY a
e = COPY d
```

冲突关系为:

```text
a -- c
b -- c
b -- d
c -- d
d -- e
```

同时 $a-b$ 没有 interference, 因此第一条 COPY 有机会 coalesce. $d-e$ 已经存在 interference edge, 所以第二条 COPY 无法让两端共享颜色.

开始时, `b = COPY a` 位于 `worklistMoves`. allocator 检查 $a$ 和 $b$ 的邻居集合. 假设合并通过 conservative test, 就把 $a$ 和 $b$ 合并成节点 $ab$.

原来的关系:

```text
a -- c
b -- c
b -- d
```

合并后变成:

```text
ab -- c
ab -- d
```

而 `b = COPY a` 进入 `coalescedMoves`.

对于 `e = COPY d`, 由于 $d-e$ 已经有 interference edge, 这条 move 进入 `constrainedMoves`. allocator 不会再尝试合并它们. 如果 $e$ 此时 degree 很低并且没有其他活跃 move, 它可以进入 `simplifyWorklist`.

随着 $e$ 被 simplify, $d$ 的 degree 下降. 如果 $d$ 原本处于 high-degree 状态, 它可能因此跌到 $K$ 以下, 从 `spillWorklist` 转移到 `simplifyWorklist` 或 `freezeWorklist`.

再考虑另一种情况. 假设 $a-b$ 的 coalescing 第一次因为 high-degree neighbors 太多而没有通过 conservative test, move 会进入 `activeMoves`. 随后若若干邻居被 simplify, $a$ 或 $b$ 周围的 degree 降低, allocator 会重新启用这条 move. 第二次检查时它可能已经满足 Briggs criterion, 于是完成 coalescing.

如果图已经无法继续 simplify, active moves 也没有变得安全, 但存在低 degree 且 move-related 的节点, Freeze 会选择其中一个节点, 把相关 moves 转入 `frozenMoves`. 该节点失去 move-related 状态以后就能进入 simplify. 这样算法不会因为追求 COPY elimination 而卡在原地.

## 9 AssignColors 与 coalesced nodes

IRC 的主循环结束后, 普通节点都已经被压入 `selectStack`, 或者通过 coalescing 成为了另一个节点的 alias. 接下来的 `AssignColors()` 与第四部分的 Select 类似: 依次从栈顶弹出节点, 查看已经着色的邻居占用了哪些物理寄存器, 从合法颜色中选择一个剩余颜色.

对于普通节点 $n$, 可以先构造被邻居阻塞的颜色集合 $Forbidden(n)$, 然后计算 $Available(n)=LegalColors(n)-Forbidden(n)$. 如果 $Available(n)$ 为空, $n$ 加入 `spilledNodes`; 否则从其中选择一个物理寄存器. 如果存在 register preference 或 move hint, allocator 可以优先选择有助于删除 COPY 的颜色.

所有 ordinary nodes 处理完以后, coalesced nodes 通过 alias 继承颜色. 如果 $alias(v)=u$, 那么令 $color(v)=color(u)$. 所以一条成功 coalesced 的 `v = COPY u` 最终天然满足 $color(v)=color(u)$.

如果 `spilledNodes` 非空, allocator 会进行 spill rewrite, 重新计算 liveness 和 interference, 再重新运行整个算法. Spill rewrite 产生的新 temporaries 和新的 COPY 也会重新进入下一轮 IRC. 因此 coalescing 和 spilling 之间也存在反馈: 某次 spill 可能拆短 live range, 让下一轮的 COPY 更容易合并; coalescing 也可能增加 pressure, 最终使某个节点发生 spill.

## 10 IRC 中的数据结构

把算法实现出来时, 需要同时保存图结构, 节点状态和 move 状态. `adjList[n]` 或 `adjSet` 保存 interference relation, `degree[n]` 保存当前简化图中的 degree, `moveList[n]` 保存与节点相关的 COPY, `alias[n]` 记录 coalescing 后的代表节点, `color[n]` 保存最终物理寄存器.

节点状态通常包括 `simplifyWorklist`, `freezeWorklist`, `spillWorklist`, `selectStack`, `coalescedNodes`, `coloredNodes` 和 `spilledNodes`. 前三个表示当前仍在图中的节点分别等待哪种操作; `selectStack` 保存已经 simplify 或 optimistic remove 的节点; `coalescedNodes` 保存被其他节点吸收的节点; 最后的 `coloredNodes` 和 `spilledNodes` 是 AssignColors 后的结果.

这套数据结构看起来繁琐, 原因在于 IRC 同时维护两个会互相影响的过程. Coloring 希望不断删除低 degree nodes, coalescing 希望暂时保留 move-related nodes 等待合并机会. Degree 的变化会改变 coalescing 条件, move 的冻结或合并又会改变节点是否能够 simplify. Worklist 的作用就是明确记录每个对象当前处于哪一个阶段, 避免每次都重新扫描整张图.

从算法结构上看, IRC 已经比单纯的 Chaitin coloring 完整很多. Chaitin 的主要循环围绕 simplify 和 spill 展开, IRC 把 COPY optimization 纳入同一个状态机, 形成:

```text
               +------------------+
               |                  |
               v                  |
           Simplify               |
               |                  |
               v                  |
            Coalesce ------------>+
               |
               v
             Freeze
               |
               v
          SelectSpill
               |
               +------> Simplify

main loop ends
       |
       v
 AssignColors
       |
       v
 Rewrite if spilled
```

实际执行并不会严格按图中的固定环路逐项走一遍. 每次循环都会根据当前 worklist 是否为空选择能够推进的操作, 图和 move 状态随之变化.

## 11 Coalescing 的收益和代价

Coalescing 最直接的收益是减少 register-to-register move. 对 CPU 来说, 某些 move 可能在 rename 阶段成本很低, 某些甚至可以被硬件消除, 但它们仍然可能占用 decode/issue bandwidth, 增加 code size, 并影响调度. 对一些目标机器或特殊 register classes 来说, move 的成本还会更高.

另一方面, coalescing 会延长或合并 live ranges. 原本两个不同时期占用寄存器的值一旦被视为一个更大的 allocation object, 其邻居集合可能增大, register pressure 也可能在某些区域更难处理. 所以 "消除更多 COPY" 和 "避免更多 spill" 并不总是同一个方向.

这也是 conservative coalescing 的基本取舍. Aggressive coalescing 更愿意删除 COPY, 可能付出更多 spill 风险; conservative coalescing 会保留一些 move, 换取更稳定的 colorability. IRC 进一步让这个选择随着 simplify 动态变化, 第一次不安全的 move 可以进入 `activeMoves`, 等 degree 降低后重新尝试.

现代工业 allocator 未必直接实现完整的 textbook IRC 状态机, 但这里形成的几个观念会一直保留下去: COPY 可以形成 register preference, coalescing 会改变 live range 和 interference, 合并需要考虑 pressure, 某些 move 可以推迟处理, 也可以在必要时放弃. 后面看 LLVM RegisterCoalescer, LLVM Greedy 的 register hints, 以及 GCC IRA 的 copy cost 时, 都能看到这些思想的延续.

下一部分进入 Linear Scan Register Allocation. 到那里我们会暂时放下显式 interference graph, 改用 live interval 的线性顺序处理寄存器竞争. 这样可以直接比较两种经典视角: graph coloring 主要保存 "谁和谁冲突", linear scan 则主要保存 "每个值在什么时候存活".
