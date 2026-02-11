# Landscape Mini

[![Latest Release](https://img.shields.io/github/v/release/Cloud370/landscape-mini)](https://github.com/Cloud370/landscape-mini/releases/latest)

[English](README_EN.md) | 中文 | [**下载最新镜像**](https://github.com/Cloud370/landscape-mini/releases/latest)

Landscape Router 的最小化 x86 镜像构建器。支持 **Debian Trixie** 和 **Alpine Linux** 两种基础系统，生成精简磁盘镜像（最小 ~76MB 压缩），支持 BIOS + UEFI 双启动。

上游项目：[Landscape Router](https://github.com/ThisSeanZhang/landscape)

## 特性

- 双基础系统：Debian Trixie / Alpine Linux（内核 6.12+，原生 BTF/BPF 支持）
- GPT 分区，BIOS + UEFI 双引导（兼容 Proxmox/SeaBIOS）
- 激进裁剪：移除未使用的内核模块（声卡、GPU、无线等）、文档、locale
- 可选内置 Docker CE（含 compose 插件）
- CI/CD：GitHub Actions 4 变体并行构建+测试 + Release 发布
- 自动化测试：QEMU 无人值守启动 + 健康检查 + E2E 网络测试（DHCP/DNS/NAT）

## 快速开始

### 构建

```bash
# 安装构建依赖（首次）
make deps

# 构建 Debian 镜像
make build

# 构建 Alpine 镜像（更小）
make build-alpine

# 构建含 Docker 的镜像
make build-docker
make build-alpine-docker
```

### 测试

```bash
# 自动化健康检查（无需交互）
make deps-test      # 首次需安装测试依赖
make test           # Debian 健康检查
make test-alpine    # Alpine 健康检查

# E2E 网络测试（双 VM：路由器 + 客户端）
make test-e2e           # Debian E2E
make test-e2e-alpine    # Alpine E2E

# 交互式启动（串口控制台）
make test-serial
```

### 部署

#### 物理机 / U 盘

```bash
dd if=output/landscape-mini-x86.img of=/dev/sdX bs=4M status=progress
```

#### Proxmox VE (PVE)

1. 上传镜像到 PVE 服务器
2. 创建虚拟机（不添加磁盘）
3. 导入磁盘：`qm importdisk <vmid> landscape-mini-x86.img local-lvm`
4. 在 VM 硬件设置中挂载导入的磁盘
5. 设置启动顺序，启动虚拟机

#### 云服务器（dd 脚本）

使用 [reinstall](https://github.com/bin456789/reinstall) 脚本将自定义镜像写入云服务器：

```bash
bash <(curl -sL https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) \
    dd --img='https://github.com/Cloud370/landscape-mini/releases/latest/download/landscape-mini-x86.img.gz'
```

> 根分区会在首次启动时自动扩展以填满整个磁盘，无需手动操作。

## 默认凭据

| 用户 | 密码 |
|------|------|
| `root` | `landscape` |
| `ld` | `landscape` |

## 构建配置

编辑 `build.env` 或通过环境变量覆盖：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `APT_MIRROR` | 清华镜像 | Debian 软件源地址 |
| `LANDSCAPE_VERSION` | `latest` | Landscape 版本号（或指定 tag） |
| `OUTPUT_FORMAT` | `img` | 输出格式：`img`、`vmdk`、`both` |
| `COMPRESS_OUTPUT` | `yes` | 是否压缩输出镜像 |
| `IMAGE_SIZE_MB` | `1024` | 初始镜像大小（最终会自动缩小） |
| `ROOT_PASSWORD` | `landscape` | root 密码 |
| `TIMEZONE` | `Asia/Shanghai` | 时区 |

### build.sh 参数

```bash
sudo ./build.sh                          # 默认构建（Debian）
sudo ./build.sh --base alpine            # 构建 Alpine 镜像
sudo ./build.sh --with-docker            # 包含 Docker
sudo ./build.sh --version v0.12.4        # 指定版本
sudo ./build.sh --skip-to 5              # 从第 5 阶段恢复构建
```

## 构建流程

`build.sh` 采用 **编排器 + 后端** 架构，按 8 个阶段顺序执行：

- `build.sh` — 编排器：解析参数、加载配置和后端、执行阶段
- `lib/common.sh` — 共享函数（阶段 1、2、5、7、8 及工具函数）
- `lib/debian.sh` — Debian 后端（debootstrap、apt、systemd）
- `lib/alpine.sh` — Alpine 后端（apk、OpenRC、mkinitfs、gcompat）

```
1. Download     下载 Landscape 二进制文件和 Web 前端资源
2. Disk Image   创建 GPT 磁盘镜像（BIOS boot + EFI + root 三分区）
3. Bootstrap    Debian: debootstrap / Alpine: apk.static
4. Configure    安装内核、GRUB 双引导、网络工具、SSH
5. Landscape    安装 Landscape 二进制、创建 init 服务（systemd/OpenRC）
6. Docker       （可选）安装 Docker CE / apk docker
7. Cleanup      裁剪内核模块、清理缓存、缩小镜像
8. Report       输出构建结果
```

## 磁盘分区布局

```
┌──────────────┬────────────┬────────────┬──────────────────────────┐
│ BIOS boot    │ EFI System │ Root (/)   │                          │
│ 1 MiB        │ 200 MiB    │ 剩余空间    │  ← 构建后自动缩小        │
│ (无文件系统)   │ FAT32      │ ext4       │                          │
├──────────────┼────────────┼────────────┤                          │
│ GPT: EF02    │ GPT: EF00  │ GPT: 8300  │                          │
└──────────────┴────────────┴────────────┴──────────────────────────┘
```

## 自动化测试

### 健康检查

`make test` / `make test-alpine` 执行完整的无人值守测试流程：

1. 复制镜像到临时文件（保护构建产物）
2. 后台启动 QEMU（自动检测 KVM）
3. 等待 SSH 就绪（120s 超时）
4. 执行健康检查（内核、服务、网络、Web UI 等）
5. 输出结果并清理 QEMU

自动适配 systemd（Debian）和 OpenRC（Alpine）两种 init 系统。

### E2E 网络测试

`make test-e2e` / `make test-e2e-alpine` 使用双 VM 拓扑测试真实路由功能：

```
Router VM (eth0=WAN/SLIRP, eth1=LAN/mcast) ←→ Client VM (CirrOS, eth0=mcast)
```

测试项：DHCP 分配、网关连通、DNS 解析、NAT（客户端经路由器上网）。

测试日志输出到 `output/test-logs/`。

## QEMU 测试端口

| 服务 | 宿主机端口 | 说明 |
|------|-----------|------|
| SSH | 2222 | `ssh -p 2222 root@localhost` |
| Web UI | 9800 | `http://localhost:9800` |

## 项目结构

```
├── build.sh              # 构建编排器（参数解析、加载后端、执行阶段）
├── build.env             # 构建配置
├── Makefile              # 开发便捷命令
├── lib/
│   ├── common.sh         # 共享构建函数（下载、磁盘、安装、裁剪）
│   ├── debian.sh         # Debian 后端（debootstrap、apt、systemd）
│   └── alpine.sh         # Alpine 后端（apk、OpenRC、mkinitfs）
├── configs/
│   └── landscape_init.toml  # 路由器初始配置（WAN/LAN/DHCP/NAT）
├── rootfs/               # 写入镜像的配置文件
│   └── etc/
│       ├── network/interfaces
│       ├── sysctl.d/99-landscape.conf
│       ├── systemd/system/          # systemd 服务（Debian）
│       │   ├── landscape-router.service
│       │   └── expand-rootfs.service
│       └── init.d/                  # OpenRC 脚本（Alpine）
│           ├── landscape-router
│           └── expand-rootfs
├── tests/
│   ├── test-auto.sh      # 健康检查测试（支持 systemd/OpenRC）
│   └── test-e2e.sh       # E2E 网络测试（双 VM：DHCP/DNS/NAT）
└── .github/workflows/
    ├── ci.yml            # CI：4 变体并行构建+测试
    ├── release.yml       # Release：构建+测试+发布
    └── test.yml          # 独立测试（手动触发）
```

## CI/CD

- **触发条件**：推送到 main（构建相关文件变更时）或手动触发
- **构建矩阵**：4 变体完全并行（`default`、`docker`、`alpine`、`alpine-docker`）
- **每个变体**：构建 → 健康检查 → E2E 网络测试（合并为单个 job，互不等待）
- **Release**：打 `v*` 标签时自动压缩镜像并创建 GitHub Release

## 许可证

本项目是 [Landscape Router](https://github.com/ThisSeanZhang/landscape) 的社区镜像构建器。
