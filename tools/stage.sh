#!/bin/bash
# 部署前整理：只把白名單內的檔案複製到乾淨目錄，並做上線前檢查。
# 不依賴任何忽略檔行為——docs/、tests/ 常含客戶與品牌資訊，絕不能上傳。
# 用法：bash tools/stage.sh <輸出目錄>          （輸出目錄必須不存在）
# 相容 macOS 內建 bash 3.2：不用 mapfile、關聯陣列；空陣列一律用 ${a[@]+"${a[@]}"} 展開。
# zsh 不會自動拆變數、陣列從 1 起算，用 zsh/sh 跑會出現難查的錯，直接擋掉
[ -n "${BASH_VERSION:-}" ] || { echo "請用 bash 執行：bash $0"; exit 1; }
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy.config.sh
source "$HERE/deploy.config.sh"

OUT_ARG="${1:?用法：bash tools/stage.sh <輸出目錄>}"
[ -e "$OUT_ARG" ] && { echo "輸出目錄已存在：$OUT_ARG（請指定新的空目錄）"; exit 1; }
[ -d "$PROJECT_DIR" ] || { echo "找不到來源專案資料夾：$PROJECT_DIR"; exit 1; }

# 尚未存在的路徑也要能算出實體絕對路徑（往上找到存在的祖先再接回來）
abs_path() {
  local p="$1" rest=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
  printf '%s%s' "$(cd "$p" && pwd -P)" "$rest"
}
SRC="$(cd "$PROJECT_DIR" && pwd -P)"
OUT="$(abs_path "$OUT_ARG")"
# 輸出到來源專案裡會污染專案（而且下次整理可能把自己也複製進去），建立目錄前就擋
case "$OUT/" in "$SRC"/*) echo "❌ 輸出目錄不可放在來源專案裡：$OUT"; exit 1;; esac
mkdir -p "$OUT"

echo "來源：$SRC"
echo "輸出：$OUT"

# ── 1. 白名單複製 ──────────────────────────────────────────────
cd "$SRC"
for entry in "${INCLUDE_PATHS[@]}"; do
  entry="${entry%/}"                       # 去掉結尾斜線，避免 BSD cp 只複製資料夾內容
  # 以換行當分隔做 glob 展開，路徑含空白也不會被拆開
  oldifs="$IFS"; IFS=$'\n'
  # shellcheck disable=SC2206
  matches=( $entry )
  IFS="$oldifs"
  found=0
  for m in "${matches[@]}"; do
    [ -e "$m" ] || continue
    found=1
    mkdir -p "$OUT/$(dirname "$m")"
    if [ -d "$m" ]; then
      cp -R "$m" "$OUT/$(dirname "$m")/"
    else
      cp "$m" "$OUT/$(dirname "$m")/"
    fi
  done
  [ $found -eq 1 ] || { echo "❌ 白名單項目不存在：$entry"; exit 1; }
done

# Finder 產生的 .DS_Store 無害但不該上線，直接移除（只動輸出目錄）
find "$OUT" -name .DS_Store -type f -delete

# ── 2. 上線前檢查（全部跑完再一起判定，一次看到所有問題）─────────────
fail=0
cd "$OUT"

exclude_args=()
for d in ${SCAN_EXCLUDE_DIRS[@]+"${SCAN_EXCLUDE_DIRS[@]}"}; do
  exclude_args+=("--exclude-dir=$d")
done

# 2a. 品牌／客戶字樣：文字檔（顯示行號與內容）
# 注意：grep 找不到會回傳 1，一律用 || true 收掉，只看輸出判定，避免 pipefail 誤報。
if [ -n "$BRAND_PATTERN" ]; then
  text_hits=$(grep -rnIiE ${exclude_args[@]+"${exclude_args[@]}"} -- "$BRAND_PATTERN" . || true)
  if [ -n "$text_hits" ]; then
    echo "❌ 文字檔發現品牌／客戶字樣："; echo "$text_hits"; fail=1
  fi
  # 2b. 二進位檔也要掃：圖片、字型的中繼資料（XMP、PNG tEXt 等）可能藏著原始檔名或客戶名
  bin_pattern="${BRAND_PATTERN_BINARY:-$BRAND_PATTERN}"
  bin_hits=$(LC_ALL=C grep -rlaiE ${exclude_args[@]+"${exclude_args[@]}"} -- "$bin_pattern" . || true)
  if [ -n "$bin_hits" ]; then
    echo "❌ 檔案內容（含圖片與字型中繼資料）發現品牌／客戶字樣："; echo "$bin_hits"; fail=1
  fi
else
  echo "（BRAND_PATTERN 留空，略過品牌字樣掃描）"
fi

# 2c. 不該部署的檔案與資料夾（以輸出目錄為根的相對路徑判斷，輸出路徑本身不會誤判）
find_expr=()
for n in "${FORBIDDEN_NAMES[@]}"; do
  [ ${#find_expr[@]} -gt 0 ] && find_expr+=(-o)
  find_expr+=(-iname "$n")
done
for d in "${FORBIDDEN_DIRS[@]}"; do
  [ ${#find_expr[@]} -gt 0 ] && find_expr+=(-o)
  find_expr+=(-path "*/$d" -o -path "*/$d/*")
done
bad_files=$(find . \( "${find_expr[@]}" \) -print)
if [ -n "$bad_files" ]; then
  echo "❌ 發現不該部署的檔案："; echo "$bad_files"; fail=1
fi

# 2d. 符號連結：可能指到專案外的檔案，一律不收
links=$(find . -type l -print)
if [ -n "$links" ]; then
  echo "❌ 發現符號連結（請改成實體檔案）："; echo "$links"; fail=1
fi

# 2e. Workers 靜態資源單檔上限 25 MiB
big=$(find . -type f -size +25M -print)
if [ -n "$big" ]; then
  echo "❌ 超過 Workers 靜態資源單檔 25 MiB 上限："; echo "$big"; fail=1
fi

# 2f. 檔案數上限（免費方案 20,000）
count=$(find . -type f | wc -l | tr -d ' ')
if [ "$count" -gt 20000 ]; then
  echo "❌ 檔案數 $count 超過 Workers 靜態資源 20,000 上限"; fail=1
fi

# 2g. 首頁必須存在，否則網址根目錄是 404
[ -f index.html ] || { echo "❌ 輸出目錄沒有 index.html"; fail=1; }

[ $fail -eq 0 ] || { echo "整理失敗，請修正後重跑（輸出目錄保留供檢查：$OUT）"; exit 1; }
echo "✅ 已整理到 $OUT：$count 個檔案，$(du -sh "$OUT" | cut -f1)"
