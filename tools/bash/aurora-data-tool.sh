#!/usr/bin/env bash
# Aurora load-plan helper for RHEL 9.8.
# generate, tables, and dumpargs read the same text plan as the Windows tool.
# Dump, CSV backup, delete, load, prepare, and cleanup are the PowerShell actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AWK_FILE="$ROOT/tools/bash/aurora-gen.awk"

usage() {
    cat <<'EOF'
Usage:
  aurora-data-tool.sh selftest
  aurora-data-tool.sh generate --plan FILE [--out DIR] [--table NAME]
  aurora-data-tool.sh tables --plan FILE
  aurora-data-tool.sh dumpargs --plan FILE --defaults PATH --result PATH

generate writes deterministic CSV for JMeter load data.
dumpargs prints one mysqldump argument per line.
MySQL sessions (dump, backup, delete, load, cleanup) run with:
  powershell -File tools/ps/Invoke-AuroraDataTool.ps1
EOF
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

action="$1"
shift

plan=""
out=""
table=""
defaults=""
result=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            plan="${2:-}"
            shift 2
            ;;
        --out)
            out="${2:-}"
            shift 2
            ;;
        --table)
            table="${2:-}"
            shift 2
            ;;
        --defaults)
            defaults="${2:-}"
            shift 2
            ;;
        --result)
            result="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

export LC_ALL=C

run_awk() {
    awk -f "$AWK_FILE" "$@"
}

case "$action" in
    selftest)
        run_awk -v mode=selftest
        ;;
    tables)
        [[ -n "$plan" && -f "$plan" ]] || die "--plan must be an existing file"
        run_awk -v mode=tables "$plan"
        ;;
    dumpargs)
        [[ -n "$plan" && -f "$plan" ]] || die "--plan must be an existing file"
        [[ -n "$defaults" && -n "$result" ]] || die "dumpargs requires --defaults and --result"
        run_awk -v mode=dumpargs -v defaults="$defaults" -v result="$result" "$plan"
        ;;
    generate)
        [[ -n "$plan" && -f "$plan" ]] || die "--plan must be an existing file"
        if [[ -z "$out" ]]; then
            if [[ -n "$table" ]]; then
                run_awk -v mode=csv -v only="$table" "$plan"
            else
                run_awk -v mode=csv "$plan"
            fi
            exit 0
        fi
        mkdir -p "$out"
        write_one() {
            local name="$1"
            [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || die "table name is not a safe file name: $name"
            run_awk -v mode=csv -v only="$name" "$plan" > "$out/$name.csv"
        }
        if [[ -n "$table" ]]; then
            write_one "$table"
        else
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                write_one "$name"
            done < <(run_awk -v mode=tables "$plan")
        fi
        ;;
    *)
        die "Unknown action: $action. On RHEL this script generates CSV and mysqldump arguments. Database changes use the PowerShell tool."
        ;;
esac
