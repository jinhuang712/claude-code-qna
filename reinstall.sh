#!/usr/bin/env bash
# qna 插件：一键卸载 → 清缓存 → 重装 → 校验
#
# 为什么不用 `claude plugin update`：它靠 .claude-plugin/plugin.json 的 version
# 字符串判新旧、不 git pull 本地那份 marketplace 缓存——版本没提就误判"没变"、
# 回报 "already at the latest" 空转不更新。本脚本直接铲掉本地缓存，重拉一份干净的。
#
# 两种来源，默认自动判断：
#
#   本地  脚本旁边就是仓库（如 ~/dev/skills/claude-code-qna）→ 装工作区当前状态，
#         未 commit 的改动也生效，本地开发用这个
#   远端  脚本是 curl 下来的孤儿 → 装 GitHub main 上已 push 的版本
#
# 已 clone 本仓的，直接跑（装工作区）：
#   bash reinstall.sh
#
# 没 clone 的一键跑（装 main）：
#   curl -fsSL https://raw.githubusercontent.com/jinhuang712/claude-code-qna/main/reinstall.sh | bash
#
# 强制指定来源：
#   bash reinstall.sh --local      # 装工作区，即使有远端
#   bash reinstall.sh --remote     # 装 main，即使在 clone 里

set -euo pipefail

NAME="qna"
MARKETPLACE="qna-marketplace"       # 与插件名不同：marketplace.json 里叫这个
PLUGIN_ID="${NAME}@${MARKETPLACE}"
REPO_URL="https://github.com/jinhuang712/claude-code-qna.git"
PLUGINS_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
skip() { printf '    \033[2m%s\033[0m\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --local)  MODE="local" ;;
    --remote) MODE="remote" ;;
    # 头部注释块就是帮助文本，去掉 # 前缀原样打出，不另维护一份说明
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) die "未知参数 ${arg}（只认 --local / --remote）" ;;
  esac
done

command -v claude >/dev/null 2>&1 || die "找不到 claude CLI；确认已装 Claude Code 且在 PATH 里"

# curl | bash 时 BASH_SOURCE 是 /dev/stdin 之类，解析不出仓库——那正是远端模式。
REPO_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "${candidate}/.claude-plugin/marketplace.json" ] && REPO_DIR="${candidate}"
fi

case "$MODE" in
  local)
    [ -n "$REPO_DIR" ] || die "--local 要求脚本在仓库里跑，但旁边没有 .claude-plugin/marketplace.json"
    SOURCE="$REPO_DIR" ;;
  remote)
    SOURCE="$REPO_URL" ;;
  auto)
    if [ -n "$REPO_DIR" ]; then SOURCE="$REPO_DIR"; else SOURCE="$REPO_URL"; fi ;;
esac

if [ "$SOURCE" = "$REPO_URL" ]; then
  log "来源：远端 ${REPO_URL}（装 main 上已 push 的版本）"
else
  log "来源：本地 ${SOURCE}（装工作区当前状态，含未 commit 的改动）"
fi

# 本地模式下先跑冒烟，别把坏的装进去。远端模式没有测试文件，跳过。
if [ -n "$REPO_DIR" ] && [ -x "${REPO_DIR}/tests/smoke.sh" ]; then
  log "0/6 跑冒烟测试"
  "${REPO_DIR}/tests/smoke.sh" || die "冒烟测试没过，装载中止。先修好再来。"
else
  skip "0/6 无测试文件（远端模式），跳过"
fi

if [ "$SOURCE" != "$REPO_URL" ]; then
  log "1/6 校验 manifest（marketplace + plugin）"
  claude plugin validate "${SOURCE}" >/dev/null ||
    die "marketplace manifest 没过：claude plugin validate ${SOURCE}"
  claude plugin validate "${SOURCE}/plugins/${NAME}" >/dev/null ||
    die "plugin manifest 没过：claude plugin validate ${SOURCE}/plugins/${NAME}"
else
  skip "1/6 远端来源，本地无从校验，跳过"
fi

log "2/6 卸载旧插件 ${PLUGIN_ID}（未装则跳过）"
claude plugin uninstall -y "${PLUGIN_ID}" 2>/dev/null || skip "未安装或已卸载，跳过"

log "3/6 移除 marketplace ${MARKETPLACE}（未加则跳过）"
claude plugin marketplace remove "${MARKETPLACE}" 2>/dev/null || skip "未配置或已移除，跳过"

log "4/6 铲掉本地缓存克隆（强制下次全新拉取）"
rm -rf "${PLUGINS_DIR}/cache/${MARKETPLACE}" \
       "${PLUGINS_DIR}/marketplaces/${MARKETPLACE}"

log "5/6 重新添加 marketplace 并安装"
claude plugin marketplace add "${SOURCE}"
claude plugin install "${PLUGIN_ID}"

log "6/6 校验安装结果"
installed_ver="$(ls "${PLUGINS_DIR}/cache/${MARKETPLACE}/${NAME}" 2>/dev/null | head -1 || true)"
if [ -n "${installed_ver}" ]; then
  log "已安装版本：${installed_ver}"
else
  warn "缓存目录里没看到 ${PLUGINS_DIR}/cache/${MARKETPLACE}/${NAME}"
  warn "本地路径 marketplace 可能直接读源目录、不落缓存——以下面的 list 为准"
fi
claude plugin list 2>/dev/null | grep -i "${NAME}" || warn "plugin list 里没看到 ${NAME}，安装可能失败"

printf '\n\033[1;32m✔ 完成。\033[0m 改动只在\033[1m新会话\033[0m生效——当前会话仍跑旧缓存，请重开 Claude Code。\n'
printf '   验证：新会话里看有没有注入 QNA_ADD / QNA_MARK 四条命令，然后跑 \033[1m/qna:ask\033[0m。\n'
