# Proxmox VE（PVE）安装引导

[返回 README](../../README.md) | 中文

## 适用场景

这篇文档只解决两件事：

- 把现成镜像导入 PVE
- 把你自己构建的镜像导入 PVE

如果你还没构建镜像，先看 [Custom Build 使用说明](./custom-build.md)。

---

## 先选路径

| 你的情况 | 直接去 |
|---|---|
| 直接用仓库 Release | 看下面“推荐路径” |
| 已经有 `.ova` | 看“方式 1：通过 URL 导入 OVA” |
| 已经有 `.img` / `.img.gz` | 看“方式 2：手动导入 `.img` / `.img.gz`” |

## 推荐路径

1. 能直接用仓库 Release 镜像时，优先直接安装
2. 需要自定义参数时，再用 [Custom Build 使用说明](./custom-build.md)
3. 第一次构建，推荐 `base_system=debian`、`include_docker=true`、`output_formats=img,ova`
4. 在 PVE 中优先导入 `.ova`；不方便时再用 `.img` / `.img.gz`

## 推荐构建方式

如果你是第一次使用，推荐：

- `base_system=debian`
- `include_docker=true`
- `output_formats=img,ova`

原因：

- `base_system=debian`：默认推荐
- `include_docker=true`：省去后续再装 Docker
- `output_formats=img,ova`：同时保留 `.ova` 导入和 `.img` 手动导入

> 不需要自定义参数时，优先直接使用仓库 Release 中已经构建好的镜像。

---

## 开始前准备

请先确认：

- 你有一个可用的 PVE 节点
- 你已经拿到了构建产物：推荐 `.ova`，备用 `.img` / `.img.gz`
- 你知道要导入到哪个存储池
- 你可以登录 PVE Web 管理界面
- 如果走手动导入，你还能通过 SSH 登录 PVE 宿主机

---

## 多张网卡时，网卡类型必须一致

如果虚拟机有多张网卡，请确认它们的类型一致，例如全部是 `E1000`，或者全部是 `VirtIO`。

如果网卡类型混用，可能出现：

- WAN / LAN 顺序对调
- `eth0` 没有分配 IP
- `eth0` / `eth1` 顺序和预期不一致

处理方法：

1. 进入 PVE 虚拟机的**硬件**页面
2. 检查所有网卡的 model/type
3. 改成一致的类型
4. **重启虚拟机**

---

## 方式 1：通过 URL 直接导入 OVA

优先使用仓库官方 Release 中的 `.ova` 下载链接。

如果你使用的是 `Custom Build`，`.ova` 下载链接是固定的，见第 3 步的公式；也可以到 workflow 摘要末尾的「复制即用的 Latest 直链」直接复制。

### 第 1 步：确认存储池允许导入

在**左侧边栏**找到对应的存储图标（例如 `local`），点击进入。

在右侧面板点击 **编辑**，确认“内容”里已经勾选：

- `导入`
- `磁盘镜像`

### 第 2 步：进入导入页面

同样在左侧边栏点击该存储，右侧面板会显示它的子页列表，选择其中的 **内容**。

找到 **从 URL 下载 / 导入** 的入口。

### 第 3 步：填入下载链接

- 官方 Release：直接复制对应 `.ova` 的下载链接
- Custom Build：链接是固定的，可以直接按公式拼出 —— `https://github.com/<你的用户名>/landscape-mini/releases/download/custom-build-latest/landscape-mini-x86-<base>[-docker][-lkit].ova`（例如默认构建是 `landscape-mini-x86-debian-lkit.ova`）；或者到 workflow 运行页面，在摘要末尾的「复制即用的 Latest 直链」代码块里整行复制

然后把链接填入 PVE 的 URL 导入框。

### 第 4 步：执行导入

确认目标存储后，开始导入。

### 第 5 步：检查导入后的虚拟机配置

建议检查：

- 启动模式
- 磁盘控制器
- 网桥绑定
- CPU 类型
- 网卡模型

补充：

- 老 CPU 可优先手动设置 `CPU type=host`
- PVE 当前不会稳定从 OVF/OVA 元数据中自动继承 `CPU type=host`

---

## 方式 2：手动导入 `.img` 或 `.img.gz`

如果你不想使用 OVA，或者 OVA 导入不方便，可以走 raw 镜像导入。

### 第 1 步：先在 PVE 中创建虚拟机

新建虚拟机时：

- 正常填写 VM 名称、ID 等信息
- **不要添加硬盘**
- 其他设置按默认或你的需求填写

### 第 2 步：把 `.img` 或 `.img.gz` 放到 PVE 宿主机上

常见方式：

#### 方式 A：在 PVE 宿主机上直接下载

如果你使用官方 Release，请先复制 `.img.gz` 下载链接，然后 SSH 登录 PVE 宿主机执行：

```bash
wget -O landscape-mini.img.gz "<官方 Release 下载链接>"
```

如果你使用的是 `Custom Build`，请到你自己的 workflow 产物或固定 release 页面复制 `.img` / `.img.gz` 下载链接，再执行同样的下载步骤。

如果下载到的是 `.img.gz`，先解压：

```bash
gunzip -f landscape-mini.img.gz
```

#### 方式 B：从本地手动上传

你也可以用 `scp`、`rsync`、SFTP 或其他习惯的方式上传到 PVE 宿主机。

例如：

```bash
scp landscape-mini.img root@<pve-host>:/root/
```

如果上传的是 `.img.gz`，上传后也需要先解压：

```bash
gunzip -f /root/landscape-mini.img.gz
```

### 第 3 步：导入磁盘到 PVE

登录 PVE 宿主机后执行：

```bash
qm importdisk <vmid> /path/to/landscape-mini.img <storage>
```

例如：

```bash
qm importdisk 101 /root/landscape-mini.img local-lvm
```

说明：

- `<vmid>`：虚拟机 ID
- `/path/to/landscape-mini.img`：镜像路径
- `<storage>`：目标存储池名称

### 第 4 步：在虚拟机硬件页面挂载导入后的磁盘

回到 PVE Web 页面：

**虚拟机 -> 硬件**

找到刚导入的磁盘，把它挂载到你要使用的位置，例如 `scsi0`、`sata0`。

然后设置：

- 启动顺序
- 该磁盘为启动盘

---

## 首次启动后的检查

启动虚拟机后，建议先执行：

```bash
ip a
```

重点看：

- `eth0` 是否拿到了预期的 IP
- `eth1` 是否对应你预期的另一张网卡
- WAN / LAN 是否和你的接线、bridge 配置一致

如果 `eth0` 没有 IP，或者 `eth0` / `eth1` 顺序异常，优先回到 PVE 检查多张网卡的类型是否一致。

---

## 磁盘扩容说明

Landscape Mini 支持在启动时自动扩展根分区到当前磁盘大小。

这意味着：

- **首次启动时**会自动扩容到当前磁盘大小
- 后续如果你在 PVE 中把磁盘调大，**下次重启时**也会继续扩容

### 在 PVE 中如何扩容

进入：

**虚拟机 -> 硬件 -> 选中硬盘 -> 磁盘操作 -> 调整大小**

例如可先增加：

- **16G**

### 注意

当前 **不支持热扩容立即生效**。

在 PVE 里调整硬盘大小后，需要 **重启虚拟机**，扩容才会在下一次启动时生效。

---

## 常见问题

### 为什么通过 URL 导入失败？

先确认目标存储已经开启：

- `导入`
- `磁盘镜像`

路径：

**数据中心 -> 存储 -> 对应存储对象（例如 `local`） -> 编辑 -> 内容**

### 出现这个错误怎么办？

```text
sata0: import working storage 'local' does not support 'images' content type or is not filebased
```

通常表示：

- 选中的 working storage 没有开启 `磁盘镜像`
- 或它不是适合该导入流程的 file-based storage

处理方法：

1. 进入 **数据中心 -> 存储 -> local -> 编辑**
2. 确认“内容”里已勾选：`导入`、`磁盘镜像`
3. 如果仍失败，改用支持 file-based 的目录型存储，或者改走手动导入 `.img`

### PVE 控制台里中文显示成小方块？

PVE 网页控制台（noVNC）显示的是虚拟机的**内核控制台**画面。Linux 内核控制台字体最多只能加载约 512 个字形，装不下任何 CJK 字符集，所以中文一律渲染成方块 —— 这是内核控制台的固有限制，不是 noVNC 或镜像的问题。

需要中文交互（例如 `lkit` 的中文 TUI）时请改用：

- SSH 登录：由你本地终端渲染，字体齐全
- Landscape 的 Web 终端：由浏览器渲染

### 为什么启动后 `eth0` 没有分配 IP？

优先检查：

- 虚拟机是否有多张网卡
- 多张网卡的类型是否一致

如果混用不同网卡类型，就可能导致 `eth0` / `eth1` 顺序混乱，或者 `eth0` 没有拿到预期 IP。

解决方法：

1. 把所有网卡改成一致类型
2. 重启虚拟机
3. 再次执行 `ip a` 检查

### OVA 导入后还需要检查什么？

至少检查：

- 启动模式
- 磁盘控制器
- 网桥绑定
- CPU 类型
- 网卡类型是否一致

如果是老 CPU，建议优先手动设置 CPU type 为 `host`。

### 导入后为什么磁盘容量没有立刻变大？

因为当前扩容是在**启动时生效**的。

如果你刚在 PVE 中执行了“调整大小”，需要重启虚拟机，扩容才会在下一次启动时生效。
