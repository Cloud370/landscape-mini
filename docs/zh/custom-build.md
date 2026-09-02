# Custom Build 使用说明

[返回 README](../../README.md) | 中文 | [English](../en/custom-build.md)

## 适用场景

如果你要改这些内容，直接用 **Custom Build**：

- 网络参数
- Linux 登录密码
- Web 管理账号 / 密码
- Landscape 版本
- 输出格式

如果你只是想直接安装，优先去 [Release 页面](https://github.com/Cloud370/landscape-mini/releases/latest)。
如果你要在 PVE 中导入，构建完成后继续看 [PVE 安装引导](./pve-install.md)。

---

## 第一次怎么选

第一次使用，直接选：

- `base_system=debian`
- `include_docker=false`
- `output_formats=img`

如果你的目标是：

- 想带 Docker：改成 `include_docker=true`
- 想导入 PVE：改成 `output_formats=img,ova`
- 想更轻量：改成 `base_system=alpine`

---

## 3 步完成一次构建

### 第 1 步：打开 Actions

进入你自己的 fork 仓库后：

- 点击顶部 **Actions**
- 在左侧找到 **Custom Build**
- 点击 **Run workflow**

### 第 2 步：填写参数

现在使用的是显式组合：

- `base_system`
- `include_docker`
- `output_formats`

常用输入：

- 网络参数：`lan_server_ip`、`lan_range_start`、`lan_range_end`、`lan_netmask`
- Linux 密码：`root_password`
- Web 管理账号 / 密码：`api_username`、`api_password`
- Landscape 版本：`landscape_version`
- 测试选择：`run_test`

`run_test` 可选值：

- 留空 / `none`
- `readiness`
- `readiness,dataplane`

说明：

- `include_docker=true` 时，请求 `dataplane` 会明确 skip
- 当前优先级：**direct inputs > secrets > defaults**

### 第 3 步：运行并取回产物

点击 **Run workflow** 后，成功构建会产出：

- raw `.img`
- `build-metadata.txt`
- `effective-landscape_init.toml`
- 如果请求了额外格式，还会包含 `.vmdk` / `.ova`

现在有两种取回方式：

| 入口 | 用途 | 链接格式 |
| --- | --- | --- |
| `custom-build-latest` | 最近一次成功构建的固定入口 | `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-latest` |
| `custom-build-<artifact_id>` | 当前这次构建的不可变历史入口 | `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-<artifact_id>` |

可直接复制的下载直链格式：

- latest：`https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/<asset>`
- 历史：`https://github.com/<owner>/landscape-mini/releases/download/custom-build-<artifact_id>/<asset>`

产物文件名按构建身份固定生成，规则是：

`landscape-mini-x86-<base_system>[-docker][-lkit].<img.gz|vmdk.gz|ova>`

例如默认构建（Debian + lkit）的 OVA 是 `landscape-mini-x86-debian-lkit.ova`。

因此只要构建选项不变，你的 latest 直链就是**长期固定**的，例如：

`https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/landscape-mini-x86-debian-lkit.ova`

每次成功重新构建，同一个 URL 会自动指向最新产物 —— 可以直接写进教程、脚本或 PVE 的 URL 导入框，不用每次去页面里找。

说明：

- `<owner>` 就是你自己 fork / 仓库的用户名或组织名
- `custom-build-latest` 会随着后续成功构建更新
- `custom-build-<artifact_id>` 会固定保留，不会被后续成功构建覆盖
- workflow summary 会渲染 release 页面、历史页面和每个产物的直链表格，末尾还有「复制即用的 Latest 直链」代码块，整行复制即可
- 如果你还要保留 workflow 原始 artifact，也仍然可以记录 `run_id` / `artifact_id`

---

## 常见目标怎么选

### 我只想先做出一份镜像

直接选：

- `base_system=debian`
- `include_docker=false`
- `output_formats=img`

### 我要 Docker

直接改：

- `include_docker=true`

### 我要 PVE 导入

直接改：

- `output_formats=img,ova`

说明：

- workflow 输入统一写 `ova`
- 最终产物是 `.ova`
- 建议保留 `img`，便于测试和手动导入

### 我要更轻量

直接改：

- `base_system=alpine`

---

## 构建完成后还能做什么

如果你已经成功跑完一次 Custom Build，后面还可以继续用：

- **Test Image**

它适合：

- 对已有 artifact 再跑一次复测
- 补做 readiness / dataplane 验证
- 重新传 SSH / API 凭据测试

复测入口使用：

- `run_id`
- `artifact_id`

---

## 常见问题

### `ova` 会不会替代 `.img`？

不会。

推荐保留 `img`，再按需增加 `ova`。

### dataplane 为什么有时不会跑？

规则是：

- `run_test=` 或 `run_test=none` → 不测试
- `run_test=readiness` → 只跑 readiness
- `run_test=readiness,dataplane` 且 `include_docker=false` → 跑 readiness + dataplane
- `run_test=readiness,dataplane` 且 `include_docker=true` → dataplane 明确 skip
