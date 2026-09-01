# Landscape Mini

[![Latest Release](https://img.shields.io/github/v/release/Cloud370/landscape-mini)](https://github.com/Cloud370/landscape-mini/releases/latest)

[English](../en/README.md) | 中文 | [贡献流程](../../CONTRIBUTING.md) | [**下载最新镜像**](https://github.com/Cloud370/landscape-mini/releases/latest)

Landscape Router 的最小化 x86 镜像构建器。支持 **Debian Trixie** 和 **Alpine Linux** 两种基础系统，可生成精简磁盘镜像，并支持 BIOS + UEFI 双启动。

上游项目：[Landscape Router](https://github.com/ThisSeanZhang/landscape)

## 按目标阅读

| 你的目标 | 直接去 |
|---|---|
| 直接下载现成镜像 | [Release 页面](https://github.com/Cloud370/landscape-mini/releases/latest) |
| 自定义网络 / 密码 / 版本 / 输出格式 | [Custom Build 使用说明](./custom-build.md) |
| 在 PVE 中导入 / 安装 | [PVE 安装引导](./pve-install.md) |
| 本地构建 / 测试 / 调试 | 继续看本文 |
| English docs | [docs/en/README.md](../en/README.md) |

## 推荐路径

- 只想装起来：Release → [PVE 安装引导](./pve-install.md)
- 需要改网络、密码或版本：[Custom Build 使用说明](./custom-build.md) → [PVE 安装引导](./pve-install.md)
- 要改仓库代码：继续看下方“本地开发”，再看 [CONTRIBUTING.md](../../CONTRIBUTING.md)

## 特性

- 同时支持 Debian 和 Alpine 两种基础系统
- 镜像身份由显式组合定义：`base_system + include_docker + output_formats`
- 输出格式支持 `img`、`vmdk`、`ova`
- 支持 BIOS + UEFI，常见虚拟化环境都比较友好
- fork 用户也可以直接在 GitHub 上跑自定义构建
- GitHub Actions 已经接好，支持自动构建、测试和发布

## 本地开发

如果你已经确定要在本地构建、调试或验证未推送改动，再看这里。

### 本地构建

构建默认以**普通用户身份运行（rootless）**：chroot 类操作通过 Linux 用户
命名空间完成，不再需要 `sudo`、loop 设备或挂载；以 root 身份运行也依然支持。
要求：Linux（内核支持非特权用户命名空间，主流发行版默认开启）+ `make deps`
安装依赖。其中 `uidmap` 配合 Debian/Ubuntu 默认为人类用户分配的
`/etc/subuid`、`/etc/subgid` 委派范围，构建会把这批 id 映射进命名空间，
dpkg 的组属主写入（shadow、crontab 等）原生完成，Debian 基座的 chroot
保持原生速度；`proot` 是无用户命名空间（或无 subid 委派）环境的兜底，
该路径下包安装阶段会明显变慢。macOS 用户请在 Linux 虚拟机或容器中构建。

本地配置现在按以下优先级分层加载：

`build.env < build.env.<profile> < build.env.local < 显式环境变量`

推荐做法：

- `build.env`：仓库默认值，保持 tracked
- `build.env.local`：本机私有覆盖，适合密码、LAN/DHCP、自测开关
- `build.env.<profile>`：按场景切换 profile，例如 `lab`、`pve`
- 显式环境变量：临时一次性覆盖，例如 `LANDSCAPE_ADMIN_USER=bar make build`

```bash
# 安装构建依赖（首次）
make deps

# 默认组合：debian + no-docker + img
make build

# 使用 profile：build.env.lab
BUILD_ENV_PROFILE=lab make build

# 本机私有覆盖：build.env.local
make build

# 一次性显式覆盖仍然优先级最高
LANDSCAPE_ADMIN_USER=admin RUN_TEST=readiness make build

# Alpine raw image
make build BASE_SYSTEM=alpine

# Debian + Docker + img,ova
make build INCLUDE_DOCKER=true OUTPUT_FORMATS=img,ova
```

本地支持的常用自定义项包括：

- `LANDSCAPE_ADMIN_USER` / `LANDSCAPE_ADMIN_PASS`
- `LANDSCAPE_LAN_SERVER_IP` / `LANDSCAPE_LAN_RANGE_START` / `LANDSCAPE_LAN_RANGE_END` / `LANDSCAPE_LAN_NETMASK`
- `RUN_TEST`

#### 构建缓存

本地构建默认启用持久化缓存（目录 `.cache/`，可用 `CACHE_DIR` 覆盖），`make clean` / `make distclean` 不会删除它：

- Landscape 发行包（webserver 二进制、static.zip）按版本缓存，并使用上游 `SHASUM256sum.txt` 做 SHA256 校验
- Debian apt 归档包与 Alpine apk 包缓存，重复构建时跳过大部分包下载

```bash
make status       # 查看 work/output/cache 目录占用
make cache-clean  # 彻底清空构建缓存（需要重新下载）
```

`LANDSCAPE_VERSION=latest` 会在构建开始时解析为具体 tag 再进入缓存；CI（GitHub Actions）也会通过 `actions/cache` 复用下载缓存。

### 本地测试

```bash
# 自动化 readiness 检查（无需交互）
make deps-test
make test

# 数据面测试仅适用于 include_docker=false 的 raw image
make test-dataplane

# 也可以在构建后自动执行测试
RUN_TEST=readiness make build
RUN_TEST=readiness,dataplane make build

# INCLUDE_DOCKER=true 时请求 dataplane 会被明确跳过并记录 skip marker
INCLUDE_DOCKER=true RUN_TEST=readiness,dataplane make build

# 也可以直接指定任意 raw image
./tests/test-readiness.sh output/landscape-mini-x86-alpine.img
./tests/test-dataplane.sh output/landscape-mini-x86-debian.img

# 交互式启动（串口控制台）
make test-serial
```

默认情况下，`make test` / `make test-dataplane` 会自动处理本地并行运行所需的端口、日志目录，以及 dataplane 的 mcast / 临时 work 目录：

- 未显式传 `SSH_PORT` / `WEB_PORT` 时，会自动分配可用端口
- `test-dataplane` 未显式传 `MCAST_PORT` 时，也会自动分配可用 mcast 端口
- 如果默认 `output/test-logs` 或 dataplane cache 目录不可写（例如 build 产物由 root 创建），测试会自动切到 `/tmp` 下的可写临时目录
- 想固定资源时，仍可像以前一样显式传 `SSH_PORT` / `WEB_PORT` / `MCAST_PORT`

例如：

```bash
# 默认直接跑；并行开多个也会自动避让
make test
make test-dataplane

# 并行跑多个构建目录
make test OUTPUT_DIR=output/p1 WORK_DIR=work/p1 &
make test OUTPUT_DIR=output/p2 WORK_DIR=work/p2 &
wait

# 仍可手动固定端口 / mcast
make test SSH_PORT=2229 WEB_PORT=9809
make test-dataplane SSH_PORT=2230 WEB_PORT=9810 MCAST_PORT=1240
```

建议把 `test` / `test-dataplane` 当作默认入口；只有在你明确要复用固定端口或调试特定镜像时，再直接调用脚本并传参。

```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
```
仅适用于你手动固定了端口，或者在 `make test-serial` / `make test-gui` 这种固定网络配置下调试。自动分配端口的测试会在日志里打印实际分配结果。

> `make test-serial` / `make test-gui` 仍使用固定端口和固定网络参数，便于交互调试；自动分配逻辑只用于 `make test`、`make test-dataplane` 以及对应脚本。

> dataplane 调度规则仍然基于 `include_docker=false`，不是旧的 variant 名称。

> 自动分配逻辑实现位于 `tests/local-runtime.sh`。

> 如果你显式传了端口 / mcast / MAC，测试会尊重你的设置，不会自动改写。

> 如需彻底关闭自动分配，可传 `LANDSCAPE_TEST_AUTO_ALLOCATE=0`。

例如：

```bash
LANDSCAPE_TEST_AUTO_ALLOCATE=0 make test SSH_PORT=2222 WEB_PORT=9800
LANDSCAPE_TEST_AUTO_ALLOCATE=0 make test-dataplane SSH_PORT=2224 WEB_PORT=9802 MCAST_PORT=1234
```

如果关闭自动分配，请自己保证端口、日志目录和 dataplane 网络资源不冲突。

> 常见本地用法：默认直接 `make test` / `make test-dataplane`；只有需要稳定复用某组端口时再显式覆盖。

```bash
# 查看当前默认说明
make help
```

help 中的 `test SSH port=auto` / `test Web port=auto` / `dataplane mcast=auto:auto` 表示本地测试会自动分配这些资源；`serial SSH` / `serial Web` 则是 `make test-serial` / `make test-gui` 固定使用的端口。

如果你显式传了变量，help 会显示你指定的值。

```bash
make help SSH_PORT=2229 WEB_PORT=9809 MCAST_PORT=1240
```

这样更适合需要固定端口做抓包或外部联调的场景。

```bash
# dataplane 也支持固定 MAC
make test-dataplane ROUTER_WAN_MAC=52:54:00:12:34:44 ROUTER_LAN_MAC=52:54:00:12:35:44 CLIENT_MAC=52:54:00:12:36:44
```

通常不需要手动改 MAC；只有你要复现实验网络或对接特定外部工具时再传。
## 部署

### 物理机 / U 盘

```bash
dd if=output/landscape-mini-x86-debian.img of=/dev/sdX bs=4M status=progress
```

### Proxmox VE (PVE)

优先阅读：

- [PVE 安装引导](./pve-install.md)

### 云服务器（dd 脚本）

使用 [reinstall](https://github.com/bin456789/reinstall) 脚本将自定义镜像写入云服务器：

```bash
bash <(curl -sL https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) \
    dd --img='https://github.com/Cloud370/landscape-mini/releases/latest/download/landscape-mini-x86-debian.img.gz'
```

> 根分区会在首次启动时自动扩展以填满整个磁盘，无需手动操作。

## 默认凭据

| 场景 | 用户 | 密码 |
|------|------|------|
| SSH / 系统登录 | `root` | `landscape` |
| SSH / 系统登录 | `ld` | `landscape` |
| 管理网页 | `root` | `root` |

> `custom-build.yml` 支持通过 workflow inputs 或 GitHub Secrets 覆盖 Linux / Web 管理凭据。明文 inputs 适合个人临时使用；如果你更在意安全，优先使用 `CUSTOM_ROOT_PASSWORD`、`CUSTOM_API_USERNAME`、`CUSTOM_API_PASSWORD`。

## 构建配置

推荐不要直接修改 tracked 的 `build.env` 作为日常自定义入口，而是优先使用：

- `build.env.local`
- `build.env.<profile>`
- 显式环境变量
- GitHub Actions `Custom Build`

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BASE_SYSTEM` | `debian` | 基础系统：`debian` / `alpine` |
| `INCLUDE_DOCKER` | `false` | 是否包含 Docker：`true` / `false` |
| `OUTPUT_FORMATS` | `img` | 输出格式列表：`img`、`vmdk`、`ova`，逗号分隔 |
| `RUN_TEST` | _(empty)_ | 本地测试选择：空 / `none`、`readiness`、`readiness,dataplane` |
| `LANDSCAPE_ADMIN_USER` | `root` | Web 管理用户名 |
| `LANDSCAPE_ADMIN_PASS` | `root` | Web 管理密码 |
| `LANDSCAPE_LAN_SERVER_IP` | _(empty)_ | LAN 网关 / DHCP 服务 IP |
| `LANDSCAPE_LAN_RANGE_START` | _(empty)_ | LAN DHCP 起始地址 |
| `LANDSCAPE_LAN_RANGE_END` | _(empty)_ | LAN DHCP 结束地址 |
| `LANDSCAPE_LAN_NETMASK` | _(empty)_ | LAN 子网前缀长度，例如 `24` |
| `APT_MIRROR` | _(auto probe)_ | Debian 软件源显式覆盖；如果为空则从候选列表自动探测 |
| `ALPINE_MIRROR` | _(auto probe)_ | Alpine 软件源显式覆盖；如果为空则从候选列表自动探测 |
| `DOCKER_APT_MIRROR` | _(auto probe)_ | Debian Docker APT 仓库显式覆盖；如果为空则从候选列表自动探测 |
| `DOCKER_APT_GPG_URL` | _(auto probe)_ | Debian Docker APT GPG key 显式覆盖；如果为空则从候选列表自动探测 |
| `LANDSCAPE_VERSION` | `v0.24.2` | 上游 Landscape 版本号 |
| `LANDSCAPE_REPO` | `https://github.com/ThisSeanZhang/landscape` | 上游 Landscape 发布仓库 |
| `IMAGE_SIZE_MB` | `2048` | 初始镜像大小（最终会自动缩小） |
| `ROOT_PASSWORD` | `landscape` | root / ld 登录密码 |
| `TIMEZONE` | `Asia/Shanghai` | 时区 |
| `LOCALE` | `C.UTF-8` | 默认系统 locale |
| `EXTRA_LOCALES` | `en_US.UTF-8` | 额外生成的 Debian UTF-8 locale |

### 自定义构建（GitHub Actions）

仓库提供 `custom-build.yml`，面向 fork 用户提供组合式构建入口，支持：

- `base_system`：`debian` / `alpine`
- `include_docker`：`true` / `false`
- `output_formats`（统一使用 `ova` 作为 OVA 输出格式名）
- `landscape_version`
- `lan_server_ip` / `lan_range_start` / `lan_range_end` / `lan_netmask`
- `root_password`
- `api_username` / `api_password`
- `run_test`

当前优先级：**direct inputs > secrets > defaults**。

workflow 会在最开始先做入参校验，提前拦截非法 `output_formats` / `run_test` / 基本网络输入，减少跑到一半才失败的情况。

测试契约统一为：

- 空 / `none`：仅构建
- `readiness`
- `readiness,dataplane`

其中 `include_docker=true` 请求 dataplane 时会明确 skip，并在日志中说明原因。

workflow 会把以下身份信息写入 `build-metadata.txt`：

- `base_system`
- `include_docker`
- `output_formats`
- `run_test`
- `produced_files`
- `artifact_id`
- `release_channel`

网络拓扑的有效配置会随 artifact 一起携带为 `effective-landscape_init.toml`，供 `test.yml`、固定 release 发布和 tag release rebuild 校验使用。

成功的 Custom Build 现在会同时发布两类入口：

- 固定入口：`custom-build-latest`
- 历史入口：`custom-build-<artifact_id>`

其中：

- `custom-build-latest` 始终指向最近一次成功 Custom Build
- `custom-build-<artifact_id>` 固定保留本次构建，不会被后续成功构建覆盖

常用链接格式：

- Latest Release 页面：`https://github.com/<owner>/landscape-mini/releases/tag/custom-build-latest`
- Latest 下载直链：`https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/<asset>`
- 历史 Release 页面：`https://github.com/<owner>/landscape-mini/releases/tag/custom-build-<artifact_id>`
- 历史下载直链：`https://github.com/<owner>/landscape-mini/releases/download/custom-build-<artifact_id>/<asset>`

workflow summary 会直接渲染本次构建的 latest / 历史页面和各产物直链，方便复制。

Artifacts 仍然保持不可变；如果你要保留 workflow 侧的原始身份，也可以继续记录 `run_id` / `artifact_id`。

## 自动化测试

### Readiness 检查

`make test` 或 `./tests/test-readiness.sh <image.img>` 执行统一的 router readiness 契约验证：

1. 复制镜像到临时文件（保护构建产物）
2. 后台启动 QEMU（自动检测 KVM）
3. 等待 SSH、API listener、API login、layout 检测完成
4. 验证 `eth0` / `eth1` 以及核心服务进入 running
5. 当 `include_docker=true` 时额外验证 Docker 可用
6. 输出 readiness / service / diagnostics 快照并清理 QEMU

### Dataplane 测试

`make test-dataplane` 或 `./tests/test-dataplane.sh <image.img>` 使用双 VM 拓扑验证真实 client-visible dataplane：

```text
Router VM (eth0=WAN/SLIRP, eth1=LAN/mcast) ←→ Client VM (CirrOS, eth0=mcast)
```

测试项：DHCP 分配、Router API 中 lease 可见、Router ↔ Client LAN 连通。

> dataplane 调度规则基于 `include_docker=false`，而不是旧的 variant 名称。

## CI/CD

- **CI**：手动触发始终可用；自动 `push main` / `PR -> main` 只在 shell / CI 执行逻辑变化时运行
- **fork 保护**：fork 仓库里的自动事件默认只会 skip，不会真的执行自动 CI；需要时仍可手动触发
- **自动 CI 验证面**：仅验证 `debian + include_docker=false`，并只请求 raw `img`
- **Readiness / Dataplane 覆盖**：自动 CI 对 `include_docker=false` 跑 `readiness,dataplane`
- **Artifact contract**：每个 image artifact 都包含 raw `.img`、`build-metadata.txt`、`effective-landscape_init.toml`；自动 CI 不再承担 `.vmdk` / `.ova` 导出
- **Custom Build**：`custom-build.yml` 支持 fork 用户按显式组合构建，并在开头先做入参校验，再给出更明确的下载/导入引导
- **Manual Retest**：`test.yml` 支持按 `run_id` 或 `artifact_id` 复测 Debian 默认公开组合，并重新传入 SSH / API 凭据
- **Release**：推送 `v*` tag 时，`release.yml` 会在 tag 对应 commit 上重新构建 Debian 的 Docker / 非 Docker 产物，而不是 promote CI artifacts；发布公开默认面：`.img.gz` + `.ova`
- **Alpine**：不再属于默认公开 release 面，按需通过 `Custom Build` 产出

## 许可证

本项目采用 **GPL-3.0** 协议发布，并与上游 [Landscape Router](https://github.com/ThisSeanZhang/landscape) 保持一致。
