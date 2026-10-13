#!/usr/bin/env bash
# =====================================================================
# Сборка итогового документа для Google Docs:
#   docs/report/report.md  ->  DOCX (для импорта в Google Docs)
#                          ->  PDF  (pandoc + xelatex, кириллица)
#   в двух ориентациях: портретной и ландшафтной (обе версии сохраняются).
#
# Файлы сохраняются в docs/tmp/report_build/ (каталог не коммитится):
#   Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault.docx            — портрет
#   Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault.pdf             — портрет
#   Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault_landscape.docx  — ландшафт
#   Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault_landscape.pdf   — ландшафт
#
# Запуск: bash scripts/build_report.sh [all|portrait|landscape]   (по умолчанию all)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
NAME="Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault"
SRC=docs/report/report.md
OUT=docs/tmp/report_build
mkdir -p "$OUT"

if ! command -v pandoc >/dev/null; then
    echo "pandoc не найден: brew install pandoc" >&2
    exit 1
fi
if ! command -v xelatex >/dev/null; then
    echo "внимание: xelatex не найден — PDF собираться не будет (DOCX можно загрузить в Google Docs)" >&2
fi

COMMON=(--from markdown+pipe_tables+raw_html
        --toc --toc-depth=2
        --resource-path=docs/report:docs/report/diagrams
        --standalone)

PDF_COMMON=(--pdf-engine=xelatex
            -V mainfont="Times New Roman"
            -V monofont="Menlo"
            -V fontsize=11pt
            -V colorlinks=true)

build_pdf() {                       # build_pdf <файл> <опции geometry>
    local target="$1" geometry="$2"
    if command -v xelatex >/dev/null; then
        pandoc "$SRC" "${COMMON[@]}" "${PDF_COMMON[@]}" -V "geometry:${geometry}" -o "$target"
        echo "  создан $target"
    fi
}

if [ "$MODE" = "all" ] || [ "$MODE" = "portrait" ]; then
    echo "=== Портретная версия ==="
    pandoc "$SRC" "${COMMON[@]}" -o "$OUT/${NAME}.docx"
    echo "  создан $OUT/${NAME}.docx"
    build_pdf "$OUT/${NAME}.pdf" "a4paper,margin=2cm"
fi

if [ "$MODE" = "all" ] || [ "$MODE" = "landscape" ]; then
    echo "=== Ландшафтная версия ==="
    pandoc "$SRC" "${COMMON[@]}" -o "$OUT/${NAME}_landscape.docx"
    python3 scripts/make_landscape_docx.py "$OUT/${NAME}_landscape.docx"
    echo "  создан $OUT/${NAME}_landscape.docx"
    build_pdf "$OUT/${NAME}_landscape.pdf" "a4paper,landscape,margin=1.5cm"
fi

echo
echo "=== Контроль собранных артефактов ==="
python3 scripts/check_report_artifacts.py "$OUT"
echo
echo "Загрузите нужную версию DOCX в Google Docs (Файл -> Импорт) либо приложите PDF."

