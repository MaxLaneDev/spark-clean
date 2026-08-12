---
layout: default
title: "SparkClean：给开发者用的 Mac 清理与储存空间分析工具"
description: "看清 Xcode、Docker、node_modules、缓存和 App 残留占了多少空间，再决定要删什么。"
lang: zh-Hans
locale: zh_CN
direction: ltr
permalink: /zh-hans/
markdown_url: https://raw.githubusercontent.com/georgekhananaev/spark-clean/main/docs/zh-hans/index.md
asset_base: https://raw.githubusercontent.com/georgekhananaev/spark-clean/main/docs/zh-hans/
skip_label: 跳到主要内容
language_label: 语言
footer_label: 开发者
license_label: 许可证
issues_label: 问题反馈
releases_label: 版本发布
---

<p class="eyebrow">原生 macOS 工具，支持 macOS 14 及以上版本</p>

# Mac 空间去哪了？看清楚再清理

<p class="lead">开发工具很会占空间，却不太会自己收拾。SparkClean 会找出 Xcode、Docker、<code>node_modules</code>、缓存、重复文件和 App 残留，让你先看清每一项，再决定要不要清理。</p>

<p class="actions">
  <a class="button primary" href="https://github.com/georgekhananaev/spark-clean/releases/latest">下载最新版</a>
  <a class="button" href="https://github.com/georgekhananaev/spark-clean">在 GitHub 查看源码</a>
</p>

<img class="product-shot" src="../../screenshots/language-simplified-chinese.png" alt="SparkClean 简体中文界面，显示清理分类、风险等级和可释放的 Mac 储存空间">

## 把开发工具留下的东西收拾干净

SparkClean 把缓存清理、储存空间分析、重复文件查找和 App 卸载放进一个原生
Mac App。每个区域都能单独扫描，不用为了看一个分类，重新等一遍完整扫描。

<div class="feature-grid">
  <article class="feature-card">
    <h3>开发缓存，一处看全</h3>
    <p>集中检查 Xcode DerivedData 和模拟器、Docker 资源、node_modules、Homebrew、JetBrains、Python 环境、Rust target，以及常见包管理器的缓存。</p>
  </article>
  <article class="feature-card">
    <h3>空间花在哪，一眼看懂</h3>
    <p>“磁盘地图”和“储存空间分析”只读不删，帮你看清大文件夹、App 数据、APFS 宗卷、本地快照和储存空间变化。</p>
  </article>
  <article class="feature-card">
    <h3>重复文件和 App 残留</h3>
    <p>用 SHA-256 确认内容完全相同的文件。卸载 App 时，缓存、偏好设置、容器、日志和支持文件都可以分别检查、分别选择。</p>
  </article>
  <article class="feature-card">
    <h3>先看，后删</h3>
    <p>结果分为“安全”“需检查”和“谨慎”。路径会在清理前显示，受保护的位置会被排除，确认后的文件默认移到废纸篓。</p>
  </article>
</div>

## 文件留在你的 Mac 上

扫描、分析和清理都在本机完成。SparkClean 不需要账号，没有订阅、广告、
使用分析或遥测，也不会上传文件名、路径、扫描结果或清理记录。网络只用于
可选的 GitHub 版本检查，以及你主动开始的下载。

<div class="notice">
  <p><strong>清理后还有回头路。</strong> 在清倒废纸篓前，按 <strong>Shift+Cmd+Z</strong> 可以恢复最近一次移到废纸篓的清理。Docker 清理这类命令操作无法这样恢复，因此会在确认前单独说明。</p>
</div>

## 五种语言，随时切换

SparkClean 支持英语、简体中文、日语、德语和希伯来语。在
**设置 → 通用 → 应用语言** 中选择语言，然后按提示重新启动 App。

大多数非英文内容最初由 AI 辅助翻译。它是起点，不是定稿。如果某句话不自然、
技术含义不准确，或者根本不像 Mac App 会说的话，欢迎直接改一个词、审阅一种语言，
或添加新语言。具体方法请看
[翻译贡献指南](https://github.com/georgekhananaev/spark-clean/blob/main/docs/TRANSLATIONS.md)。

## 常见问题

### SparkClean 能清理什么？

它会查找可重新生成的缓存、日志、临时数据、旧安装包、开发产物、长期不用的 App
和 App 残留。完整范围和明确排除的安全区域都写在
[支持说明](https://github.com/georgekhananaev/spark-clean/blob/main/SUPPORTED.md)中。

### SparkClean 是开源软件吗？

完整源代码可以查看和修改。根据非商业许可证，个人、教育、学术及其他非商业用途
可以免费使用。SparkClean 属于“源代码可用”（source-available）软件，不是经过
OSI 认可的开源软件。

### 删错了能恢复吗？

默认情况下，所选文件会移到废纸篓。只要还没有清倒废纸篓，就可以恢复最近一次
清理。永久删除必须在设置中明确打开，而且仍会受到分类和路径安全规则的限制。

### 需要什么系统？

需要 macOS 14 Sonoma 或更高版本，Apple 芯片和 Intel Mac 都支持。

## 下载、文档与支持

<ul class="link-list">
  <li><a href="https://github.com/georgekhananaev/spark-clean/releases/latest">从 GitHub Releases 下载 SparkClean</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/blob/main/README.md">查看完整使用说明和截图</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/issues">报告问题或提出功能建议</a></li>
  <li><a href="https://github.com/georgekhananaev/spark-clean/blob/main/CONTRIBUTING.md">贡献代码、文档或翻译</a></li>
</ul>
