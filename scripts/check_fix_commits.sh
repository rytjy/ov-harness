#!/usr/bin/env bash
# check_fix_commits.sh — 核查 remediation 报告里声称的 fix commit 是否在受审版本中
#
# 用法:
#   check_fix_commits.sh <owner/repo> <reviewed_sha> <remediation.txt|pdf>
#   check_fix_commits.sh <owner/repo> --dry <remediation.txt|pdf>     # 只抽 SHA，不打 API
#
# 产出三档 triage:
#   PRESENT              → 修复是受审版本的祖先（compare: ahead & behind_by=0）
#   NOT IN REVISION      → 修复存在但受审版本早于它（behind）
#   EXISTS, NOT ON LINE  → 提交在该仓库，但不在受审版本的祖先链上（rebase/squash？）
#   NOT IN REPO          → 该仓库里没有（去查其它仓库 / 私有仓库）
#
# 注意: 未认证 GitHub API 限 60 次/小时。设 GITHUB_TOKEN 可提高限额。
set -uo pipefail
[ $# -eq 3 ] || { echo "用法: $0 <owner/repo> <reviewed_sha|--dry> <file.pdf|txt>"; exit 2; }
REPO="$1"; PIN="$2"; DOC="$3"
API="https://api.github.com/repos/$REPO"
TOK="${GITHUB_TOKEN:-}"; AUTH=(); [ -n "$TOK" ] && AUTH=(-H "Authorization: Bearer $TOK")

case "$DOC" in
  *.pdf) TMP="$(mktemp -t fixdoc).txt"; pdftotext -q "$DOC" "$TMP" || { echo "pdftotext 失败"; exit 2; }; SRC="$TMP" ;;
  *)     SRC="$DOC" ;;
esac

SHAS="$(grep -oE '\b[0-9a-f]{40}\b' "$SRC" | sort -u)"
[ -n "$SHAS" ] || { echo "没抽到 40 位 SHA —— 文档可能是扫描件（无文字层）"; exit 3; }

if [ "$PIN" = "--dry" ]; then
  echo "抽到 $(printf '%s\n' "$SHAS" | wc -l) 个 SHA（--dry，未打 API）:"; printf '  %s\n' $SHAS; exit 0
fi

printf '%-12s %-8s %s\n' "FIX_SHA" "HTTP" "VERDICT"
for sha in $SHAS; do
  st=""; ahead=""; behind=""; code="200"
  body="$(curl -sS -m 30 "${AUTH[@]}" "$API/compare/$sha...$PIN" 2>/dev/null)"
  read -r st ahead behind <<<"$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("status","?"), d.get("ahead_by",""), d.get("behind_by",""))
except Exception: print("ERR","","")' 2>/dev/null)"
  case "$st" in
    ahead|identical) v="PRESENT (ahead=$ahead behind=$behind)" ;;
    behind)          v="NOT IN REVISION (revision predates the fix)" ;;
    diverged)        v="DIVERGED — manual look" ;;
    *) code="$(curl -sS -m 30 "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$API/commits/$sha" 2>/dev/null)"
       case "$code" in
         200) v="EXISTS, NOT ON LINE (rebased/squashed?)" ;;
         *)   v="NOT IN REPO (http $code) — check other/private repos" ;;
       esac ;;
  esac
  printf '%-12s %-8s %s\n' "${sha:0:10}" "$code" "$v"
  sleep 1
done
