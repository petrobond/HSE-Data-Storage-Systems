#!/usr/bin/env bash
# =====================================================================
# Сборка итогового документа для Google Docs:
#   docs/report/report.md  ->  DOCX (основной формат для Google Docs)
#                          ->  PDF  (через pandoc + xelatex, кириллица)
#
# Файлы сохраняются в docs/tmp/report_build/ (каталог не коммитится).
# Запуск: bash scripts/build_report.sh   (или make report)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault"
SRC=docs/report/report.md
OUT=docs/tmp/report_build
mkdir -p "$OUT"

if ! command -v pandoc >/dev/null; then
    echo "pandoc не найден: brew install pandoc" >&2
    exit 1
fi

echo "=== Сборка DOCX ==="
pandoc "$SRC" \
    --from markdown+pipe_tables+raw_html \
    --toc --toc-depth=2 \
    --resource-path=docs/report:docs/report/diagrams \
    --standalone \
    -o "$OUT/${NAME}.docx"
echo "  создан $OUT/${NAME}.docx"

echo "=== Сборка PDF (xelatex, кириллица) ==="
if command -v xelatex >/dev/null; then
    pandoc "$SRC" \
        --pdf-engine=xelatex \
        -V mainfont="Times New Roman" \
        -V monofont="Menlo" \
        -V fontsize=11pt \
        -V geometry:a4paper,margin=2cm \
        -V colorlinks=true \
        --toc --toc-depth=2 \
        --resource-path=docs/report:docs/report/diagrams \
        --standalone \
        -o "$OUT/${NAME}.pdf"
    echo "  создан $OUT/${NAME}.pdf"
else
    echo "  xelatex не найден — PDF не собран (DOCX можно загрузить в Google Docs)"
fi

echo
echo "Готово. Загрузите DOCX в Google Docs (Файл -> Импорт) либо PDF."
echo "Каталог сборки: $OUT"
ls -la "$OUT"
