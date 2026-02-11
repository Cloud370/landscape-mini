# Landscape Mini

[English](README_EN.md) | 中文

Landscape Router 的最小化 x86 镜像构建器。使用 `debootstrap` 生成精简的 Debian Trixie 磁盘镜像（~150–500MB），支持 BIOS + UEFI 双启动。

上游项目：[Landscape Router](https://github.com/ThisSeanZhang/landscape)

## 特性

- 基于 Debian Trixie（内核 6.12+，原生 BTF/BPF 支持）
- GPT 分区，BIOS + UEFI 双引导（兼容 Proxmox/SeaBIOS）
- 激进裁剪：移除未使用的内核模块（声卡、GPU、无线等）、文档、locale
- 可选内置 Docker CE（含 compose 插件）
- CI/CD：GitHub Actions 自动构建 + Release 发布
- 自动化测试：QEMU 无人值守启动 + 14 项健康检查

## 快速开始

### 构建

```bash
# 安装构建依赖（首次）
make deps

# 构建标准镜像
make build

# 构建含 Docker 的镜像
make build-docker
```

### 测试

```bash
# 自动化健康检查（无需交互）
make deps-test      # 首次需安装测试依赖
make test

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
sudo ./build.sh                          # 默认构建
sudo ./build.sh --with-docker            # 包含 Docker
sudo ./build.sh --version v0.12.4        # 指定版本
sudo ./build.sh --skip-to 5              # 从第 5 阶段恢复构建
```

## 构建流程

`build.sh` 按 8 个阶段顺序执行：

```
1. Download     下载 Landscape 二进制文件和 Web 前端资源
2. Disk Image   创建 GPT 磁盘镜像（BIOS boot + EFI + root 三分区）
3. Bootstrap    debootstrap 安装 Debian 最小系统
4. Configure    安装内核、GRUB 双引导、网络工具、SSH
5. Landscape    安装 Landscape 二进制、创建 systemd 服务
6. Docker       （可选）安装 Docker CE + compose
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

`make test` 执行完整的无人值守测试流程：

1. 复制镜像到临时文件（保护构建产物）
2. 后台启动 QEMU（自动检测 KVM）
3. 等待 SSH 就绪（120s 超时）
4. 执行 14 项健康检查
5. 输出结果并清理 QEMU

检查项包括：内核版本、主机名、磁盘布局、用户、Landscape 服务、Web UI、IP 转发、sshd、systemd 状态、bpftool、Docker（自动检测）。

测试日志输出到 `output/test-logs/`。

## QEMU 测试端口

| 服务 | 宿主机端口 | 说明 |
|------|-----------|------|
| SSH | 2222 | `ssh -p 2222 root@localhost` |
| Web UI | 9800 | `http://localhost:9800` |

## 项目结构

```
├── build.sh              # 主构建脚本（8 阶段）
├── build.env             # 构建配置
├── Makefile              # 开发便捷命令
├── configs/
│   └── landscape_init.toml  # 路由器初始配置（WAN/LAN/DHCP/NAT）
├── rootfs/               # 写入镜像的配置文件
│   └── etc/
│       ├── network/interfaces
│       ├── sysctl.d/99-landscape.conf
│       └── systemd/system/landscape-router.service
├── tests/
│   └── test-auto.sh      # 自动化测试脚本
└── .github/workflows/
    └── build.yml         # CI/CD 流水线
```

## CI/CD

- **触发条件**：推送到 main（构建相关文件变更时）或手动触发
- **构建矩阵**：并行构建 `default` 和 `docker` 两个变体
- **Release**：打 `v*` 标签时自动压缩镜像、生成校验和、创建 GitHub Release

## 许可证

本项目是 [Landscape Router](https://github.com/ThisSeanZhang/landscape) 的社区镜像构建器。
