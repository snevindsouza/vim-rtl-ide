#!/bin/sh
# tests/run_tests.sh -- repeatable verification of the RTL IDE.
#
#   sh tests/run_tests.sh            run everything in a throw-away $HOME
#   KEEP=1 sh tests/run_tests.sh     keep the temporary directory
#
# What it does:
#   T13  installs into a temporary HOME (whose path contains a space) that
#        already has a fake ~/.vimrc, and checks the backup was made and
#        the manifest written, then that --dry-run changes nothing.
#   T01-T12  run tests/rtl_test.vim in that HOME with a headless Vim
#        (vim -es).  Results are printed; a SKIP means the optional tool
#        the test needs is not installed here.
#
# Interactive checks that cannot be automated are listed at the end.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rtl-ide-test.XXXXXX") || exit 1
FAKEHOME="$TMP/home with space"
PROJ="$FAKEHOME/proj dir"
status=0

cleanup() { [ "${KEEP:-0}" = 1 ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

echo "== RTL IDE test run  ($(date))"
echo "   temp HOME: $FAKEHOME"

if ! command -v vim >/dev/null 2>&1; then
  echo "FAIL ---- vim is not in PATH; cannot run T01-T12"
  exit 1
fi
echo "   $(vim --version | head -n 1)"

# ------------------------------------------------------------------ T13 ---
mkdir -p "$FAKEHOME/.vim/plugin-unrelated"
printf '" pre-existing user vimrc\nset nocompatible\n' > "$FAKEHOME/.vimrc"
printf '" unrelated file that must survive\n' > "$FAKEHOME/.vim/plugin-unrelated/keep.vim"

sh "$ROOT/install.sh" --home "$FAKEHOME" > "$TMP/install.log" 2>&1
rc=$?
bk=$(ls -d "$FAKEHOME"/.vim-rtl-ide-backup-* 2>/dev/null | head -n 1)
if [ $rc -eq 0 ] && [ -n "$bk" ] && grep -q 'pre-existing user vimrc' "$bk/.vimrc" \
   && [ -f "$FAKEHOME/.vim/rtl-ide.manifest" ] \
   && grep -q 'plugin-free Vim IDE' "$FAKEHOME/.vimrc" \
   && [ -f "$FAKEHOME/.vim/plugin-unrelated/keep.vim" ]; then
  echo "PASS T13  installer backs up ~/.vimrc, writes manifest, leaves unrelated files ($bk)"
else
  echo "FAIL T13  installer backup/manifest check (rc=$rc, backup='$bk'); see $TMP/install.log"
  status=1
fi
# second run must be a no-op, dry-run must not write
sh "$ROOT/install.sh" --home "$FAKEHOME" > "$TMP/install2.log" 2>&1
n_backups=$(ls -d "$FAKEHOME"/.vim-rtl-ide-backup-* 2>/dev/null | wc -l)
printf '" changed\n' >> "$FAKEHOME/.vimrc"
sum_before=$(cat "$FAKEHOME/.vimrc" | wc -c)
sh "$ROOT/install.sh" --home "$FAKEHOME" --dry-run > "$TMP/install3.log" 2>&1
sum_after=$(cat "$FAKEHOME/.vimrc" | wc -c)
if [ "$n_backups" -eq 1 ] && [ "$sum_before" -eq "$sum_after" ] && grep -q 'dry-run' "$TMP/install3.log"; then
  echo "PASS T13b repeated install is idempotent (1 backup dir), --dry-run writes nothing"
else
  echo "FAIL T13b idempotence/dry-run (backups=$n_backups, before=$sum_before after=$sum_after)"
  status=1
fi
# put the real vimrc back for the vim tests
sh "$ROOT/install.sh" --home "$FAKEHOME" > /dev/null 2>&1

# ------------------------------------------------------------- T01..T12 ---
mkdir -p "$PROJ"
cp -R "$HERE/rtl/." "$PROJ/"
OUT="$TMP/results.txt"
NOTERM=
vim --help 2>&1 | grep -q -- '--not-a-term' && NOTERM=--not-a-term
HOME="$FAKEHOME" vim -N -i NONE $NOTERM -u "$FAKEHOME/.vimrc" -es \
  -c "let g:rtl_test_out='$OUT'" \
  -c "let g:rtl_test_proj='$PROJ'" \
  -S "$HERE/rtl_test.vim" > "$TMP/vim.log" 2>&1
vrc=$?
if [ -f "$OUT" ]; then
  cat "$OUT"
  if grep -q '^FAIL' "$OUT"; then status=1; fi
else
  echo "FAIL ---- vim did not write results (exit $vrc); log:"
  cat "$TMP/vim.log"
  status=1
fi

# ------------------------------------------------------------- summary ---
echo ""
echo "== Not automated (do these once, interactively):"
echo "   - open proj/top.v, type  <Space>ii  on 'counter' -> instantiation inserted"
echo "   - in insert mode after  u_counter ( .  press <Tab> -> port menu"
echo "   - <Space>p, paste indented code from your PC, <Esc> -> indentation kept"
echo "   - with verible-verilog-ls installed: K on a signal, <Space>gd, :RtlLspStatus"
echo "   - type 'always @* begin<CR>' in a .v file -> 'end' appears once, 'u' undoes all"
[ $status -eq 0 ] && echo "== ALL AUTOMATED TESTS PASSED" || echo "== SOME TESTS FAILED (see above)"
exit $status
