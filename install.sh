#!/bin/sh
# install.sh -- install the plugin-free Vim RTL IDE into $HOME (no root).
#
#   sh install.sh               install (backs up what it replaces)
#   sh install.sh --dry-run     show what would happen, change nothing
#   sh install.sh --home DIR    install into DIR instead of $HOME
#   sh install.sh --restore DIR restore a backup directory made earlier
#   sh install.sh --uninstall   remove installed files (keeps backups)
#   sh install.sh --help
#
# Installs:  $HOME/.vimrc  and  $HOME/.vim/{autoload/rtl,after/ftplugin,
#            ftdetect,dict,templates,doc}/...  (listed in the manifest
#            $HOME/.vim/rtl-ide.manifest).  Nothing else in ~/.vim is
#            touched.  Existing versions of exactly those files are copied
#            to  $HOME/.vim-rtl-ide-backup-<timestamp>/  before being
#            replaced.  Safe to run repeatedly.  No network access.

set -u

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
HOME_DIR=${HOME:-}
DRY_RUN=0
MODE=install
RESTORE_DIR=

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1 ;;
    --home) shift; HOME_DIR=$1 ;;
    --restore) MODE=restore; shift; RESTORE_DIR=$1 ;;
    --uninstall) MODE=uninstall ;;
    --help|-h)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$HOME_DIR" ] || { echo "HOME is not set; use --home DIR" >&2; exit 2; }
VIM_DIR="$HOME_DIR/.vim"
MANIFEST="$VIM_DIR/rtl-ide.manifest"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME_DIR/.vim-rtl-ide-backup-$STAMP"

say()  { printf '%s\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

# --------------------------------------------------------------- files ---
# Relative paths under the source tree -> relative paths under $HOME.
# (vimrc -> .vimrc ; vim/X -> .vim/X)
list_files() {
  printf 'vimrc\n'
  ( cd "$SRC_DIR/vim" && find autoload after ftdetect dict templates doc -type f | sort )
}
dest_of() {
  case "$1" in
    vimrc) printf '%s\n' "$HOME_DIR/.vimrc" ;;
    *)     printf '%s\n' "$VIM_DIR/$1" ;;
  esac
}
src_of() {
  case "$1" in
    vimrc) printf '%s\n' "$SRC_DIR/vimrc" ;;
    *)     printf '%s\n' "$SRC_DIR/vim/$1" ;;
  esac
}

# --------------------------------------------------------------- install ---
do_install() {
  say "RTL IDE installer"
  say "  source : $SRC_DIR"
  say "  target : $HOME_DIR  (vimrc -> $HOME_DIR/.vimrc, modules -> $VIM_DIR)"
  [ "$DRY_RUN" -eq 1 ] && say "  mode   : DRY RUN - nothing will be written"

  # sanity: source tree complete?
  for f in vimrc vim/autoload/rtl/lsp.vim vim/doc/rtl-ide.txt; do
    [ -f "$SRC_DIR/$f" ] || { say "missing $SRC_DIR/$f - run from the unpacked directory" >&2; exit 1; }
  done

  if command -v vim >/dev/null 2>&1; then
    say "  vim    : $(vim --version 2>/dev/null | head -n 1)"
  else
    say "  vim    : NOT FOUND in PATH (files will still be installed)"
  fi

  say ""
  say "Backing up files that will be replaced -> $BACKUP_DIR"
  need_backup=0
  for rel in $(list_files); do
    dst=$(dest_of "$rel")
    if [ -e "$dst" ]; then
      if cmp -s "$(src_of "$rel")" "$dst"; then
        continue    # identical: nothing to back up or replace
      fi
      need_backup=1
      case "$rel" in
        vimrc) bdst="$BACKUP_DIR/.vimrc" ;;
        *)     bdst="$BACKUP_DIR/.vim/$rel" ;;
      esac
      say "  backup $dst"
      run mkdir -p "$(dirname "$bdst")"
      run cp -p "$dst" "$bdst"
    fi
  done
  [ "$need_backup" -eq 1 ] || say "  (nothing to back up)"

  say ""
  say "Installing"
  : > "${TMPDIR:-/tmp}/rtl-ide-manifest.$$" 2>/dev/null || true
  newman="${TMPDIR:-/tmp}/rtl-ide-manifest.$$"
  for rel in $(list_files); do
    src=$(src_of "$rel"); dst=$(dest_of "$rel")
    printf '%s\n' "$dst" >> "$newman"
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
      say "  unchanged $dst"
      continue
    fi
    say "  install   $dst"
    run mkdir -p "$(dirname "$dst")"
    run cp "$src" "$dst"
    run chmod 0644 "$dst"
  done
  run mkdir -p "$VIM_DIR/undo"
  if [ "$DRY_RUN" -eq 0 ]; then
    mv "$newman" "$MANIFEST"
    say "  manifest  $MANIFEST"
  else
    rm -f "$newman"
    say "  [dry-run] manifest $MANIFEST"
  fi

  # help tags (needs vim; harmless if missing)
  if command -v vim >/dev/null 2>&1; then
    say ""
    say "Generating help tags"
    run vim -u NONE -i NONE -N -es -c "helptags $VIM_DIR/doc" -c "qa!"
  fi

  say ""
  say "Optional tools (none required):"
  for t in ctags verilator iverilog verible-verilog-lint verible-verilog-ls ghdl vhdl_ls; do
    if command -v "$t" >/dev/null 2>&1; then
      say "  [ok] $t -> $(command -v "$t")"
    else
      say "  [--] $t not in PATH"
    fi
  done
  say ""
  say "Done.  Start vim, open a .v file, run :RtlDoctor and :help rtl-ide."
  [ "$need_backup" -eq 1 ] && say "Rollback:  sh $SRC_DIR/install.sh --restore $BACKUP_DIR"
  return 0
}

# --------------------------------------------------------------- restore ---
do_restore() {
  [ -d "$RESTORE_DIR" ] || { say "no such backup directory: $RESTORE_DIR" >&2; exit 1; }
  say "Restoring from $RESTORE_DIR into $HOME_DIR"
  # remove what we installed, then put the backup copies back
  do_uninstall quiet
  ( cd "$RESTORE_DIR" && find . -type f ) | sed 's|^\./||' | while IFS= read -r rel; do
    say "  restore $HOME_DIR/$rel"
    run mkdir -p "$(dirname "$HOME_DIR/$rel")"
    run cp -p "$RESTORE_DIR/$rel" "$HOME_DIR/$rel"
  done
  say "Done."
}

# ------------------------------------------------------------- uninstall ---
do_uninstall() {
  quiet=${1:-}
  if [ ! -f "$MANIFEST" ]; then
    [ -n "$quiet" ] || say "no manifest at $MANIFEST; nothing to uninstall"
    return 0
  fi
  say "Removing files listed in $MANIFEST"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      "$HOME_DIR"/*) ;;
      *) say "  skip (outside home): $f"; continue ;;
    esac
    if [ -f "$f" ]; then
      say "  remove $f"
      run rm -f "$f"
    fi
  done < "$MANIFEST"
  run rm -f "$MANIFEST" "$VIM_DIR/doc/tags"
  # drop now-empty directories we created (never ~/.vim itself)
  for d in autoload/rtl after/ftplugin after ftdetect dict templates/verilog templates/vhdl templates doc; do
    [ -d "$VIM_DIR/$d" ] && run rmdir "$VIM_DIR/$d" 2>/dev/null
  done
  [ -n "$quiet" ] || say "Done.  Backups in $HOME_DIR/.vim-rtl-ide-backup-* were kept."
  return 0
}

case "$MODE" in
  install)   do_install ;;
  restore)   do_restore ;;
  uninstall) do_uninstall ;;
esac
