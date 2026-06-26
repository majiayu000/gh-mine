#!/usr/bin/env bash
# gh-mine installer — downloads the script into ~/.local/bin and checks runtime deps.
set -euo pipefail

REPO="majiayu000/gh-mine"
BRANCH="main"
SOURCE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/gh-mine"

INSTALL_DIR="${GH_MINE_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="${INSTALL_DIR}/gh-mine"

command -v curl >/dev/null 2>&1 || { echo "install: 需要 'curl'" >&2; exit 1; }

mkdir -p "$INSTALL_DIR"
echo "下载 gh-mine -> ${TARGET}"
curl -fsSL "$SOURCE_URL" -o "$TARGET"
chmod +x "$TARGET"

# 运行时依赖提示（不致命，因为 install 也能在已装 gh/jq 后才用）
for c in gh jq; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "提示: 缺少运行时依赖 '${c}'，请先安装" >&2
  fi
done

# PATH 提示
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo "提示: ${INSTALL_DIR} 不在 PATH，请在 shell 配置中加入：" >&2
    echo "  export PATH=\"\$PATH:${INSTALL_DIR}\"" >&2
    ;;
esac

echo "完成。运行: gh-mine --help"
