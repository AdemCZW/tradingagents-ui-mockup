#!/bin/bash
# 上線後驗證：整理好的每個檔案都要和線上一模一樣（md5），不該公開的路徑都要 404。
# 唯讀：只發 GET 請求，不改任何東西，可以隨時對線上站跑。
# 用法：bash tools/verify-live.sh <整理好的目錄> [網址]      （網址預設 deploy.config.sh 的 LIVE_URL）
#
# 為什麼要重試：剛部署完，邊緣節點可能還在回舊版，第一次比對不符不代表部署失敗。
# 不符的項目每 RETRY_INTERVAL 秒重比一次，最多比 MAX_ATTEMPTS 次（含第一次），仍不符才判定失敗。
# zsh 不會自動拆變數、陣列從 1 起算，用 zsh/sh 跑會出現難查的錯，直接擋掉
[ -n "${BASH_VERSION:-}" ] || { echo "請用 bash 執行：bash $0"; exit 1; }
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy.config.sh
source "$HERE/deploy.config.sh"

STAGED_ARG="${1:?用法：bash tools/verify-live.sh <整理好的目錄> [網址]}"
[ -d "$STAGED_ARG" ] || { echo "找不到整理好的目錄：$STAGED_ARG"; exit 1; }
STAGED="$(cd "$STAGED_ARG" && pwd)"
BASE="${2:-$LIVE_URL}"
BASE="${BASE%/}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
RETRY_INTERVAL="${RETRY_INTERVAL:-5}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

file_md5() {
  if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi
}

# 路徑百分比編碼（中文、空白檔名）。bash 3.2 的 printf "'c" 對高位元組會給負數，要自己補回 0–255。
urlencode_path() {
  local LC_ALL=C
  local s="$1" o="" c n h i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9/._~-]) o="$o$c" ;;
      *) printf -v n '%d' "'$c"; n=$(( (n + 256) % 256 )); printf -v h '%%%02X' "$n"; o="$o$h" ;;
    esac
  done
  printf '%s' "$o"
}

# 檔案路徑 → 線上網址路徑。Workers 預設 html_handling=auto-trailing-slash：
# /index.html 會 307 導向 /、/a/index.html → /a/、/a.html → /a。比對導向前的網址只會拿到 307，要比對導向後的。
url_path_for() {
  local rel="$1"
  case "$rel" in
    index.html) printf '/' ;;
    */index.html) printf '/%s/' "${rel%/index.html}" ;;
    *.html) printf '/%s' "${rel%.html}" ;;
    *) printf '/%s' "$rel" ;;
  esac
}

# ── 建立檢查清單：每行「種類<TAB>網址路徑<TAB>參數」─────────────────
ITEMS="$WORK/items"; : > "$ITEMS"

# 1) 每個整理出的檔案 → md5 必須一致
( cd "$STAGED" && find . -type f ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort ) > "$WORK/files"
while IFS= read -r rel; do
  case "$rel" in
    _headers|_redirects|.assetsignore) continue ;;   # Workers 讀取後不對外提供，改由下面的 404／標頭檢查驗證
  esac
  printf 'md5\t%s\t%s\n' "$(url_path_for "$rel")" "$rel" >> "$ITEMS"
done < "$WORK/files"

# 2) 不該公開的路徑 → 必須 404
{
  printf '%s\n' /docs/ /tests/ /README.md /.env /wrangler.jsonc /package.json
  [ -f "$STAGED/_headers" ] && echo /_headers
  [ -f "$STAGED/_redirects" ] && echo /_redirects
  for p in ${EXTRA_404_PATHS[@]+"${EXTRA_404_PATHS[@]}"}; do echo "$p"; done
  # 來源專案裡實際存在的敏感檔（docs/、tests/、*.md…），抽前 30 個逐一確認線上沒有
  # 只 404 目錄網址不夠：Workers 沒有目錄列表，/docs/ 404 不代表 /docs/brief.md 不在線上
  if [ -d "$PROJECT_DIR" ]; then
    expr=()
    for n in "${FORBIDDEN_NAMES[@]}"; do [ ${#expr[@]} -gt 0 ] && expr+=(-o); expr+=(-iname "$n"); done
    for d in "${FORBIDDEN_DIRS[@]}"; do [ ${#expr[@]} -gt 0 ] && expr+=(-o); expr+=(-path "./$d/*"); done
    ( cd "$PROJECT_DIR" && find . \( -name node_modules -o -name .git -o -name .wrangler \) -prune -o -type f \( "${expr[@]}" \) -print 2>/dev/null \
        | sed 's|^\.||' | LC_ALL=C sort | head -n 30 ) || true
  fi
} | LC_ALL=C sort -u | while IFS= read -r p; do
  [ -n "$p" ] || continue
  # 萬一這個路徑本來就是整理出的合法檔案，交給 md5 檢查，不要求 404
  # （_headers／_redirects 例外：它們在整理目錄裡，但 Workers 不該對外提供）
  case "$p" in /_headers|/_redirects|/.assetsignore) ;; *)
    [ -e "$STAGED/${p#/}" ] && [ ! -d "$STAGED/${p#/}" ] && continue ;;
  esac
  printf '404\t%s\t-\n' "$p"
done >> "$ITEMS"

# 3) _headers 有設防收錄 → 線上首頁回應必須真的帶 X-Robots-Tag: noindex
if [ -f "$STAGED/_headers" ] && grep -qi 'X-Robots-Tag' "$STAGED/_headers"; then
  printf 'hdr\t/\tx-robots-tag:noindex\n' >> "$ITEMS"
fi

total=$(wc -l < "$ITEMS" | tr -d ' ')
echo "驗證 $BASE：$total 項（檔案 md5、應 404 路徑、防收錄標頭）"
if [ "${VERBOSE:-0}" = "1" ]; then
  echo "檢查清單："; sed 's/^/  /' "$ITEMS"
fi

# ── 單項檢查：通過回 0；失敗回 1 並把原因寫到 $WORK/reason ─────────────
check_item() {
  local kind="$1" path="$2" arg="$3" url code body="$WORK/body" hdrs="$WORK/hdrs" local_md5 remote_md5
  url="$BASE$(urlencode_path "$path")"
  code=$(curl -sS --max-time 60 -H 'Cache-Control: no-cache' -D "$hdrs" -o "$body" -w '%{http_code}' "$url" 2>"$WORK/curlerr") || code="000"
  case "$kind" in
    md5)
      if [ "$code" != "200" ]; then
        echo "HTTP $code（預期 200）$(head -c 200 "$WORK/curlerr")" > "$WORK/reason"; return 1
      fi
      local_md5=$(file_md5 "$STAGED/$arg"); remote_md5=$(file_md5 "$body")
      if [ "$local_md5" != "$remote_md5" ]; then
        echo "md5 不符：本機 $local_md5／線上 $remote_md5" > "$WORK/reason"; return 1
      fi ;;
    404)
      if [ "$code" != "404" ]; then
        echo "HTTP $code（預期 404）" > "$WORK/reason"; return 1
      fi ;;
    hdr)
      local name="${arg%%:*}" want="${arg#*:}" got
      got=$(grep -i "^$name:" "$hdrs" | tr -d '\r' || true)
      if [ "$code" != "200" ] || ! printf '%s' "$got" | grep -qi -- "$want"; then
        echo "HTTP $code，標頭 $name 未含 $want（實得：${got:-無}）" > "$WORK/reason"; return 1
      fi ;;
  esac
  return 0
}

# ── 分輪比對：第一輪全部，之後只重比不符的 ───────────────────────────
cp "$ITEMS" "$WORK/pending"
attempt=1
while :; do
  : > "$WORK/next"; : > "$WORK/failed"
  while IFS=$'\t' read -r kind path arg; do
    if check_item "$kind" "$path" "$arg"; then :; else
      printf '%s\t%s\t%s\n' "$kind" "$path" "$arg" >> "$WORK/next"
      printf '  ❌ [%s] %s — %s\n' "$kind" "$path" "$(cat "$WORK/reason")" >> "$WORK/failed"
    fi
  done < "$WORK/pending"
  left=$(wc -l < "$WORK/next" | tr -d ' ')
  [ "$left" -eq 0 ] && break
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then break; fi
  echo "第 $attempt 次比對：$left 項不符，${RETRY_INTERVAL} 秒後重試（最多 $MAX_ATTEMPTS 次）"
  sleep "$RETRY_INTERVAL"
  attempt=$((attempt + 1))
  cp "$WORK/next" "$WORK/pending"
done

failed=$(wc -l < "$WORK/next" | tr -d ' ')
passed=$((total - failed))
if [ "$failed" -gt 0 ]; then
  echo "比對 $attempt 次後仍不符："
  cat "$WORK/failed"
fi
echo "結果：通過 $passed／失敗 $failed（共 $total 項，比對 $attempt 次）"
[ "$failed" -eq 0 ] || exit 1
echo "✅ 線上內容與整理出的檔案一致"
