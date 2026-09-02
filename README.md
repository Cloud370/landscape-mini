# Landscape Mini

[![Latest Release](https://img.shields.io/github/v/release/Cloud370/landscape-mini)](https://github.com/Cloud370/landscape-mini/releases/latest)

[English](./docs/en/README.md) | 中文 | [贡献流程](./CONTRIBUTING.md) | [**下载最新镜像**](https://github.com/Cloud370/landscape-mini/releases/latest)

Landscape Router 的最小化 x86 镜像构建器，支持 **Debian Trixie** / **Alpine Linux**，可生成 `img` / `vmdk` / `ova`，支持 BIOS + UEFI。

上游项目：[Landscape Router](https://github.com/ThisSeanZhang/landscape)

## 从这里开始

| 你的目标 | 直接去 |
|---|---|
| 直接下载现成镜像 | [Release 页面](https://github.com/Cloud370/landscape-mini/releases/latest) |
| 自定义网络 / 密码 / 版本 / 输出格式 | [Custom Build 使用说明](./docs/zh/custom-build.md) |
| 构建内置 landscape-kit 的镜像 | [内置 lkit 说明](./docs/zh/lkit.md) |
| 在 PVE 中导入 / 安装 | [PVE 安装引导](./docs/zh/pve-install.md) |
| 本地构建 / 测试 / 调试 | [中文主文档](./docs/zh/README.md) |
| English docs | [docs/en/README.md](./docs/en/README.md) |

## 推荐路径

### 我只想装起来

1. 下载 [Release 镜像](https://github.com/Cloud370/landscape-mini/releases/latest)
2. 如果在 PVE 中使用，继续看 [PVE 安装引导](./docs/zh/pve-install.md)

### 我想改网络、密码或版本

1. 看 [Custom Build 使用说明](./docs/zh/custom-build.md)
2. 构建完成后，如果要在 PVE 中导入，继续看 [PVE 安装引导](./docs/zh/pve-install.md)

### 我想改这个仓库

1. 先看 [中文主文档](./docs/zh/README.md)
2. 再看 [贡献流程](./CONTRIBUTING.md)

## 项目概览

- 基础系统：`debian` / `alpine`
- 镜像身份：`base_system + include_docker + output_formats`
- 输出格式：`img`、`vmdk`、`ova`
- 默认上游版本：`build.env` 中的 `LANDSCAPE_VERSION`

## 默认登录

| 场景 | 用户 | 密码 |
|------|------|------|
| SSH / 系统登录 | `root` | `landscape` |
| SSH / 系统登录 | `ld` | `landscape` |
| Web UI | `root` | `root` |

> 通过 `Custom Build` 可以覆盖 Linux / Web 管理凭据。更多本地构建、测试、CI / Release、构建参数说明，见 [docs/zh/README.md](./docs/zh/README.md)。
