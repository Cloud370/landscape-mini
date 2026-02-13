# Changelog / 变更日志

All notable changes to this project will be documented in this file.
本文件记录项目的所有重要变更。

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 规范。

## [Unreleased]

## [0.2.1] - 2026-02-13

### Added / 新增

- Add bilingual CHANGELOG.md following Keep a Changelog format / 新增双语变更日志，遵循 Keep a Changelog 规范 (`e72d334`)
- Add `setup-mirror.sh` script for switching to Chinese package mirrors / 新增 `setup-mirror.sh` 脚本，用于切换国内软件包镜像源 (`cf40c6c`)

### Changed / 变更

- Update image size to ~76MB, add CI concurrency control / 更新镜像大小至约 76MB，增加 CI 并发控制 (`5f0abf9`)

### Fixed / 修复

- Improve kernel module trimming for stability and compatibility / 改进内核模块裁剪策略，提升稳定性和兼容性 (`f623ca0`)
- Add VMware/ESXi storage drivers to Alpine initramfs / 为 Alpine initramfs 添加 VMware/ESXi 存储驱动 (`ff8315f`)
- Use kernel `modules=` param for ESXi storage drivers instead of custom mkinitfs feature / 使用内核 `modules=` 参数加载 ESXi 存储驱动，替代自定义 mkinitfs 特性 (`4b5551b`)

## [0.2.0] - 2026-02-12

### Added / 新增

- Add Alpine Linux support as alternative base system / 新增 Alpine Linux 作为可选基础系统 (`44165b9`)
- Add end-to-end network tests (DHCP, DNS, NAT) / 新增端到端网络测试（DHCP、DNS、NAT）(`44165b9`)

### Changed / 变更

- Optimize CI pipeline with parallel build-and-test jobs / 优化 CI 流水线，采用并行构建与测试 (`44165b9`)
- Sync documentation with new architecture / 同步文档以反映新架构 (`44165b9`)

### Fixed / 修复

- Fix output directory permissions and disable fail-fast in CI / 修复 CI 中输出目录权限问题并禁用 fail-fast (`ee0cf7e`)
- Fix `work/` directory permissions for E2E CirrOS download / 修复 E2E 测试中 CirrOS 下载的 `work/` 目录权限 (`3965b5a`)
- Switch CirrOS mirror to GitHub and validate download result / 将 CirrOS 镜像源切换至 GitHub 并校验下载结果 (`3ac6bf9`)
- Update `test.yml` fallback workflow reference from `build.yml` to `ci.yml` / 更新 `test.yml` 中回退工作流引用，由 `build.yml` 改为 `ci.yml` (`5e01a05`)

## [0.1.2] - 2026-02-11

### Added / 新增

- Add auto-expand root partition on first boot / 新增首次启动时自动扩展根分区 (`72b089f`)
- Add deployment documentation / 新增部署文档 (`72b089f`)

### Fixed / 修复

- Fix VNC display configuration / 修复 VNC 显示配置 (`72b089f`)
- Use latest release URL instead of VERSION placeholder in docs / 文档中使用最新版本链接替代 VERSION 占位符 (`71d0e01`)

## [0.1.1] - 2026-02-11

### Changed / 变更

- Aggressive image size reduction from 693MB to 312MB / 大幅压缩镜像体积，从 693MB 缩减至 312MB (`b2dc2a8`)

## [0.1.0] - 2026-02-11

### Added / 新增

- Add minimal x86 image builder using debootstrap / 新增基于 debootstrap 的最小化 x86 镜像构建工具 (`0112655`)
- Support BIOS + UEFI dual boot for PVE/SeaBIOS compatibility / 支持 BIOS + UEFI 双引导，兼容 PVE/SeaBIOS (`822b5e0`)
- Add non-interactive automated test system / 新增非交互式自动化测试系统 (`e6698f7`)
- Make test non-interactive by default, add README and CI test jobs / 测试默认为非交互模式，新增 README 和 CI 测试任务 (`41c415f`)

### Changed / 变更

- Improve build and CI pipeline / 改进构建和 CI 流水线 (`f34c5df`)
- Split CI into `ci.yml` and `release.yml` / 将 CI 拆分为 `ci.yml` 和 `release.yml` (`d260ab9`)

### Fixed / 修复

- Use default mirror in CI and split artifacts by format / CI 中使用默认镜像源并按格式拆分构建产物 (`621bceb`)
- Respect `APT_MIRROR` env var override in `build.env` / `build.env` 中正确读取 `APT_MIRROR` 环境变量覆盖值 (`e261fbb`)
- Remove redundant `.gz` artifacts, compress only for release / 移除冗余 `.gz` 产物，仅在发布时压缩 (`74d9887`)
- Add tags trigger to enable release on version tags / 添加标签触发器以支持版本标签发布 (`bffc1f2`)
- Add concurrency group to prevent duplicate CI runs / 添加并发组以防止 CI 重复运行 (`ee11fe2`)
- Add contents write permission for release job / 为发布任务添加内容写入权限 (`97b6240`)

[Unreleased]: https://github.com/Cloud370/landscape-mini/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/Cloud370/landscape-mini/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Cloud370/landscape-mini/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/Cloud370/landscape-mini/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Cloud370/landscape-mini/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Cloud370/landscape-mini/releases/tag/v0.1.0
