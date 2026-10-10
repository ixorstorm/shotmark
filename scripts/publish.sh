#!/bin/bash
# 把 work/shotmark 的最新状态发布到 GitHub（ixorstorm/shotmark）。
# 工作区是唯一真实源，GitHub 是公开镜像：用 subtree split 保留真实开发历史。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"   # 工作区根
BRANCH=shotmark-public
git subtree split --prefix=work/shotmark -b "$BRANCH"
git push https://github.com/ixorstorm/shotmark.git "$BRANCH:main"
echo "✔ 已推送到 GitHub main"
