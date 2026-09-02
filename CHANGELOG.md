# Changelog / 变更日志

This file currently tracks unreleased work and recent notable changes.
本文件当前记录未发布改动与近期的重要变更。

## [Unreleased]

### Added / 新增

- Consolidate agent guidance into a single source of truth: `AGENTS.md` now carries the full guide (repo overview, build model, CI contract, key files) plus explicit hard rules, and `CLAUDE.md` is reduced to a filesystem symlink pointing at `AGENTS.md` so every agent loads the same rules; the changelog discipline is stated outright — every user-visible change must land with a bilingual `CHANGELOG.md` `[Unreleased]` entry in the same PR\
  将代理指引收敛为单一事实来源：`AGENTS.md` 承载完整指南（仓库概览、构建模型、CI 契约、关键文件）与明确的硬规则，`CLAUDE.md` 精简为文件系统层面指向 `AGENTS.md` 的软链接，使所有代理加载同一套规则；变更记录纪律写明 —— 所有用户可见改动必须在同一 PR 中附带双语的 `CHANGELOG.md` `[Unreleased]` 条目
- New `INCLUDE_LKIT` build mode (Debian only): embed landscape-kit (`lkit`) and its managed Landscape layout at build time — `/usr/local/bin/lkit`, the lkit daemon unit, and a `/root/.lkit/landscape` release tree byte-identical to a completed `lkit install` — so the router is managed by lkit from first boot with no manual install/migrate step; `LKIT_VERSION` (default `latest`, resolved to a concrete tag and cached like `LANDSCAPE_VERSION`) pins the kit release, artifacts gain a `-lkit` suffix with `include_lkit` recorded in `build-metadata.txt`, the Custom Build workflow gains an `include_lkit` input, and `make test-lkit-provision` validates the provisioned layout in CI before building\
  新增 `INCLUDE_LKIT` 构建模式（仅 Debian）：构建期内置 landscape-kit（`lkit`）及其管理的 Landscape 布局 —— `/usr/local/bin/lkit`、lkit daemon unit、与 `lkit install` 完成后逐字节一致的 `/root/.lkit/landscape` 发布树 —— 路由器从首次开机起即由 lkit 接管，无需手动安装/迁移；`LKIT_VERSION`（默认 `latest`，与 `LANDSCAPE_VERSION` 一样先解析成具体 tag 再缓存）可固定 kit 版本，产物文件名带 `-lkit` 后缀并在 `build-metadata.txt` 记录 `include_lkit`，Custom Build 工作流新增 `include_lkit` 输入，`make test-lkit-provision` 在构建前于 CI 中校验内置布局
- `make doctor` environment self-check (`scripts/check-build-env.sh`): read-only probes that report whether the current machine (or sandbox/CI container you might be in) can run the rootless build, which chroot engine each base system would pick and why, plus targeted hints — NoNewPrivs confinement, missing `uidmap`/subid delegation, Ubuntu 24.04+ AppArmor userns restriction, KVM availability\
  新增 `make doctor` 环境自检（`scripts/check-build-env.sh`）：只读探测当前机器（或你所在的沙箱/CI 容器）能否运行 rootless 构建、各基座会选用哪个 chroot 引擎及原因，并给出针对性提示 —— NoNewPrivs 受限、缺少 `uidmap`/subid 委派、Ubuntu 24.04+ 的 AppArmor 用户命名空间限制、KVM 是否可用
- Rootless builds: `./build.sh` / `make build` now run as a normal user by default. The build no longer uses loop devices, partition mounts, or persistent chroot mounts — the rootfs is assembled in a plain directory and packed into the image offline (`mke2fs -d`, mtools, `sgdisk` on image files). Chroot steps run in a user namespace that maps the builder to root plus the delegated `/etc/subuid`/`/etc/subgid` ranges (`uidmap`), so dpkg's group ownerships land natively at full chroot speed; `proot` is the fallback for hosts without user namespaces or subid delegation (slower package phases; `BUILD_CHROOT_ENGINE=auto|chroot|unshare|proot` overrides detection). Running as root still works\
  支持 rootless 构建：`./build.sh` / `make build` 默认以普通用户运行。构建不再使用 loop 设备、分区挂载或常驻 chroot 挂载 —— rootfs 在普通目录中组装并离线打包为镜像（`mke2fs -d`、mtools、直接对镜像文件执行 `sgdisk`）。chroot 步骤在用户命名空间中执行：构建者映射为 root，并额外映射 `/etc/subuid`/`/etc/subgid` 委派范围（依赖 `uidmap`），dpkg 的组属主写入原生完成、保持原生 chroot 速度；无用户命名空间或无 subid 委派的宿主机回退到 `proot`（包安装阶段较慢；可用 `BUILD_CHROOT_ENGINE` 覆盖探测结果）。以 root 运行依然支持
- Broaden host compatibility: sbin directories are added to `PATH` automatically, GRUB is installed host-side (`grub-mkstandalone` EFI binary + offline BIOS boot-code embedding), GRUB packages are no longer installed into the image, OVMF firmware is auto-detected across Debian/Fedora/Arch layouts for QEMU targets, and dependency errors include per-distro install hints\
  提升宿主机兼容性：自动把 sbin 目录加入 `PATH`，GRUB 改为宿主侧安装（`grub-mkstandalone` EFI 二进制 + 离线 BIOS 引导代码嵌入），镜像内不再安装 GRUB 包，QEMU 目标的 OVMF 固件在 Debian/Fedora/Arch 布局间自动探测，依赖缺失时给出各发行版的安装提示
- `--skip-to` resume now operates on the persistent rootfs tree in `work/` instead of re-attaching the finished image with a loop device / `--skip-to` 断点续建改为基于 `work/` 中持久化的 rootfs 目录树，不再用 loop 设备重新挂载成品镜像
- Alpine package operations now run host-side via `apk.static --root` with the persistent cache directory, and the Debian apt archive cache is synchronised with rsync instead of bind-mounted — both work identically root and rootless / Alpine 包操作改为宿主侧通过 `apk.static --root` 执行并直接使用持久化缓存目录，Debian 的 apt 归档缓存改用 rsync 同步替代 bind 挂载 —— root 与 rootless 行为完全一致
- Add a persistent local build cache (`.cache/`, override via `CACHE_DIR`) that survives `make clean`: landscape release assets are cached per resolved version and verified against upstream `SHASUM256sum.txt`, and Debian apt / Alpine apk package archives are reused across rebuilds; CI reuses the download cache via `actions/cache`, and `make cache-clean` purges it\
  新增本地持久化构建缓存（`.cache/`，可用 `CACHE_DIR` 覆盖），`make clean` 不再清空缓存：Landscape 发行包按解析后的版本缓存并用上游 `SHASUM256sum.txt` 校验，Debian apt 与 Alpine apk 包归档在重复构建时复用；CI 通过 `actions/cache` 复用下载缓存，并提供 `make cache-clean` 彻底清空
- Resolve `LANDSCAPE_VERSION=latest` to a concrete release tag at build start so downloads stay cacheable and reproducible\
  构建开始时将 `LANDSCAPE_VERSION=latest` 解析为具体 release tag，使下载可缓存、可复现
- Guard against pinning a pre-v0.24 landscape binary together with a v0.24-schema init config: the build now fails when the config still uses `static_nat_mappings_v4/v6` tables (silently dropped by old binaries, losing DHCP/SSH/WUI port mappings) and warns on other downgrade paths\
  增加旧版本固定与 v0.24 配置结构组合的防护：配置仍使用 `static_nat_mappings_v4/v6` 时直接构建失败（老二进制会静默丢弃这些表，丢失 DHCP/SSH/WUI 端口映射），其余降级路径给出警告

### Changed / 变更

- CI and Custom Build now build images without `sudo` (rootless on the runner), removing the post-build permission fixup step; the build job installs `mtools`/`gdisk`/`proot`/`uidmap` instead of `parted`, and lifts Ubuntu 24.04+'s AppArmor restriction on unprivileged user namespaces so the runner picks the native-speed namespace engine / CI 与 Custom Build 构建镜像不再使用 `sudo`（在 runner 上以 rootless 运行），并移除构建后的权限修正步骤；构建 job 的依赖改为安装 `mtools`/`gdisk`/`proot`/`uidmap`（移除 `parted`），并解除 Ubuntu 24.04+ 对非特权用户命名空间的 AppArmor 限制，使 runner 选用原生速度的命名空间引擎
- The `ld` user is now pinned to uid 1000 in all build modes; rootless-built images fix `/home/ld` ownership on first boot via the existing expand-rootfs hook (no-op for root builds)\
  所有构建模式下 `ld` 用户固定为 uid 1000；rootless 构建的镜像通过已有的 expand-rootfs 钩子在首次启动时修正 `/home/ld` 属主（root 构建为空操作）
- `make clean` / `make distclean` / `make cache-clean` no longer require sudo (plain `rm` with a sudo fallback for trees left by older root-based builds) / `make clean` / `make distclean` / `make cache-clean` 不再必须 sudo（普通 `rm`，对旧版 root 构建遗留的目录回退到 sudo）
- Bump default upstream Landscape version from `v0.18.3` to `v0.24.2`; migrate `configs/landscape_init.toml` to the new format (`version` field + `static_nat_mappings_v4`/`v6` split with `lan_target`/`l4_protocols`) and pin the `version` field automatically from the resolved landscape version — pinning upstream versions older than v0.24 now requires hand-matching the init config\
  默认上游 Landscape 版本从 `v0.18.3` 升级到 `v0.24.2`；`configs/landscape_init.toml` 迁移到新格式（`version` 字段 + `static_nat_mappings_v4`/`v6` 拆分及 `lan_target`/`l4_protocols` 字段），并由构建按解析后的版本自动写入 `version` —— 如需固定早于 v0.24 的上游版本，需要手动适配 init 配置
- Create the raw disk image with `truncate` (sparse) instead of zero-filling 2GB with `dd`, and use `pigz` for output compression when available\
  使用 `truncate`（稀疏文件）替代 `dd` 清零创建 2GB raw 镜像，并在可用时使用 `pigz` 压缩产物

### Fixed / 修复

- Fix OVA import failures on Windows hypervisors: the OVF descriptor declared a `virtio` NIC (`ResourceSubType`) and `vmx-14` virtual hardware — `virtio` is a KVM subtype VMware importers reject and `vmx-14` requires Workstation 14+ (VirtualBox rejects any `vmx-*`); the descriptor now ships `E1000` + `vmx-11` (ESXi 6.0+/Workstation 11+, driver present in both base systems) and Alpine's `osType` maps to the valid `other Linux 64-bit` id / 修复 OVA 在 Windows 虚拟化软件上导入失败：OVF 描述符里的 `virtio` 网卡子类型是 KVM 专属（VMware 导入器拒收），`vmx-14` 硬件版本要求 Workstation 14+（VirtualBox 拒收所有 `vmx-*`）；现改为 `E1000` + `vmx-11`（ESXi 6.0+/Workstation 11+，两个基座内核均自带 e1000 驱动），Alpine 的 `osType` 改用有效的 `other Linux 64-bit` 编号
- Generate the first initrd with the default `MODULES=most` and only switch `MODULES=dep` on after the kernel packages are installed: the dep-mode root-device lookup cannot resolve `/` inside chroots on overlayfs-backed roots (Docker builders), which aborted the linux-image postinst and with it the whole package phase / 首次 initrd 改用默认 `MODULES=most` 生成，内核包装完后再切换 `MODULES=dep`：dep 模式的根设备探测在 overlayfs 根的 chroot（Docker 构建容器）里无法解析 `/`，此前会让 linux-image 的 postinst 中止并拖垮整个装包阶段
- Read-only artifacts no longer break rootless cleanup and packing: `systemd-hwdb` leaves `hwdb.bin` mode 444 (the write bit is restored before truncating), and the ext4 size probe plus archive cache sync run inside the mapped namespace because `_apt`-created cache directories carry delegated ids the plain builder cannot read / 只读产物不再卡死 rootless 清理与打包：`systemd-hwdb` 会把 `hwdb.bin` 置为 444（截断前先恢复写位），ext4 容量探测与归档缓存同步改在映射命名空间内执行——`_apt` 创建的缓存目录带委派 id，普通构建用户读不了
- Retry the Debian bootstrap as a whole instead of re-running a half-configured second stage over a dirty tree, and clear stale Alpine rootfs trees before `apk --initdb` so files from a previous, larger build cannot leak into the new image / Debian 引导失败时整体重试，不再在半配置的脏树上重跑第二阶段；Alpine 在 `apk --initdb` 前清空旧 rootfs 树，避免上一次更大构建的文件残留进新镜像
- Harden resume and assembly: `--skip-to 3` no longer mounts special filesystems only for bootstrap to wipe the tree under them, the BIOS `core.img` is verified non-empty before embedding, ext4 geometry from `dumpe2fs` is checked before computing the image size, and the build-time chroot now uses `env -i` for the root chroot engine exactly like the rootless engines / 加固断点续建与镜像组装：`--skip-to 3` 不再先挂载特殊文件系统再被 bootstrap 清树，BIOS `core.img` 嵌入前校验非空，`dumpe2fs` 读取的 ext4 几何信息先校验再计算镜像尺寸，root chroot 引擎的构建期环境与 rootless 引擎一致改为 `env -i`
- Expand the first-boot group-ownership restore list (`chage`, `wall`, `write`, utmp/lastlog) and take `/home/ld`'s group from the account's primary gid instead of assuming gid == uid / 扩充首次启动的组属主恢复列表（`chage`、`wall`、`write`、utmp/lastlog），`/home/ld` 的组改用账号主组而不是假设 gid == uid
- Embed the GRUB `linux` loader into the standalone UEFI binary so UEFI boots actually load the kernel: the ESP GRUB previously tried to auto-load `linux.mod` from a `/boot/grub/x86_64-efi/` directory that no longer exists in the image, aborted with `Failed to boot both default and fallback entries`, and sat at the menu forever; `grub-mkstandalone` failures are now reported instead of silenced\
  将 GRUB 的 `linux` 加载器内嵌进独立 UEFI 二进制，修复 UEFI 启动无法加载内核的问题：此前 ESP 中的 GRUB 会尝试从镜像里已不存在的 `/boot/grub/x86_64-efi/` 目录自动加载 `linux.mod`，以 `Failed to boot both default and fallback entries` 中止并永远停留在菜单界面；`grub-mkstandalone` 的失败现在会被如实报告而不是静默忽略
- Render the ESP fstab entry with an uppercase `XXXX-XXXX` serial: `blkid` resolves vfat UUIDs case-sensitively, so the lowercase form made first-boot fsck fail critically, abort the OpenRC boot runlevel, and leave hostname/sshd/landscape-router unstarted / fstab 中 ESP 条目的序列号改为大写 `XXXX-XXXX`：`blkid` 对 vfat UUID 的解析区分大小写，小写形式会导致首次启动 fsck 关键失败、OpenRC boot runlevel 中止，hostname/sshd/landscape-router 均无法启动
- Declare `xz-utils` as a build dependency (`make deps` plus the Debian backend dependency check): the APT mirror probe silently requires the `xz` binary to parse `Packages.xz`, and on minimal hosts without it every mirror was misreported as unhealthy\
  将 `xz-utils` 声明为构建依赖（`make deps` 与 Debian 后端依赖检查）：APT 镜像源探测静默依赖 `xz` 二进制解析 `Packages.xz`，精简主机缺失时所有镜像会被误判为不可用
- Improve Custom Build result UX by rendering table-based workflow summaries, adding copy-ready latest/history direct links, and publishing both a stable `custom-build-latest` entry plus immutable per-build `custom-build-<artifact_id>` releases\
  优化 Custom Build 结果体验：将 workflow summary 改为表格展示，补充可直接复制的 latest/history 直链，并同时发布稳定入口 `custom-build-latest` 与按构建保留的不可变 `custom-build-<artifact_id>` release
- Clarify Custom Build documentation around latest vs immutable history retrieval so fork users can distinguish moving pointers from exact-build download pages more easily\
  更新 Custom Build 文档，明确区分 latest 固定入口与不可变历史入口，方便 fork 用户更直接地获取精确构建页面和下载链接
- Update the readiness helper's static NAT API path to the v0.24 `/api/v1/nat/static_mappings/v4` endpoint\
  将 readiness 辅助函数的静态 NAT API 路径更新为 v0.24 的 `/api/v1/nat/static_mappings/v4` 端点
- Stop Custom Build publishing from deleting the previous fixed release on each successful run so earlier successful results remain shareable and reproducible\
  修复 Custom Build 每次成功后都会删除上一个固定 release 的行为，使之前的成功结果可以继续分享和复现


## [0.2.9] - 2026-04-17

### Fixed / 修复

- Keep full wired NIC driver coverage during image trimming, ship PCI/NIC diagnostics tools, and install full firmware packages so Intel X520-DA2 passthrough and broader physical NIC compatibility work on both Debian and Alpine\
  在镜像裁剪阶段保留完整有线网卡驱动覆盖，预装 PCI/NIC 诊断工具，并安装完整固件包，使 Debian 与 Alpine 上的 Intel X520-DA2 直通及更广泛实体网卡兼容性恢复正常
- Prefer the first configured source candidate (official by default), retry it for a bounded failover window before switching to backups in order, and stop main CI from running readiness/dataplane tests by default on the Debian non-Docker build\
  默认优先使用首个配置源（默认即官方源），在限定故障切换窗口内持续重试，超时后再按顺序切换到备用源，并让主 CI 的 Debian 非 Docker 默认构建不再自动运行 readiness/dataplane 测试

## [0.2.8] - 2026-04-17

### Fixed / 修复

- Run Alpine `expand-rootfs` from an OpenRC `local.d` hook instead of a regular service so first-boot root partition auto-expansion happens more reliably on slower virtualized environments like PVE\
  将 Alpine 的 `expand-rootfs` 改为通过 OpenRC `local.d` 钩子运行，而不是普通服务，以提升其在 PVE 等较慢虚拟化环境下首次启动自动扩容的成功率
- Run Alpine `expand-rootfs` in the later OpenRC `default` runlevel so first-boot root partition auto-expansion happens reliably after the kernel recognizes the resized partition\
  将 Alpine 的 `expand-rootfs` 改为在更晚的 OpenRC `default` runlevel 运行，使首次启动时根分区自动扩容可在内核识别新分区大小后稳定完成
- Stop reusable GitHub workflow builds from gzip-compressing raw `.img` outputs by default, while keeping compression available as an explicit workflow input when needed\
  让可复用 GitHub workflow 构建默认不再额外 gzip 压缩 raw `.img` 产物，同时保留按需显式开启压缩的能力
- Ensure Custom Build fixed releases always publish a compressed `.img.gz` when the latest successful build only produced a raw `.img`, so fork users keep getting the expected compressed installer asset\
  确保 Custom Build 固定 release 在最新成功构建只产出 raw `.img` 时也会自动补发 `.img.gz`，让 fork 用户默认仍能拿到预期的压缩安装镜像
- Make reusable build timeout configurable so automatic CI can keep the short limit while Custom Build gets a longer build window, and stop parsing workflow metadata via shell sourcing so Custom Build artifact capture and fixed-release publishing no longer break on values containing spaces\
  让可复用构建超时支持按调用方配置，使自动 CI 保持较短限制而 Custom Build 拥有更长构建窗口，并停止通过 shell source 解析 workflow metadata，避免 Custom Build 的 artifact metadata 采集与 fixed-release 发布在字段值含空格时失败

## [0.2.7] - 2026-04-16

### Added / 新增

- Add fork-friendly `custom-build.yml` with high-value topology and credential inputs, plus secrets-preferred guidance for security-sensitive users\
  新增面向 fork 用户的 `custom-build.yml`，支持高价值网络与凭据输入，并为注重安全的用户提供 secrets 优先指引

### Changed / 变更

- Rework automatic CI into a faster validation-only surface that checks only the Debian non-Docker raw `img` path, leaving wider output/export combinations to manual or release workflows\
  将自动 CI 收缩为更快的验证面，仅校验 Debian 非 Docker 的 raw `img` 路径，把更宽的输出/导出组合留给手动或 release 工作流
- Rebuild Debian Docker / non-Docker release artifacts directly on tag pushes instead of promoting CI artifacts from main, while continuing to publish `.img.gz` + `.ova` release assets\
  改为在 tag 推送时直接重建 Debian Docker / 非 Docker 发布产物，而不是从 main 上 promote CI artifacts，同时继续发布 `.img.gz` + `.ova` release 资产
- Rework CI around a reusable single-variant build-and-validate workflow, ship effective topology config inside artifacts, and let tests consume artifact-carried config plus injected credentials\
  将 CI 重构为可复用的单变体构建验证流程，把 effective topology 配置随 artifact 一起发布，并让测试使用 artifact 自带配置与注入凭据
- Replace the legacy variant model with an explicit build identity model based on `base_system`, `include_docker`, and `output_formats`, update local build UX, rework tests to consume metadata, and fold `ova` into the normal exporter pipeline\
  用 `base_system`、`include_docker`、`output_formats` 替换旧的 variant 模型，更新本地构建体验，让测试改为消费 metadata，并将 `ova` 纳入常规导出流水线
- Rewrite CI, Custom Build, retest, release promotion, and repository docs around tuple-based build identities instead of named variants\
  将 CI、Custom Build、复测、release promotion 与仓库文档统一重写为基于 tuple 的构建身份模型，不再围绕命名 variant 运转

### Fixed / 修复

- Switch image default DNS resolver to `1.1.1.1` while keeping build-time DNS aligned with the active build environment, so CI stays resilient without breaking resumed/offline-friendly workflows\
  将镜像默认 DNS 解析器切换为 `1.1.1.1`，同时让构建阶段 DNS 跟随当前构建环境，既增强 CI 稳定性，又避免破坏恢复构建/离线友好流程
- Add multi-source probing and early-fail mirror resolution so local builds and GitHub CI can select healthy package sources automatically when explicit mirrors are not set, while preserving `--skip-to` source provenance on resumed builds and preferring representative download throughput over raw latency\
  新增多源探测与早失败镜像源解析逻辑，使本地构建与 GitHub CI 在未显式指定镜像源时可自动选择健康可用的软件源，在恢复构建时保留 `--skip-to` 的源 provenance，并优先参考代表性下载吞吐而非仅看延迟
- Let CI inherit configurable Docker mirror settings while making chroot retry steps fail fast on command errors\
  让 CI 继承可配置的 Docker 镜像源设置，并让 chroot 重试步骤在命令失败时立即终止
- Add configurable Debian Docker source settings and retry transient package/network operations during image builds to reduce CI failures from upstream mirror instability\
  为 Debian Docker 构建增加可配置的软件源设置，并对镜像构建中的易失败网络/包管理步骤增加重试，降低上游源抖动导致的 CI 失败
- Retry Debian and Alpine Docker package installation steps during image builds so transient upstream network failures are less likely to fail CI\
  在镜像构建期间为 Debian 和 Alpine 的 Docker 安装步骤增加重试，降低上游网络瞬时故障导致 CI 失败的概率
- Use `C.UTF-8` as the default image locale so Debian and Alpine shells no longer warn about missing `en_US.UTF-8` locale data on first boot\
  将镜像默认 locale 改为 `C.UTF-8`，避免 Debian 和 Alpine 首次启动时因缺少 `en_US.UTF-8` locale 数据而出现 shell 警告
- Stop hardcoding test SSH/API credentials so custom builds and retests can validate non-default passwords consistently\
  移除测试中对 SSH/API 凭据的硬编码，使自定义构建与复测能够稳定验证非默认密码

## [0.2.6] - 2026-04-14

### Fixed / 修复

- Publish only release image archives and stop uploading duplicate metadata files as GitHub release assets\
  发布时仅上传镜像压缩包，不再将重复的 metadata 文件作为 GitHub release 资产上传

## [0.2.5] - 2026-04-14

### Fixed / 修复

- Fix tagged release builds to keep using the upstream Landscape version from `build.env`, harden asset downloads, and make manual retest workflows restore build metadata from the correct path\
  修复 tag 发布时错误使用仓库版本号替代上游 Landscape 版本的问题，加固资源下载校验，并修正手动复测 workflow 的 build metadata 路径

## [0.2.4] - 2026-04-14

### Changed / 变更

- Rebuild validation around separate readiness and dataplane suites, and align CI / manual retest / release workflows on a shared validation contract with traceable artifact identity\
  将验证体系重构为 readiness 与 dataplane 两套测试，并统一 CI / 手动复测 / release 的验证契约与可追踪 artifact 身份

### Fixed / 修复

- Harden CI and release test stability by retrying API login, using less brittle tool detection, and aligning CI's default Landscape version with release builds\
  通过重试 API 登录、改进工具探测稳定性，并让 CI 默认 Landscape 版本与 release 保持一致，提升 CI 与发布测试稳定性

## [0.2.3] - 2026-04-14

### Changed / 变更

- Sync with upstream Landscape v0.18.2\
  同步上游 Landscape v0.18.2

### Fixed / 修复

- Improve build and test reliability to reduce false positives and stuck CI runs\
  改进构建与测试可靠性，减少误报和卡死的 CI 任务
- Validate CI on pull requests to `main` and make workflow conditions safer\
  对发往 `main` 的 Pull Request 执行 CI 校验，并增强工作流条件判断的安全性
- Relax Web UI and API readiness checks to better match runtime startup behavior\
  放宽 Web UI 与 API 就绪探测，使其更贴近实际启动行为
- Wait for Landscape API readiness before failing health checks, especially for Alpine Docker startup lag\
  在健康检查失败前等待 Landscape API 就绪，降低 Alpine Docker 启动较慢导致的误判

## [0.2.2] - 2026-02-23

### Changed / 变更

- Sync with upstream Landscape v0.13.0 (add device mark)\
  同步上游 Landscape v0.13.0（新增设备标记功能）

## [0.2.1] - 2026-02-13

### Added / 新增

- Add bilingual CHANGELOG.md following Keep a Changelog format\
  新增双语变更日志，遵循 Keep a Changelog 规范 (`e72d334`)
- Add `setup-mirror.sh` script for switching to Chinese package mirrors\
  新增 `setup-mirror.sh` 脚本，用于切换国内软件包镜像源 (`cf40c6c`)

### Changed / 变更

- Update image size to ~76MB, add CI concurrency control\
  更新镜像大小至约 76MB，增加 CI 并发控制 (`5f0abf9`)

### Fixed / 修复

- Improve kernel module trimming for stability and compatibility\
  改进内核模块裁剪策略，提升稳定性和兼容性 (`f623ca0`)
- Add VMware/ESXi storage drivers to Alpine initramfs\
  为 Alpine initramfs 添加 VMware/ESXi 存储驱动 (`ff8315f`)
- Use kernel `modules=` param for ESXi storage drivers instead of custom mkinitfs feature\
  使用内核 `modules=` 参数加载 ESXi 存储驱动，替代自定义 mkinitfs 特性 (`4b5551b`)

## [0.2.0] - 2026-02-12

### Added / 新增

- Add Alpine Linux support as alternative base system\
  新增 Alpine Linux 作为可选基础系统 (`44165b9`)
- Add end-to-end network tests (DHCP, DNS, NAT)\
  新增端到端网络测试（DHCP、DNS、NAT） (`44165b9`)

### Changed / 变更

- Optimize CI pipeline with parallel build-and-test jobs\
  优化 CI 流水线，采用并行构建与测试 (`44165b9`)
- Sync documentation with new architecture\
  同步文档以反映新架构 (`44165b9`)

### Fixed / 修复

- Fix output directory permissions and disable fail-fast in CI\
  修复 CI 中输出目录权限问题并禁用 fail-fast (`ee0cf7e`)
- Fix `work/` directory permissions for E2E CirrOS download\
  修复 E2E 测试中 CirrOS 下载的 `work/` 目录权限 (`3965b5a`)
- Switch CirrOS mirror to GitHub and validate download result\
  将 CirrOS 镜像源切换至 GitHub 并校验下载结果 (`3ac6bf9`)
- Update `test.yml` fallback workflow reference from `build.yml` to `ci.yml`\
  更新 `test.yml` 中回退工作流引用，由 `build.yml` 改为 `ci.yml` (`5e01a05`)

## [0.1.2] - 2026-02-11

### Added / 新增

- Add auto-expand root partition on first boot\
  新增首次启动时自动扩展根分区 (`72b089f`)
- Add deployment documentation\
  新增部署文档 (`72b089f`)

### Fixed / 修复

- Fix VNC display configuration\
  修复 VNC 显示配置 (`72b089f`)
- Use latest release URL instead of VERSION placeholder in docs\
  文档中使用最新版本链接替代 VERSION 占位符 (`71d0e01`)

## [0.1.1] - 2026-02-11

### Changed / 变更

- Aggressive image size reduction from 693MB to 312MB\
  大幅压缩镜像体积，从 693MB 缩减至 312MB (`b2dc2a8`)

## [0.1.0] - 2026-02-11

### Added / 新增

- Add minimal x86 image builder using debootstrap\
  新增基于 debootstrap 的最小化 x86 镜像构建工具 (`0112655`)
- Support BIOS + UEFI dual boot for PVE/SeaBIOS compatibility\
  支持 BIOS + UEFI 双引导，兼容 PVE/SeaBIOS (`822b5e0`)
- Add non-interactive automated test system\
  新增非交互式自动化测试系统 (`e6698f7`)
- Make test non-interactive by default, add README and CI test jobs\
  测试默认为非交互模式，新增 README 和 CI 测试任务 (`41c415f`)

### Changed / 变更

- Improve build and CI pipeline\
  改进构建和 CI 流水线 (`f34c5df`)
- Split CI into `ci.yml` and `release.yml`\
  将 CI 拆分为 `ci.yml` 和 `release.yml` (`d260ab9`)

### Fixed / 修复

- Use default mirror in CI and split artifacts by format / CI 中使用默认镜像源并按格式拆分构建产物 (`621bceb`)
- Respect `APT_MIRROR` env var override in `build.env` / `build.env` 中正确读取 `APT_MIRROR` 环境变量覆盖值 (`e261fbb`)
- Remove redundant `.gz` artifacts, compress only for release\
  移除冗余 `.gz` 产物，仅在发布时压缩 (`74d9887`)
- Add tags trigger to enable release on version tags\
  添加标签触发器以支持版本标签发布 (`bffc1f2`)
- Add concurrency group to prevent duplicate CI runs\
  添加并发组以防止 CI 重复运行 (`ee11fe2`)
- Add contents write permission for release job\
  为发布任务添加内容写入权限 (`97b6240`)

[Unreleased]: https://github.com/Cloud370/landscape-mini/compare/v0.2.9...HEAD
[0.2.9]: https://github.com/Cloud370/landscape-mini/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/Cloud370/landscape-mini/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/Cloud370/landscape-mini/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/Cloud370/landscape-mini/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/Cloud370/landscape-mini/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/Cloud370/landscape-mini/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/Cloud370/landscape-mini/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/Cloud370/landscape-mini/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Cloud370/landscape-mini/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Cloud370/landscape-mini/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/Cloud370/landscape-mini/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Cloud370/landscape-mini/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Cloud370/landscape-mini/releases/tag/v0.1.0
