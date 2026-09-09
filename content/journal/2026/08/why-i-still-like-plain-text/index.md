---
title: "为什么我仍然喜欢纯文本"
slug: "why-i-still-like-plain-text"
lang: zh-Hans
created: 2026-08-08
updated: 2026-08-08
description: "纯文本让知识更容易阅读、迁移和长期保存。"
license: CC-BY-SA-4.0
---

纯文本提供了一种很可靠的自由, 内容不依赖某个特定程序才能被阅读. 编辑器会变化, 操作系统会变化, 而一份 UTF-8 文本仍然可以被 `cat`, `less`, 浏览器和打印机理解.

## 文件本身就是接口

当笔记保存在普通文件里时, 备份, 比较和搜索都可以交给成熟的小工具. 下面的命令列出 Markdown 文件, 并在其中查找一个词:

```sh
find notes -type f -name '*.md' -print
grep -R 'portable' notes
```

## 格式应当服务于内容

Markdown 对我有用, 是因为源文件依然接近自然文本. 标题, 列表和链接提供了足够的结构.

当然, 纯文本并不适合所有材料. 图像, 音频和复杂数据各有更合适的格式.
