#!/bin/bash
# 部署到 Cloudflare Workers（靜態資源）。帳號 Pages 專案數已達上限，新站一律走 Workers。
# 優點：刪除 Worker 即下架；preview_urls 關閉，只公開最新版本，舊版不留網址。
# 流程：stage.sh 白名單整理＋檢查 → 產生 wrangler.jsonc → wrangler deploy → verify-live.sh 逐檔比對線上
# 用法：bash tools/deploy.sh        （工作區的危險動作護欄會要求確認）
# zsh 不會自動拆變數、陣列從 1 起算，用 zsh/sh 跑會出現難查的錯，直接擋掉
[ -n "${BASH_VERSION:-}" ] || { echo "請用 bash 執行：bash $0"; exit 1; }
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy.config.sh
source "$HERE/deploy.config.sh"

[ "$WORKER_NAME" != "my-site" ] || { echo "❌ 請先在 deploy.config.sh 設定 WORKER_NAME"; exit 1; }
command -v wrangler >/dev/null || { echo "❌ 找不到 wrangler（npm i -g wrangler）"; exit 1; }

# 記下這次部署的是哪個 commit；工作目錄有未提交變更時警告（線上會對不上任何 commit）
commit="(非 git 專案)"
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  commit="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    echo "⚠️  工作目錄有未提交的變更，線上版本將不等於 $commit"
    commit="$commit-dirty"
  fi
fi

# 部署前回歸測試：測試沒過就不部署（規格 §6.7）
tests=( ${PRE_DEPLOY_TESTS[@]+"${PRE_DEPLOY_TESTS[@]}"} )
if [ "${SKIP_TESTS:-0}" = "1" ]; then
  echo "⚠️  SKIP_TESTS=1：跳過部署前測試，請在交付檢查清單寫明原因"
elif [ ${#tests[@]} -eq 0 ]; then
  echo "⚠️  deploy.config.sh 沒有設定 PRE_DEPLOY_TESTS：這次部署沒有任何回歸測試把關"
else
  echo "── 部署前測試 ──"
  for t in "${tests[@]}"; do
    echo "▸ $t"
    ( cd "$PROJECT_DIR" && eval "$t" ) || { echo "❌ 測試未通過，停止部署：$t"; exit 1; }
  done
  echo "✅ 部署前測試全部通過"
fi

TMP="$(mktemp -d)"
OUT="$TMP/site"
bash "$HERE/stage.sh" "$OUT"              # 白名單整理＋檢查，失敗即中止（set -e）

account_line=""
[ -n "$CLOUDFLARE_ACCOUNT_ID_FOR_DEPLOY" ] && account_line="\"account_id\": \"$CLOUDFLARE_ACCOUNT_ID_FOR_DEPLOY\","
cat > "$TMP/wrangler.jsonc" <<JSON
{
  "name": "$WORKER_NAME",
  $account_line
  "compatibility_date": "$COMPATIBILITY_DATE",
  "workers_dev": true,
  "preview_urls": false,
  "assets": { "directory": "$OUT", "not_found_handling": "404-page" }
}
JSON

echo "── 部署 $WORKER_NAME（commit $commit）──"
# 刻意不把 wrangler 輸出接進管線（| tee、| grep 等）：管線會吞掉 wrangler 的失敗狀態，
# 曾經部署失敗了腳本還繼續往下跑。直接執行，失敗由 set -e 中止。
(cd "$TMP" && wrangler deploy --message "commit $commit")

echo "── 驗證線上內容 ──"
if ! bash "$HERE/verify-live.sh" "$OUT" "$LIVE_URL"; then
  echo "❌ 已部署，但線上內容與整理出的檔案不一致（整理目錄保留：$OUT）"
  echo "   稍等再重跑：bash tools/verify-live.sh \"$OUT\""
  exit 1
fi

rm -rf "$TMP"
echo "✅ 部署並驗證完成：$LIVE_URL（commit $commit）"
