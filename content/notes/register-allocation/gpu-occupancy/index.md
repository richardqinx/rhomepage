---
title: "第十部分: GPU 寄存器分配与 Occupancy"
slug: "gpu-occupancy"
lang: zh-Hans
series: register-allocation
weight: 110
created: 2026-08-18
updated: 2026-09-09
license: CC-BY-SA-4.0
---

CPU 和 GPU 都需要把数量近乎无限的 virtual registers 映射到有限的 physical registers, 因而 liveness, interference, splitting, spilling 和 coalescing 这些基本问题并没有因为执行设备变成 GPU 而消失. 真正发生变化的是寄存器资源参与性能的方式. 由于 GCC 在 GPU 上已经落后很多了, 所以这一部分我们主要以 LLVM 来分析.

CPU allocator 主要考虑单个 instruction stream 中的寄存器复用成本. GPU 同时维持大量 threads, 并把它们组织成 warp 或 wavefront 执行. 每个 thread 使用的寄存器最终都要占用 SM 或 CU 上有限的 register file. 当单个 kernel 的寄存器需求增加时, 一个执行单元能够同时驻留的 warps 或 waves 可能减少, 进而降低 GPU 隐藏 memory latency 和 execution latency 的能力. NVIDIA 的 CUDA 执行模型明确把 registers 和 shared memory 都视为决定 SM resident blocks 和 warps 数量的资源. AMD GPU 上的 SGPR 和 VGPR 同样从有限 register pools 中分配给正在执行的 wavefronts.

所以 GPU register allocator 面对一个 CPU 上弱得多的反馈关系:

```text
register allocation
        |
        v
register usage per thread / wave
        |
        v
resident warps / waves
        |
        v
occupancy
        |
        v
latency hiding and throughput
```

这使 GPU RA 的优化目标发生了变化. 减少一次 spill 当然仍然有价值, 但如果为了避免 spill 而让整个 kernel 跨过一个 register-allocation threshold, 使 resident waves 从 4 个下降到 3 个, 最终性能可能反而下降. 反过来, 强行减少寄存器数量也可能引入大量 memory traffic 或额外 instructions. GPU RA 因此长期处在 register pressure, spill cost, instruction-level parallelism 和 occupancy 之间的权衡中. NVIDIA 的 `--maxrregcount` 文档直接把 per-thread register usage 和 thread parallelism 描述为一项 trade-off, AMD 的 GCN scheduler 也专门根据 register pressure 是否会降低 wave occupancy 调整调度策略.

## 1 从 Thread Register 到整个 Register File

先把 GPU 的执行层次和寄存器资源对应起来. CUDA 中的 threads 被组织成 thread blocks, block 进入 SM 后再被划分成 warps. 一个 warp 包含 32 个 threads, warp scheduler 从 ready warps 中选择下一条 instruction 发射. 每个 SM 拥有一组 32-bit registers, 这些寄存器资源会在驻留于该 SM 的 warps 之间分配.

从程序员视角看, register 是 thread-private 的:

```text
thread 0: r0 r1 r2 ...
thread 1: r0 r1 r2 ...
thread 2: r0 r1 r2 ...
...
```

但物理资源来自同一个有限 register file. 如果一个 warp 中每个 lane 都需要一个 32-bit value, 那么硬件需要为整个 warp 保存这一组 lane values. 所以 "kernel 使用 64 个 registers" 这类指标通常不是说整个 kernel 只占 64 个 hardware words, 而是在描述每个 thread 或每个 wave 的 architectural register requirement, 最终硬件会把它乘到同时驻留的执行上下文上. NVIDIA 也因此把 register usage 作为 per-thread kernel resource 报告, 并用它限制同时可以驻留的 threads 和 blocks.

AMD 的 register organization 更能体现 GPU RA 与普通 CPU RA 的差别. AMD GCN/CDNA/RDNA 系列存在 SGPR 和 VGPR 两类主要 general-purpose register resources. VGPR 保存每个 lane 可以不同的 vector value, SGPR 保存编译器能够证明在整个 wave 中一致的 scalar value. 因而一个 wave-uniform 的值如果进入 SGPR, 整个 wave 只需要保存一份; 一个 divergent value 进入 VGPR 后, 每个 lane 拥有自己的 component.

例如:

```text
wave:

lane 0:   x = 3
lane 1:   x = 7
lane 2:   x = 5
lane 3:   x = 9
...
```

这种 `x` 是 divergent value, 需要 vector storage. 另一个值:

```text
wave:

lane 0:   n = 128
lane 1:   n = 128
lane 2:   n = 128
lane 3:   n = 128
...
```

如果 compiler 能证明 `n` 在整个 wave 中 uniform, AMDGPU 可以让它走 scalar register bank. Uniformity analysis 因而和 register pressure 直接连接. 一个 value 从 VGPR 需求转化成 SGPR 需求时, 减少的不只是一个普通颜色冲突, 还改变了它消耗哪一类硬件资源. LLVM 的 AMDGPU register-bank logic 也明确区分 SGPR, VGPR 和 AGPR, 并要求只有已知 uniform 的 value 才能合法从 VGPR 语义转入 SGPR.

部分 AMD GPU 还拥有 AGPR, 即 accumulator register resource, 用于 matrix accumulation 等操作. LLVM AMDGPU 的 pressure model 区分 SGPR, VGPR, AGPR 和 unified/mixed vector register categories, 并额外追踪 tuple pressure. 这意味着一个 AMDGPU kernel 的 register pressure 从一开始就不是一个单独整数.

## 2 Register Pressure 为什么会改变 Occupancy

Occupancy 表示一个 execution unit 上实际能够同时驻留多少 waves/warps 相对于硬件允许上限的程度. 限制 occupancy 的资源不只有 registers, 还包括 shared memory 或 LDS, thread-block/workgroup size, architectural wave slots 等. 可以把这种关系抽象写成 $W_{\text{resident}}=\min(W_{\text{arch}},W_{\text{reg}},W_{\text{smem}},W_{\text{block}},\ldots)$.

其中 register-limited occupancy 可以粗略理解成 register file 容量除以每个 resident execution context 需要的 register storage. 假设某种抽象 GPU 每个 execution unit 有 $R$ 个可用 register units, 每个 wave 分配 $r$ 个 units, 那么单从寄存器容量得到的上限近似为 $\lfloor R/r\rfloor$. 真实硬件还会按照一定 granularity 分配 registers, 因而 occupancy 往往表现成阶梯函数, 而不是随着 register count 连续变化. LLVM AMDGPU 中专门存在 VGPR/SGPR allocation granule 以及根据 register 数量计算 waves-per-EU 的 target functions.

用一个纯粹的抽象例子说明这个现象. 假设 register file 容量为 256 个 units, 分配粒度为 16. 如果一个 wave 需要 64 个 units, 最多可以容纳 4 个 waves. 如果最大 pressure 从 64 增长到 65, 硬件实际需要向上取整到 80, register-limited occupancy 就可能直接从 4 个 waves 下降到 3 个:

```text
logical pressure        allocated amount       resident waves

      64                      64                     4
      65                      80                     3
      79                      80                     3
      80                      80                     3
```

于是一个只增加了 1 个 live register 的代码变换, 有可能产生远大于 "多占一个寄存器" 的资源后果. 这类位置常被称为 occupancy cliff 或 occupancy threshold. Register allocator 和 scheduler真正关心的经常不是把 pressure 从 53 降到 52, 而是能否跨过一个会增加 resident-wave count 的 threshold.

AMD 的公开架构资料能够直接看到这种效果. MI100 的 VGPR 和 SGPR 会动态分配给 wavefronts, VGPR 使用量直接限制并发 wavefront 数. AMD 给出的一个具体例子中, wave 使用 119 个 VGPR 时只能达到 2 个 active wavefronts.

但 occupancy 不能单独当成 performance metric. 更多 resident waves 可以提供更多独立工作, 用一个 wave 的执行去覆盖另一个 wave 的 memory 或 pipeline latency. 当 kernel 本来已经有足够 latency hiding, 继续提高 occupancy 未必产生明显收益. 如果为了获得更高 occupancy 而减少 registers, compiler 还可能被迫增加 reload, rematerialization 或 dependency chains. NVIDIA 的 launch-bounds 文档甚至允许 compiler 在 occupancy requirement 已经满足后增加 register usage, 用更多 registers 换取更少 instructions 或更好的 single-thread latency hiding.

所以 GPU allocator的目标不能写成简单的 "最小化 register count". 更接近实际问题的表达是: 在不引入过高 spill 和 instruction cost 的前提下, 控制 register usage 落在合适的 occupancy range 内.

## 3 Liveness, Scheduling 与 Divergence

GPU register pressure 仍然从 liveness 产生. 如果某个程序位置上有 80 个 VGPR-width values 同时 live, allocator 无法通过重新给这些 values 换 register number 来把 pressure 变成 40. 真正能够改变 maximum pressure 的办法仍然是缩短 live range, splitting, rematerialization, spilling, 改变 instruction schedule, 或者让某些 values 转移到其他 register bank.

GPU instruction scheduling 因此和 RA 结合得非常紧. 假设有几个高 latency loads:

```text
load a
load b
load c

compute a
compute b
compute c
```

把 loads 提前可以制造更多 memory-level parallelism, 让 GPU 同时等待多个 memory operations. 代价是 `a`, `b`, `c` 从 load 完成到真正消费之间都必须保持 live:

```text
a: |----------------|
b:    |-------------|
c:       |----------|
```

如果改成:

```text
load a
compute a

load b
compute b

load c
compute c
```

live ranges 会缩短, register pressure 下降, 但 memory-level parallelism 和 instruction-level parallelism 也可能下降.

AMDGPU 的 machine scheduler 直接把这个矛盾放进 scheduling policy. `GCNSchedStrategy` 会对一个 kernel进行多阶段 scheduling, 原因就是某些 scheduling regions 的 register pressure 会决定整个 kernel 的 occupancy. 当某个 region 接近会降低 occupancy 的 pressure threshold 时, scheduler 更倾向于压低 SGPR/VGPR pressure; 在不会影响 occupancy 的区域, 约束可以放松, 让 scheduler继续追求 ILP.

这说明 GPU 上 "schedule first, register allocate later" 并不意味着两者彼此独立. Scheduler 虽然在 RA 前工作, 却必须预测 RA 后可能达到的 register usage. RA 随后又在 scheduler塑造出的 live ranges 上工作.

Divergence 则进一步改变 register bank pressure. 一个基于 lane ID 的 value 通常会沿不同 lanes 产生不同结果, 后续计算也继续保持 divergent. 在 AMDGPU 上, 这种数据通常进入 VGPR. Workgroup ID, 某些 kernel arguments, constant addresses 或其他 wave-uniform data 则有机会进入 SGPR. AMD 的编程和 profiling 文档明确把 VGPR 描述为保存 wave 内不同 work-items 的数据, SGPR 保存编译期已知 wave-uniform 的数据.

因此下面两种 IR 虽然从普通 SSA liveness 看都只有一个 value:

```text
v = thread_id.x + 1
```

和:

```text
v = workgroup_id.x + 1
```

对 AMD GPU 的 register allocation 可能完全不同. 前者随 lane 变化, 通常形成 vector value. 后者对一个 wave 中的 lanes 可以保持 uniform, 有机会使用 scalar resources. Uniformity analysis 做错或过于保守时, 本来只需要一个 scalar value 的数据可能长期占据 VGPR, 增加 vector pressure.

SGPR 也不是无限资源. LLVM AMDGPU 的 occupancy model能够分别计算 SGPR 和 VGPR 对 occupancy 的影响, 某些架构代际上 SGPR allocation本身也会形成 occupancy limit. `GCNRegPressure` 因此比较 register-pressure states 时先比较 occupancy, 再比较 spilling, tuple pressure 和 raw register pressure, 而不是简单把所有 registers 加在一起.

控制流 divergence 还会让 live range 形状更加复杂. 一个 value 可能只在部分 active lanes 上真正参与计算, 但 physical vector register仍然必须为整个 wave 保留对应 storage. AMD 的 `EXEC` mask 决定哪些 lanes 在当前 vector instruction 中 active, register allocation却不能把同一 VGPR 的不同 lanes随意分给无关 virtual values, 除非 backend 有专门的 lane/subregister packing 机制. 所以前面 CPU 上 "两个值在不同 CFG paths 上互斥, 可以共享寄存器" 的思想到了 SIMT 环境还需要同时理解 control-flow mask 和 register-lane semantics.

## 4 LLVM AMDGPU 如何做 Register Allocation

AMDGPU 的 physical register allocation发生在 LLVM machine-code backend 中. 上层可以经过 Clang, OpenMP/HIP lowering, MLIR GPU/ROCDL 等多种路径, 但进入 `lib/Target/AMDGPU` 后, allocator处理的已经是目标相关 Machine IR, 最终生成 AMD GPU ISA.

AMDGPU 没有重新实现一套完全独立的 allocator. 它复用了 LLVM target-independent Greedy RA infrastructure, 同时把 GPU register banks 拆成多个 allocation stages. 优化编译中, SGPR 和 VGPR 分别运行 Greedy allocator, whole-wave/whole-quad mode 所需 registers 也有独立 allocation stage. AGPR 相关 values 在 RA 前经过专门 preparation, allocation 完成后还有 AGPR copy rewrite 等 target passes.

主干可以简化成:

```text
Machine IR
    |
    v
AMDGPU pre-RA optimizations
and occupancy-aware scheduling
    |
    v
prepare AGPR allocation
    |
    v
SGPR register allocation
    |
    v
lower SGPR spills
    |
    v
WWM / special register allocation
    |
    v
VGPR register allocation
    |
    v
rewrite virtual registers
    |
    v
post-RA AMDGPU passes
```

SGPR 和 VGPR 分开 allocation 很符合 AMD 硬件的资源结构. Scalar values 和 vector values 不只是两个不同 register classes, 它们拥有不同 storage semantics, 不同 spill possibilities, 对 occupancy 的作用也不同. Backend 因而可以在 SGPR allocation结束后先 lower 一部分 scalar spills, 再继续处理 VGPR allocation.

Greedy RA 本身仍然使用第九部分讨论过的 `LiveInterval`, `LiveRegMatrix`, eviction 和 splitting. GPU-specific behavior主要通过 register classes, allocation order, target-specific spiller, scheduler 和 pressure model进入这套 framework. 也就是说, AMDGPU 并没有把 LLVM Greedy 换成一个名字叫 "GPU allocator" 的完全不同算法, 它改变的是 Greedy 所面对的 physical-resource topology 和 cost structure.

`GCNRegPressure` 很适合观察这种 target-specific cost model. 它分别维护 SGPR, VGPR, AGPR 等 register kinds, 同时维护 tuple pressure. 比较两个 pressure states 时, 优先考虑哪个状态能够获得更高 occupancy, 随后才比较 spill risk, tuple pressure 和 raw register count.

这里可以看到 CPU 和 GPU RA 的一个结构差异. CPU 上 allocator通常希望某个热点 region 使用较少 registers, 但一个函数最大 pressure 增加 1 不一定对全函数产生离散的执行资源变化. GPU 上一个 region 的 maximum VGPR pressure 可能决定整个 kernel 的 allocated register count, 最终改变所有 waves 的 residency. 所以 AMDGPU scheduler 和 allocator需要把局部 live-range decision 和 kernel-wide resource consequence联系起来.

AGPR 又增加了一层 register-bank problem. 某些 matrix instructions 可以使用 accumulator registers, backend需要判断一些 values 保持在 VGPR 还是转换到 AGPR 更合适, 并考虑为这种转换插入 copies. AMDGPU 的 scheduling 和 RA machinery因此还会处理 VGPR/AGPR register-bank choice 和相关 copy cost.

## 5 AMDGPU Spill 为什么比普通 Stack Spill 更复杂

CPU spilling 常被简化成 "store 到 stack slot, use 前 load 回来". AMDGPU 同样有 scratch/private memory 作为寄存器溢出的 backing storage, 但不同 register banks 的 spill path 并不相同. AMDGPU backend为 scratch access准备相应的 private-segment state, VGPR spill 可以通过 scratch memory保存每个 lane 的 private value.

VGPR spill 的直观形态可以画成:

```text
VGPR live range

|-------------------------------|

          high pressure
               |
               v

      store lane value -> scratch
              ...
      load lane value <- scratch
```

Scratch 对每个 lane提供 private address semantics, 所以一个 spilled VGPR实际上对应 wave 中各 lanes 各自的 spilled value. Memory backing 和 register file 的组织方式不同, backend需要根据 wave size 和 scratch addressing convention产生正确地址.

SGPR spill 更有 GPU 特征. 因为 SGPR 中保存的是整个 wave 共用的一份 scalar value, 直接把它按每个 lane复制到 scratch 会浪费 memory bandwidth. LLVM AMDGPU 可以优先把 SGPR spill 到 VGPR 的某个 lane, 使用 lane read/write operations 保存和恢复 scalar value. 如果最终必须进入 memory, backend可以先把 SGPR value写入 temporary VGPR lane, 再把 VGPR 保存到 scratch; restore 时反向执行.

于是 SGPR spilling 可能形成这样的资源转换:

```text
SGPR pressure
    |
    | spill scalar value
    v
VGPR lane
```

如果 VGPR 也已经紧张, 才进一步变成:

```text
SGPR
  |
  v
temporary VGPR lane
  |
  v
scratch memory
```

这种设计减少 memory spill 的机会, 但它把 scalar-register pressure转移成 vector-register pressure. 假设 kernel 正好位于 VGPR occupancy threshold 附近, 多占一个 VGPR 可能比一次普通 SGPR spill 更昂贵. 所以 GPU spilling 的成本不能只按照 "load/store 次数" 建模, 还需要考虑 spill medium 本身占用了哪一类 register resource.

AMDGPU 还存在 VGPR 与 AGPR 之间利用另一类 register storage 避免 memory spill 的机会. Backend 中有为 VGPR-to-AGPR 或 AGPR-to-VGPR spill保留寄存器的机制. 这使 register-bank pressure能够在一定条件下互相转移.

Scratch 的使用本身也可能要求 kernel准备额外的 scratch-related SGPR state. AMDGPU backend 会根据 kernel 是否需要 private/scratch access建立相应的 scratch buffer 或 flat-scratch state. 因而 spilling 还可能反过来增加少量固定 register resource 和 prologue setup.

这就是 GPU allocator里一个经常出现的反馈环:

```text
high VGPR pressure
      |
      v
spill
      |
      v
scratch instructions
      |
      v
more address / temporary state
      |
      v
new register pressure
```

好的 spiller需要避免让 spill rewrite 本身制造新的大规模 pressure problem. Rematerialization, splitting 和 spill-to-other-register-bank 都是在尝试切断这种反馈.

## 6 NVIDIA: LLVM 到 PTX, 再到真正的 Physical Register Allocation

NVIDIA 的 LLVM 路径与 AMDGPU 有一个架构上的根本差异. LLVM `NVPTX` backend 的目标是 PTX, 而 PTX 本身是 virtual ISA. LLVM NVPTX 把 LLVM IR 转换成 PTX assembly, PTX 中仍然可以声明大量 virtual registers. NVIDIA 的 PTX ISA甚至专门提供参数化 `.reg` 声明, 方便 compiler生成大量 `%r0`, `%r1`, `%r2` 这样的 virtual register names.

例如 PTX 可以出现:

```text
.reg .b32 %r<100>;
```

这里声明的是 100 个 PTX virtual registers, 不是说 GPU hardware 已经为该 thread分配了 100 个 physical registers. PTX 之后还要经过 NVIDIA backend compiler.

LLVM/NVIDIA pipeline 可以表示成:

```text
LLVM IR
    |
    v
LLVM NVPTX backend
    |
    v
PTX virtual ISA
    |
    +----------------------+
    |                      |
    v                      v
  ptxas              CUDA Driver JIT
    |                      |
    +----------+-----------+
               |
               v
            cubin
               |
               v
       native GPU machine code
```

CUDA Driver 可以把 PTX JIT compile 成 native GPU machine code, `nvcc` 文档把 `ptxas` 定义为 PTX optimizing assembler. `ptxas --resource-usage` 的结果会报告最终使用多少 registers, 以及多少 spill loads/stores因为 variables 无法放进 physical registers 而产生. 因而 NVIDIA 路径中的最终 physical register assignment发生在 PTX optimizing backend这一侧, 不是 LLVM NVPTX 在生成 PTX 时完成.

对 AMDGPU, LLVM Machine IR 中可以观察 Greedy allocator如何把 virtual VGPR/SGPR 映射成最终 architectural registers. 对 NVIDIA, LLVM NVPTX 输出仍然处于 virtual-register层, 最终 SASS register allocation由 NVIDIA backend完成. 修改 LLVM target-independent Greedy allocator不会直接替换 NVIDIA SASS allocator.

NVIDIA 仍然把 register pressure控制接口暴露在 PTX 和 CUDA compilation model 中. PTX 的 `.maxnreg` 指令可以限制 kernel 每个 thread最多分配多少 registers, `.minnctapersm` 可以向 backend表达希望每个 SM 至少容纳多少 CTAs. 这些 directives 会让 optimizing backend在 per-thread register count 和 SM utilization之间做取舍.

CUDA 层还有 `--maxrregcount` 和 `__launch_bounds__`. `--maxrregcount=N` 设置 GPU function 的 register upper bound. `__launch_bounds__(maxThreadsPerBlock,minBlocksPerMultiprocessor)` 则让 compiler根据希望同时驻留的 blocks数量推导 register budget. 如果原始 allocation 超过这个 budget, compiler会降低 register usage, 代价通常表现为更多 local-memory traffic 或更多 instructions.

这提供了一个很直接的 RA experiment. 对同一个 kernel 编译多个版本:

```text
max registers/thread:

128
96
80
64
48
```

然后观察:

```text
register count
spill stores
spill loads
local memory usage
occupancy
kernel execution time
```

结果往往不会呈现 "register count 越低越快" 的单调关系. 在某个点之前, 减少 registers可能提高 occupancy而没有严重 spills; 继续压缩后, spill traffic开始主导性能. CUDA 文档也把 `maxrregcount` 明确描述为 individual-thread performance 和 thread parallelism 之间的 trade-off.

NVIDIA register spill进入 local memory. CUDA 中的 local memory 是 thread-local address space, 但它的物理 backing 位于 device memory. Compiler在寄存器不足时可以把 value spill 到 local memory, 所以这种 spill拥有远高于 register access 的 latency, 同时经过 GPU memory hierarchy.

PTX 还有 `.pred` 等不同 register types以及各种 special registers. 从 allocator角度看, 它们再次说明 GPU machine state 并不只是一个统一的整数 register file. 最终 NVIDIA backend还需要处理 predicate state, general registers, special architectural state以及不同 machine instructions 的 operand requirements. PTX virtual ISA把这些细节留给后端 compiler继续降低.

## 7 CPU RA 与 GPU RA 的目标函数

经过 AMDGPU 和 NVIDIA 两种实现以后, 可以把 GPU register allocation 和前面的 CPU register allocation放在同一个框架下比较.

|问题|CPU|GPU|
|---|---|---|
|Register pressure 的主要后果|spill, copy, instruction constraints|spill之外还可能降低 occupancy|
|一个 register assignment 的影响范围|主要影响当前 instruction stream|per-thread/per-wave usage 会乘到大量 resident execution contexts|
|Spill backing|通常是 stack memory|private/local/scratch memory, 某些 GPU 还可利用其他 register bank|
|Scheduler 与 RA|ILP, latency 和 pressure 权衡|ILP, latency, pressure 和 occupancy threshold 权衡|
|Register classes|GPR, SIMD, special regs 等|scalar/vector/accumulator/predicate 等多类资源|
|Control flow|CFG liveness|CFG liveness再叠加 SIMT divergence 和 execution mask|
|评价指标|runtime, spills, copies, code size|runtime, spills, register count, occupancy, wave residency, code size|

CPU allocator中一个常见目标是尽量避免 hot-path spill, 同时减少 copies 和 callee-saved cost. GPU allocator仍然追求这些目标, 但 register count本身开始成为 kernel-level resource metric. 一次看起来很便宜的 live-range extension可能让 maximum pressure跨过 occupancy threshold, 影响整个 kernel 的 resident-wave capacity.

反过来, GPU allocator也不能把 occupancy最大化作为唯一目标. 一个 compute-heavy kernel如果拥有大量独立 arithmetic instructions, 更多 per-thread registers可以保存更多 intermediate values, 增加 ILP并避免 scratch traffic. 一个 memory-latency-bound kernel可能更愿意牺牲一些 single-thread efficiency, 换取更多 resident waves. AMD 的 occupancy-aware scheduler和 NVIDIA 的 launch-bounds机制都反映了这种取舍.

所以评价 GPU register allocator时至少要把 register count和程序性能一起测量. 单独报告 "VGPR 从 72 降到 64" 这句话就没有包含足够信息. 如果 72 和 64 位于同一个 occupancy bucket, 这次 reduction可能没有任何 residency收益; 如果 64 刚好跨过一个 threshold, 效果可能很大. 同样, occupancy 从 50% 提高到 75% 也不能自动说明优化成功, 因为实现可能用大量 scratch spill换来了这个数字.

GPU RA 的很多高级优化最终都围绕这种非线性成本展开. Scheduler可以重新排列 instructions 缩短 pressure peak, allocator可以围绕 high-pressure region splitting, rematerialization可以用 computation换 register residency, uniformity analysis可以把 VGPR pressure转移到 SGPR, register-bank choice可以在 VGPR 和 AGPR 之间重新分布资源. 有些研究甚至会有意识地接受少量 spill, 只为了把 maximum register count压过一个 occupancy threshold.

到这里, 前十部分已经把 register allocation 从最简单的 virtual-to-physical mapping一路推进到了 CPU 和 GPU 的工业实现. 下一部分可以在这些基础上讨论更高层的协同优化问题: register-pressure-aware scheduling, profile-guided allocation, loop-aware splitting, rematerialization, instruction selection与 RA 的相互作用, occupancy-aware GPU allocation, allocator benchmark方法.
