# 内置 landscape-kit（lkit）

Debian 镜像**默认内置** [landscape-kit](https://github.com/landscape-router/landscape-kit)（`lkit`）及它管理的 Landscape 布局 —— 无需在系统装好后再手动安装 / 迁移，首次开机起部署就归 lkit 接管；`lkit` 全局命令对所有用户可用（`/usr/local/bin/lkit`，位于标准 `PATH`），SSH 登录的欢迎信息也会检测到 lkit 并给出常用命令引导。需要 legacy 布局（`/root/landscape-webserver` 由写死的 systemd unit 直接启动）时设置 `INCLUDE_LKIT=false`；非 Debian 构建始终使用 legacy 布局并打印提示。

```bash
# 本地构建（Debian）：默认已内置 lkit
make build

# 指定 landscape-kit 版本
LKIT_VERSION=v0.5.0 make build

# 改用 legacy 布局
INCLUDE_LKIT=false make build

# GitHub Actions：Custom Build 工作流的 include_lkit 默认开启
```

## 相关变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `INCLUDE_LKIT` | `true` | 构建期内置 landscape-kit：`true` / `false`，仅 Debian（其余基座自动回退 legacy 布局并提示） |
| `LKIT_REPO` | `https://github.com/landscape-router/landscape-kit` | landscape-kit 发布仓库 |
| `LKIT_VERSION` | `latest` | landscape-kit 版本，`latest` 会解析成具体 tag 再下载缓存 |

镜像产物名会带上 `-lkit` 后缀（如 `landscape-mini-x86-debian-lkit.img`），`build-metadata.txt` 记录 `include_lkit` 与 `lkit_version_resolved`。

## 内置布局

构建产出的 rootfs 与 `lkit install` 提交完成后的磁盘布局一致：

- `/usr/local/bin/lkit` 与 `/usr/local/lib/lkit/lkit.service`（daemon unit 原件）
- `/root/.lkit/landscape/releases/<版本>/`（webserver + 静态资源）、`current` 软链、`data/`、`service/`
- `/root/.lkit/state/install-state.json`（已提交的安装状态，记录 stripped 后二进制的 sha256）
- `/etc/systemd/system/{landscape-router,lkit}.service` 指向上述原件，并在 `multi-user.target.wants` 中启用

unit 内容与 lkit 自身渲染的完全一致（lkit 会校验 `ExecStart` 与 `definition_sha256`），因此开机后 `lkit check` / `lkit update` 直接可用。

## 网络拓扑与凭据

- 拓扑沿用现有机制：`configs/landscape_init.toml`、Custom Build 的 LAN 输入、或 `EFFECTIVE_CONFIG_PATH`。配置会安装到 `/root/.lkit/landscape/data/landscape_init.toml`。
- Web 管理凭据（`LANDSCAPE_ADMIN_USER` / `LANDSCAPE_ADMIN_PASS`）注入 init 配置的 `[config.auth]` —— lkit 的 unit 不带 `EnvironmentFile`，这是 `lkit install` 同款做法。若你的 init 配置已自带 `[config.auth]`，构建不会覆盖。

## 首次开机行为

构建不会启动 Landscape，也不会预创建 `landscape_init.lock`。首次开机时 Landscape 读取 init 配置完成初始化并自行创建 lock（与 state 中记录的 `status: complete` / `lock_present: true` 对应）。后续版本升级、回滚、备份等操作交给 `lkit update` / `lkit switch` 等子命令。

## 布局校验测试

`make test-lkit-provision`（`tests/test-lkit-provision.sh`）用最小 fixture 验证 provision 脚本产出的布局、unit 字节内容、state 校验和与凭据注入，无需构建完整镜像；CI 在构建前也会执行该测试。
