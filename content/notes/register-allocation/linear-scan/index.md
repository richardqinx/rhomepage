---
title: "第六部分: Linear Scan Register Allocation"
slug: "linear-scan"
lang: zh-Hans
series: register-allocation
weight: 70
created: 2026-08-17
updated: 2026-09-09
license: CC-BY-SA-4.0
---

前面两部分一直沿着 interference graph 展开. Graph coloring 把 liveness 压缩成 "哪些 live ranges 互相冲突", 然后在这张图上寻找颜色. Linear Scan 选择保留另一种信息: 每个值在程序的哪些位置 live. 它先把机器指令排列在线性的 position space 中, 再把每个 value 的生命周期表示成 live interval, 按生命周期出现的顺序向前扫描.

Linear Scan 最初受到重视, 很大程度上来自它的编译速度和实现复杂度. 它尤其适合 JIT 场景, 因为 JIT 编译器需要把编译延迟控制得很低. 但旦 "Linear Scan" 并不意味着所有现代实现都只是一个极简单的线性循环. 一加入 lifetime holes, interval splitting, register constraints, fixed intervals 和更复杂的 spill heuristic, 算法也会逐渐形成相当丰富的数据结构. LLVM 自己曾长期使用 Linear Scan 作为默认优化寄存器分配器, 从 2004 年一直使用到 LLVM 3.0 前后; LLVM 3.0 切换到新的 Greedy allocator 时, 官方回顾也明确指出 Linear Scan 在 LLVM 中已经工作了很多年, 同时暴露出了全局 splitting 和 allocation order 上的限制.

## 1 从 live interval 开始

假设机器指令已经按照某种线性顺序编号:

```text
0    4    8    12    16    20    24    28
|----|----|-----|-----|-----|-----|-----|
```

几个 virtual registers 的生命周期可能是:

```text
v1:  |----------------|
v2:       |------|
v3:                    |---------|
v4:            |-----------------|
```

为了先讲清经典算法, 暂时把每个 value 看成一个连续区间 $[start,end)$. Linear Scan 首先按照 $start$ 从小到大排列所有 intervals. 扫描到一个新 interval 时, allocator 只需要知道哪些旧 intervals 在当前位置仍然 live. 这些 intervals 构成 `active` 集合.

例如当前处理 $v_3$, 它从位置 20 开始. 如果 $v_1$ 在位置 16 已经结束, 那么 $v_1$ 占用的物理寄存器可以立即释放. 如果 $v_4$ 一直活到位置 28, 它仍然留在 `active` 中. 因此 Linear Scan 不需要预先建立一张完整的 interference graph. 两个 intervals 是否竞争寄存器, 可以根据它们在扫描当前位置是否同时 active 来判断.

经典算法的骨架大致如下:

```text
sort intervals by increasing start position

for each interval i:
    ExpireOldIntervals(i)

    if active contains fewer than K intervals:
        assign a free register to i
        add i to active
    else:
        SpillAtInterval(i)
```

这里 `active` 通常按照 interval 的结束位置排序. 这样 `ExpireOldIntervals` 可以从最早结束的 interval 开始检查. 如果某个 active interval $j$ 满足 $end(j)\le start(i)$, 那么 $j$ 已经在新 interval 开始之前死亡, 它的寄存器可以回收到 free register 集合中.

假设机器只有三个寄存器 $R_0,R_1,R_2$, intervals 是:

```text
v1: [0,  8)
v2: [2, 12)
v3: [4, 10)
v4: [9, 16)
```

处理 $v_1$ 时, `active` 为空, 可以令 $v_1\mapsto R_0$. 到 $v_2$ 时, $v_1$ 还没结束, 所以令 $v_2\mapsto R_1$. $v_3$ 开始于 4, 此时 $v_1$, $v_2$ 都 active, 因而使用最后一个空闲寄存器 $R_2$.

扫描到 $v_4$ 时, $start(v_4)=9$. $v_1$ 已经在位置 8 结束, `ExpireOldIntervals` 会把它移出 active 并释放 $R_0$. 因此 $v_4$ 可以直接使用 $R_0$. 整个过程只需要维护当前仍然覆盖扫描位置的 intervals.

这种视角和 interference graph 有一个明显区别. Graph coloring 会提前记录 $v_i$ 与哪些其他 values 冲突; Linear Scan 更关心当前扫描位置上哪些 intervals 还没有结束. 对 straight-line interval model 来说, temporal overlap 本身就足够告诉 allocator 当前有哪些寄存器被占据.

## 2 当所有寄存器都被占用

真正需要做决策的情况发生在 `active` 已经包含 $K$ 个 intervals, 又有一个新 interval 开始时.

假设只有三个寄存器:

```text
v1: |------------------------|   end = 30
v2:    |----------|              end = 16
v3:       |------------|         end = 22
v4:          |-----|             end = 14
             ^
             scan reaches v4
```

当 $v_4$ 开始时, $v_1$, $v_2$, $v_3$ 都还 active. 四个 intervals 在当前位置同时需要资源, 三个寄存器无法全部容纳. 最简单的 Linear Scan spill heuristic 会比较当前 interval 和 active intervals 的结束位置. 如果 active 中结束最晚的 interval 比当前 interval 活得更久, 可以 spill 那个长 interval, 把它的寄存器让给当前 interval; 如果当前 interval 自己结束得最晚, 则直接 spill 当前 interval.

在这个例子中, $v_1$ 的 $end=30$, 而 $v_4$ 的 $end=14$, 因此一种合理选择是暂时牺牲 $v_1$. 这样 $v_4$ 很快就会死亡, 寄存器随后又可以重新使用. 如果反过来把 $v_4$ spill, 只是为了让 $v_1$ 从当前位置一直占据寄存器到 30, 可能造成更多后续冲突.

经典伪代码经常写成类似:

```text
spill = active interval with latest end

if end(spill) > end(current):
    current gets spill's register
    spill goes to memory
    remove spill from active
    add current to active
else:
    current goes to memory
```

"结束得最晚" 是一个很局部的 heuristic. 它利用了扫描顺序提供的信息: 一个很晚才结束的 interval 会长期占据资源, 把它移走可以更快地释放寄存器容量. 更成熟的实现会考虑 use position, spill cost 和 split point. 一个 interval 虽然结束得很晚, 但可能在当前点之后马上就要使用; 另一个 interval虽然整体较短, 下一次 use 却还很远. 只看最终的 `end` 会错过这种区别.

这也是 Linear Scan 后来逐渐发展出 lifetime position based spill decisions 的原因. allocator 可以问 "这个 interval 下一次什么时候真正需要寄存器", 而不只是 "它最后什么时候结束". 如果一个 value 在很长一段距离内都没有 use, 当前寄存器紧张时先把它移出去通常很自然.

## 3 Lifetime holes 和 inactive set

第二部分已经提过, 真实 live range 往往不是单一连续区间. 一个 live interval 可以由多个 segments 组成:

```text
v1:
|---------|          |-----------|

v2:
           |--------|
```

如果只取 $v_1$ 最早的 start 和最晚的 end, 会得到:

```text
v1:
|--------------------------------|
```

这样会把中间的 lifetime hole 也当成寄存器占用区间, 从而制造假的 interference.

支持 holes 的 Linear Scan 通常除了 `active` 之外再维护一个 `inactive` 集合. 当一个 interval 的整个生命周期尚未结束, 但当前位置恰好处于它的 hole 中时, 它从 `active` 移到 `inactive`. 当扫描位置再次进入它的下一个 live segment 时, interval 又可能从 `inactive` 回到 `active`.

例如:

```text
v1: |--------|          |--------|
v2:      |----------------|
              ^
              current position
```

在箭头位置, $v_1$ 整个 interval 还没有结束, 因为右边还有第二个 segment. 但它当前并不 live, 所以不应该继续占据 active 资源. $v_2$ 在这一段可以暂时使用某个不会与 $v_1$ 后续 segment 发生冲突的寄存器; 如果两者后面的 segments 再次重叠, allocator仍然需要提前考虑这种未来冲突.

因此支持 holes 以后, `inactive` 不能被简单视为 "完全不相关". 一个 inactive interval 当前不占据寄存器, 但它未来可能重新变为 active. 当 allocator 为新 interval 选择 physical register 时, 还要检查使用这个寄存器的 inactive intervals 会不会在未来与当前 interval 相交. 这会影响某个物理寄存器 "能够安全使用到哪个位置".

现代 Linear Scan 常用 `free_pos[reg]` 一类信息描述这种情况. 如果一个寄存器当前完全空闲, 但未来在位置 40 会与某个 inactive interval 冲突, 那么这个寄存器对当前 interval 可以自由使用到位置 40. 如果当前 interval 会一直活到 80, allocator 可以在 40 附近 split 它, 让前半段使用这个寄存器, 再处理后半段.

至此, Linear Scan 已经开始从 "给整个 interval 一次性分配一个寄存器" 发展成对 interval fragments 做决策.

## 4 Live range splitting

早期 Linear Scan 的主要弱点之一, 就是一个长 interval 在寄存器不足时很容易被整体 spill. 假设:

```text
v:
|--------------------------------------|

          high pressure
              |
              v
         |----------|
```

如果只有中间一小段发生寄存器冲突, 将整个 $v$ 从 definition 到最后 use 都 spill 到 memory 会浪费大量本来可以驻留寄存器的区域.

Splitting 可以把它改成:

```text
v1:
|-------------|

v2:
              |----------|

v3:
                         |-------------|
```

然后分别决定 $v_1$, $v_2$, $v_3$ 的 location. 例如两边驻留寄存器, 中间高压力区域进入 stack:

```text
register        stack          register
|-------------|----------|----------------|
```

这样真正执行的 spill/fill 只发生在分界附近.

Linear Scan 中的关键问题变成 split point 放在哪里. 如果当前 physical register 只能安全使用到位置 $p$, 可以把 interval 在 $p$ 附近切开. 如果某个 child interval 下一次 use 很晚, 也可以把它推迟到靠近 use 的位置才 reload. 更高级的算法会综合 block boundaries, loops, calls 和 use positions 选择 split point.

这一步显著缩小了简单 Linear Scan 和高质量 allocator 之间的差距. 很多时候, allocator 质量差异并不来自 "颜色怎么选", 而来自 live range 被怎样拆开以及 spill/fill 被放在哪里.

LLVM 从旧 Linear Scan 切换到 LLVM 3.0 Greedy allocator 时, 官方总结恰好提供了一个很典型的工业案例. LLVM 的旧 Linear Scan 按线性顺序访问 live ranges, 使用 active list 检查 interference. 一旦所有寄存器被 active intervals 阻塞, 它需要选择 live range spill. LLVM 当时的实现很难做完整的 global live range splitting, 因为新产生的 fragments 如果应该被放回已经扫描过的程序区域, 就需要回退 allocation 状态. LLVM 开发者认为这种 backtracking 与 Linear Scan 的整体结构很不协调.

## 5 Fixed intervals 和机器寄存器约束

到目前为止, 我们假设所有 physical registers 都只被 virtual intervals 占用. 真实机器还会有固定寄存器使用.

假设某条指令在位置 24 必须使用 `RAX`, 那么可以把这个约束看作 `RAX` 自己存在一个 fixed interval:

```text
RAX fixed:
                    |--|

v1:
          |------------------|
```

如果准备把 $v_1$ 分配到 `RAX`, 两者在位置 24 会冲突. allocator 可以选择其他 physical register, 也可以在固定使用之前 split $v_1$, 让它避开 `RAX` 被占据的区域.

函数调用也可以用类似方式理解. 一次 call 会 clobber 一组 caller-saved registers. 对跨 call 的 live interval 来说, 这些寄存器在 call 位置形成固定障碍:

```text
v:
|----------------------------|

              CALL
               |
               v

R0:           |x|
R1:           |x|
R2:           |x|
```

如果 $v$ 需要跨 call 保持, allocator 可以选择未被 call clobber 的寄存器, 也可以在 call 周围 split, spill/fill, 或根据具体成本做其他安排.

Two-address instruction, tied operand 和 pre-colored value 最终也可以转化成 interval assignment 上的约束. 因此成熟的 Linear Scan 同样需要真正理解目标 ISA, 并不因为它没有显式 interference graph 就能绕过 machine constraints.

## 6 Linear Scan 为什么快

Linear Scan 的基本优势来自它处理 interference 的方式. Graph-coloring allocator 往往需要显式或逻辑上处理全局冲突关系, 而经典 Linear Scan 只维护扫描点附近的 active intervals. 如果 intervals 已经按 start position 排好序, 每个 interval 只需要被插入和移出少数几个工作集合, physical register 的数量通常又远小于 virtual register 数量, 因而整个核心过程可以非常高效.

"Linear" 这个名字需要稍微宽松地理解. intervals 的排序可能需要 $O(n\log n)$; active set 如果用平衡结构维护也有额外成本; splitting 会产生新的 intervals; 带 lifetime holes 的实现还要管理 inactive sets 和 future intersection queries. 因此一个工业 Linear Scan allocator 的实际复杂度不能简单写成严格的 $O(n)$ 然后结束讨论. 它的优势更多来自算法只维护相对局部和有序的状态, 避免构造和反复修改庞大的全局 interference graph.

这也是它长期受到 JIT 编译器欢迎的原因. JIT 对编译延迟高度敏感, 一个能够快速产生足够好代码的 allocator 往往比追求更复杂全局优化更合适. AOT 编译器拥有更大的编译时间预算, 因而更愿意投入 live range splitting, eviction, coalescing 和更复杂的 cost model.

不过 "Linear Scan 适合 JIT, graph coloring 适合 AOT" 只能当作历史上的大体倾向. 高质量 Linear Scan 可以相当复杂, 图着色 allocator 也可以通过工程设计控制编译成本. 最终还是要看具体实现.

## 7 Linear Scan 和 Graph Coloring 到底差在哪里

经过前几部分以后, 两者现在可以做一个更准确的比较.

给定 liveness 信息, graph coloring 倾向于把它投影成 interference relation. 一旦得到图, allocator 很容易看到一个 value 整个生命周期中和谁冲突, coalescing 也可以通过图收缩来表达. 代价是大量位置信息被压缩掉了, spill placement 和 live range splitting 需要额外机制重新引入这些信息.

Linear Scan 保留的是 interval position. 它很自然地知道一个 value 何时开始, 何时结束, 哪些地方存在 holes, 下一个 use 在哪里. 这让局部 splitting 和 position-based decisions 很直观. 它的 allocation 顺序受线性扫描结构约束更强, 已经做出的早期选择可能阻碍后面的高价值 interval. 如果允许随意回头撤销这些 assignment, 算法就逐渐失去最初简单的 scan 结构.

可以用一个例子来看这种差别. 假设扫描早期遇到一个低价值的长 interval $a$, 当时有空闲寄存器, Linear Scan 很自然地把它分配给 $R_0$. 后面遇到一个位于热循环中的高价值 interval $b$, 却发现所有寄存器已经被早期 assignment 占据. allocator 此时需要 spill, split 或者驱逐旧 interval.

Graph-based 或 priority-based allocator可以先根据 spill weight 处理高价值 interval $b$, 再安排 $a$. LLVM 3.0 的新 allocator正是放弃了 Linear Scan 固定的线性访问顺序, 改用 priority queue 按 spill weight 等优先级处理 live ranges, 并使用 per-physical-register live interval unions 做 interference query. 这样 allocator 可以先处理重要的长 live ranges, 并在后面发现更合适的 assignment 时 eviction 已经分配的低权重 ranges.

## 8 应该怎样理解 Linear Scan 的地位

Linear Scan 的价值不应只用 "快但代码质量差" 来概括. 最基础的版本确实非常简单, 但 interval splitting, lifetime holes, inactive sets, fixed intervals, next-use heuristics 和 register preferences 都可以逐步加入. 一套成熟的 Linear Scan allocator 可以生成相当好的代码, 其核心优势是 live interval 的位置结构天然保存在算法里.

Graph coloring 的经典优势则在于它拥有全局 conflict topology. Chaitin-Briggs 可以在整个 interference graph 上判断 degree, simplify 和 coalescing, 不受到单一 start-position scan order 的严格限制. 但显式图本身也带来构造和维护成本, 而且 spill placement 仍然需要回到程序位置上处理.

现代工业 allocator 往往吸收两边的思想. LLVM Greedy 使用 LiveIntervals, 不建立 textbook Chaitin 式完整冲突图; 它又允许 arbitrary allocation order, eviction 和 extensive splitting, 因而脱离了经典 Linear Scan 的单向扫描限制. 后面学习 LLVM Greedy 时, 会看到 `LiveInterval`, `LiveRegMatrix`, priority queue, eviction 和 `SplitEditor` 怎样组合成这种结构.

从目前六部分的内容看, 三条路线已经可以放在同一张图里:

```text
                         Liveness
                            |
             +--------------+--------------+
             |                             |
             v                             v
     Interference Graph              Live Intervals
             |                             |
             v                             v
     Chaitin / Briggs               Linear Scan
             |                             |
     global graph view              scan-order view
             |                             |
             +--------------+--------------+
                            |
                            v
                Industrial hybrid designs
                  e.g. LLVM Greedy
```

下一部分进入 SSA 与寄存器分配. 前面我们暂时把 live ranges 当成一般结构, SSA 会给它们增加很强的 dominance 性质. 这会影响 interference graph 的结构, phi 的 liveness 语义, coalescing, parallel copy 以及 SSA destruction, 也会解释为什么一些在一般 interference graph 上很困难的问题, 到 SSA 形式下会表现出更特殊的性质.
