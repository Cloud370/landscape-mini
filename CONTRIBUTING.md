# Contributing

## 开发流程

默认流程：

1. 从 `main` 拉新分支
2. 开发并做必要验证
3. 如属于用户可感知变更，更新 `CHANGELOG.md` 的 `Unreleased`
4. 提交 commit
5. push 分支
6. 开 PR 合并到 `main`
7. 等 CI 通过后合并

示例：

```bash
git checkout main
git pull --ff-only origin main
git checkout -b fix/ci-timeouts

# 开发 + 验证

git add <files>
git commit -m "fix(ci): bound workflow test execution"
git push -u origin fix/ci-timeouts
```

## CHANGELOG 规则

`CHANGELOG.md` 维护方式：

- 日常开发时，把值得记录的内容写到 `Unreleased`
- 发版时，把 `Unreleased` 整理成具体版本

应该写入 changelog 的改动：

- 新功能
- bug 修复
- 构建、测试、CI/CD 行为变化
- 兼容性变化
- 默认配置变化

通常不写：

- 纯重构且无行为变化
- 纯注释修改
- 拼写修正
- 内部实现细节调整

## Commit 规范

推荐使用简洁的 Conventional Commits：

- `fix(...)`
- `feat(...)`
- `docs(...)`
- `chore(...)`
- `refactor(...)`
- `test(...)`

示例：

```text
fix(ci): bound workflow test execution
fix(tests): reduce false positives in API readiness checks
chore: release v0.2.3
```

## Push / PR 规则

日常开发不建议直接 `push origin main`。

推荐：

- push 到功能分支
- 通过 PR 合并到 `main`

以下场景更应走 PR：

- CI / workflow 改动
- release 流程改动
- 构建脚本改动
- 测试框架改动

可接受直接推 `main` 的情况：

- 仓库维护者处理紧急 hotfix
- 极小且低风险的文档或元数据修复

## 发版流程

本仓库当前的正确发版顺序：

**main 可发布 → 整理 changelog → 创建 release commit → push main → 打 tag → push tag → 执行 release rebuild**

示例：

```bash
git checkout main
git pull --ff-only origin main

# 更新 CHANGELOG.md，把 Unreleased 归档为 0.2.3

git add CHANGELOG.md
git commit -m "chore: release v0.2.3"
git push origin main

git tag v0.2.3
git push origin v0.2.3
```

`release.yml` 现在会：
- 在 tag 对应 commit 上重新构建 2 个 Debian tuple artifacts
- tuple 覆盖为 `debian + include_docker=false` 与 `debian + include_docker=true`
- 请求发布所需输出：`img,ova`
- 校验 metadata / effective topology config / tuple 完整性
- 压缩 raw `.img` 并创建 GitHub Release

它**不再**依赖 `main` 上已有成功 `ci.yml` 的 artifacts。

自动 `ci.yml` 现在只承担快速验证：
- 仅验证 `debian + include_docker=false`
- 仅请求 raw `img`
- 运行 `readiness,dataplane`

不要这样做：

- 继续把 release 理解成“promote CI artifacts”
- 期待 tag 发布依赖 main 上已有成功 CI run 才能工作
- 先打 tag，再补 release commit
- 先 push tag，再改 `CHANGELOG.md`
- 把上游 Landscape 版本当作本仓库 release 版本

## 版本号说明

本仓库有两套版本号：

### 仓库自身 release 版本

Git tag 使用仓库自己的版本序列，例如：

- `v0.2.2`
- `v0.2.3`

### 上游 Landscape 版本

`build.env` 中的 `LANDSCAPE_VERSION` 表示上游 Landscape 版本，例如：

- `v0.24.2`

它不等于本仓库自己的 release tag。

当前 tuple 覆盖要求：

- `debian + include_docker=false`
- `debian + include_docker=true`

当前公开 release 面：

- 仅发布 Debian artifacts
- 发布文件为 `.img.gz` + `.ova`