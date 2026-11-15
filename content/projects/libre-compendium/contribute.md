---
title: "Contribute"
lang: zh-Hans
slug: "contribute"
weight: 10
---

感谢您关注并愿意改进 Libre Compendium。

本项目采用传统电子邮件协作流程，不使用 GitHub 等第三方代码托管平台的 Pull Request 或 Issue 系统。无论是发现错别字、公式推导笔误，还是提交新章节、修复 LaTeX 宏包问题或提供 Git 补丁，均欢迎直接发送邮件至：

**Richard Qin <richard.qin.x@gmail.com>**

关于为什么不使用 GitHub，请阅读我翻译的文章[《GitHub 错在哪里》](https://www.gnu.org/philosophy/whats-wrong-with-github.html)。

## 一、参与方式

### 1. 轻量勘误与建议（无需使用 Git）

如果您发现排版错误、公式笔误、引用缺失或表述不清之处，可直接发送纯文本邮件，邮件标题建议包含前缀：

```text
[libre-compendium][errata] <简要说明>
```

请在正文中尽量注明以下信息，便于定位修改：

- 对应的文件路径（例如 `physics/relativity/main.tex`）或 PDF 页码与章节名；
- 原文内容及建议修改后的表述或推导。

### 2. 代码与文档补丁（Git patch）

对于多处修订、新增文档或修改 `common/` 共享基础设施，建议基于最新的 Git 仓库提交修改，并生成标准补丁后通过邮件提交（见第五节）。

## 二、许可协议与版权声明

提交或寄送任何贡献，包括纯文本勘误建议、文档源码、插图及 LaTeX 代码，即表示您确认自己有权提供该内容（属于原创作品，或已取得兼容的开源/自由许可授权），并同意按目标目录对应的项目许可协议对外分发：

### 1. 文档类内容

课程讲义、专题文章（例如 `math/`、`physics/` 下的作品）、`common/doc/` 使用手册以及 `common/skeletons/` 中的文档模板正文（不含 `latexmkrc`），采用以下双重许可：

- GNU 自由文档许可证 1.3 或更高版本（GFDL-1.3-or-later），且无不可变章节（no Invariant Sections）、无前封面文字（no Front-Cover Texts）、无后封面文字（no Back-Cover Texts），原文见 `COPYING.DOC`；
- 知识共享署名-相同方式共享 4.0 国际许可协议（CC BY-SA 4.0），原文见 `LICENSE-CC-BY-SA-4.0`。

### 2. 宏包、文档类与构建脚本

`common/tex/`、`common/build-aux/` 下的代码以及各目录的 `latexmkrc`，采用 GNU 通用公共许可证第 3 版或更高版本（GPL-3.0-or-later）授权，原文见 `COPYING`。

### 3. 第三方材料与不可修改文件

- 如引用、翻译或改编第三方文本、题目、图表或数据，必须如实标明原始来源与兼容许可协议（可使用文档条目中的 `source` / `license` 键或 `\\lcsource` 命令，写法详见 `common/doc/manual.tex`）；严禁引入版权不明或与上述自由许可不兼容的内容。
- 请勿修改 `common/license/fdl-1.3*.tex` 中的许可证原文。
- 新增文件时，请参照同目录现有文件，在文件顶部添加对应的 SPDX 与版权许可头。

## 三、编写规范与提交前自查

在生成补丁前，请先完成以下检查：

### 1. 统一使用 common 基础设施

提交新的文档项目，如新课程讲义、笔记或专题文章时，必须统一使用项目提供的 `common/` 基础设施，基于 `common/skeletons/` 中的对应骨架目录（含标准 `latexmkrc`）组织文件，并调用 `common/tex/` 提供的文档类与宏包接口，用法详见 `common/doc/manual.tex`；不应在单个文档目录内自行定义独立的文档类、样式模板或构建脚本。若确需新增通用排版环境或能力，应向 `common/` 提交补丁统一扩展，避免各文档各自为政。

### 2. 文档约定与元数据规范

文档结构、元数据字段、biblatex 引用及图表组织请遵循 `common/doc/manual.tex` 中的说明与既有项目示例。

### 3. 本地编译检查

修改完成后，请在对应文档目录运行 `latexmk` 进行本地编译，确认零报错，建议同时测试 XeLaTeX；若涉及 `common/tex/` 改动，请一并编译 `common/doc/manual.tex` 并注意 LuaLaTeX 兼容性。

### 4. 保持工作区干净

请勿将 `build/` 输出目录、`*.aux` / `*.log` / `*.bbl` 等临时构建产物或编辑器交换文件纳入提交或补丁中。

## 四、Git 提交规范

本项目采用英文提交信息，并要求附带开发者原创声明（Signed-off-by）。

### 1. 必须使用英文书写提交信息

Subject 与正文均为英文。

### 2. 必须附带 Signed-off-by 行

提交时请务必使用 `git commit -s`，请确保已正确配置 `git config user.name` 与 `git config user.email`，在提交信息末尾生成：

```text
Signed-off-by: Your Name <your.email@example.com>
```

该行表示您同意开发者原创声明（Developer Certificate of Origin）：所提交内容为您本人编写或您有权依法提交，并按本文档第二节所述许可协议向项目提供该贡献。缺少 Signed-off-by 的补丁无法直接合入。

### 3. 标题行（Subject）格式

采用 `<scope>: <concise summary>` 格式，长度控制在 50–72 字符以内，使用祈使句、首字母小写（专有名词除外），末尾不加句号。例如：

```text
common/lc-meta: suppress headers on maketitle pages
physics/relativity: fix typo in Lorentz transformation
docs: add email workflow to CONTRIBUTING
```

### 4. 按逻辑单元拆分提交

`common/` 基础设施改动、根目录文档更新与各具体学科文档修改请尽量分拆为独立提交，避免将无关改动混入同一补丁。

### 5. 正文说明与 ChangeLog 条目

对于跨文件修改、结构调整或非显然的修复，请在标题行后空一行写明改动动机与背景；并在末尾按 GNU 风格列出受影响的文件与符号/章节：

```text
* path/to/file (symbol or section): brief description of change.
```

完整示例：

```text
common/lc-meta: suppress headers on maketitle pages

Clear running headers and page numbers on both the title page and the
copyright notice page produced by \\maketitle.

* common/tex/core/lc-meta.sty (\\maketitle): Add \\thispagestyle{empty}
to the title and notice pages.

Signed-off-by: Richard Qin <richard.qin.x@gmail.com>
```

## 五、生成与发送补丁

### 1. 提交到本地分支并附带签名

```sh
git commit -s
```

### 2. 导出邮件补丁

以最近 1 个提交为例：

```sh
git format-patch -1 -o outgoing/
```

若提交了一系列补丁（多于 1 个），建议附加封面信说明整体意图：

```sh
git format-patch --cover-letter -o outgoing/ <base-commit>..HEAD
```

或只导出最近 N 个（例如最近 3 个）：

```sh
git format-patch -3 --cover-letter -o outgoing/
```

### 3. 通过 git send-email 发送

```sh
git send-email --to=richard.qin.x@gmail.com outgoing/*.patch
```

若本地尚未配置 SMTP / `git send-email`，也可直接在邮件客户端中撰写纯文本邮件，将 `*.patch` 文件作为附件发送至 `richard.qin.x@gmail.com`，请尽量保持文本/补丁格式原样，不要手动重排换行或转为富文本内联。

## 六、评审、修订与合入

- 维护者会通过电子邮件直接回复评审意见，或通知补丁已被合入。
- 若需根据评审意见修改并重发，请使用 `git commit --amend -s` 或 `git rebase` 修改提交，并在重新导出补丁时标注版本号，例如：

  ```sh
  git format-patch -1 -v2 -o outgoing/
  ```

- 补丁合入时会保留原作者信息，包括 Author 与 Signed-off-by；如有长期或实质性贡献，将在 `AUTHORS` 文件中记录。
