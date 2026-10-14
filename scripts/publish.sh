#!/bin/bash
# 把 work/shotmark 的最新状态发布到 GitHub（ixorstorm/shotmark）。
# 工作区是唯一真实源，GitHub 是公开镜像：用 subtree split 保留真实开发历史。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"   # 工作区根

# 🔒 发布门禁：自检不过不许发布（不可绕过）
echo "▸ 发布前自检…"
( cd work/shotmark && make selftest )
echo "✔ 自检通过"

BRANCH=shotmark-public
git subtree split --prefix=work/shotmark -b "$BRANCH"
# 绕过全局 gitconfig 里的 ghfast.top 镜像改写（它没有我们的凭证）；osxkeychain 在系统级配置，不受影响
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git push https://github.com/ixorstorm/shotmark.git "$BRANCH:main"
echo "✔ 已推送到 GitHub main"
