" autoload/rtl/project.vim -- project root, .rtlproject config, file list
"
" Root detection: walk upward from the current file's directory looking for
" one of g:rtl_root_markers.  Nearest match wins.  Fallback: the file's own
" directory (or the working directory for an unnamed buffer).
"
" Optional config file <root>/.rtlproject  (key = value, '#' comments).
" It is PARSED, never :source'd, so a project file cannot run code.
"
"   src_dirs      = rtl, tb, lib           (relative to root; default: root)
"   extensions    = v,sv,svh,vh,vhd,vhdl   (default: g:rtl_extensions)
"   exclude_dirs  = .git,build,obj_dir     (added to g:rtl_exclude_dirs)
"   filelist      = sim/filelist.f         (used by :RtlLintProject)
"   include_dirs  = include, rtl/common    (+incdir+ for lint, 'path' for gf)
"   defines       = SIM, WIDTH=8           (+define+ for lint)
"   top           = top_module             (--top-module for verilator)
"   lint_tool     = verilator | iverilog | verible | ghdl
"   verilator_args = -Wall -Wno-fatal
"   iverilog_args  = -g2012
"   verible_lint_args = --rules=-line-length
"   ghdl_args      = --std=08
"   lsp_command    = verible-verilog-ls --rules_config_search
"   max_files      = 20000
"
" Global settings (set in ~/.vimrc.local before use):
"   g:rtl_root_markers   list of marker files/dirs
"   g:rtl_extensions     list of extensions scanned
"   g:rtl_exclude_dirs   list of directory names never descended into
"   g:rtl_cache_seconds  seconds before the file list is re-scanned

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_root_markers  = get(g:, 'rtl_root_markers',
      \ ['.rtlproject', '.git', '.hg', '.svn', 'filelist.f', 'rtl', 'hdl'])
let g:rtl_extensions    = get(g:, 'rtl_extensions',
      \ ['v', 'vh', 'sv', 'svh', 'vhd', 'vhdl'])
let g:rtl_exclude_dirs  = get(g:, 'rtl_exclude_dirs',
      \ ['.git', '.hg', '.svn', 'obj_dir', 'build', 'work', 'sim_build',
      \  'xsim.dir', 'node_modules', '.cache', 'csrc', 'simv.daidir',
      \  'INCA_libs', 'xcelium.d', '__pycache__'])
let g:rtl_cache_seconds = get(g:, 'rtl_cache_seconds', 300)
let g:rtl_max_files     = get(g:, 'rtl_max_files', 20000)

let s:root_cache = {}      " dir -> root
let s:cfg_cache  = {}      " root -> {mtime, cfg}
let s:file_cache = {}      " root -> {time, files}

" ---------------------------------------------------------------- Root ---
function! rtl#project#Root(...) abort
  if a:0 && !empty(a:1)
    let dir = fnamemodify(a:1, ':p:h')
  elseif !empty(expand('%:p')) && &buftype ==# ''
    let dir = expand('%:p:h')
  else
    let dir = getcwd()
  endif
  if exists('b:rtl_root') && get(b:, 'rtl_root_dir', '') ==# dir
    return b:rtl_root
  endif
  if has_key(s:root_cache, dir)
    let root = s:root_cache[dir]
  else
    let root = s:FindRoot(dir)
    let s:root_cache[dir] = root
  endif
  if &buftype ==# ''
    let b:rtl_root = root
    let b:rtl_root_dir = dir
  endif
  return root
endfunction

function! s:FindRoot(dir) abort
  let best = ''
  let best_len = -1
  for marker in g:rtl_root_markers
    " findfile/finddir with ';' search upward.  Escape spaces for the
    " path argument (it is a comma/space separated list).
    let esc = escape(a:dir, ' ,;')
    let hit = findfile(marker, esc . ';')
    if empty(hit)
      let hit = finddir(marker, esc . ';')
    endif
    if !empty(hit)
      " ':p' of a directory ends in '/', strip it; the marker's parent is root
      let abs = substitute(fnamemodify(hit, ':p'), '/$', '', '')
      let cand = fnamemodify(abs, ':h')
      " nearest (longest path) marker wins
      if len(cand) > best_len
        let best = cand
        let best_len = len(cand)
      endif
    endif
  endfor
  return empty(best) ? a:dir : best
endfunction

" -------------------------------------------------------------- Config ---
function! rtl#project#Config() abort
  let root = rtl#project#Root()
  let path = root . '/.rtlproject'
  let mtime = getftime(path)
  if has_key(s:cfg_cache, root) && s:cfg_cache[root].mtime == mtime
    return s:cfg_cache[root].cfg
  endif
  let cfg = {}
  if mtime >= 0 && filereadable(path)
    for line in readfile(path)
      let line = substitute(line, '\s*#.*$', '', '')
      let m = matchlist(line, '^\s*\([A-Za-z_][A-Za-z0-9_]*\)\s*[=:]\s*\(.*\S\)\s*$')
      if !empty(m)
        let cfg[tolower(m[1])] = m[2]
      endif
    endfor
  endif
  let s:cfg_cache[root] = {'mtime': mtime, 'cfg': cfg}
  return cfg
endfunction

" Comma/space separated config value -> list (empty list if unset)
function! rtl#project#ConfigList(key, ...) abort
  let cfg = rtl#project#Config()
  let raw = get(cfg, a:key, '')
  if empty(raw)
    return a:0 ? a:1 : []
  endif
  return filter(split(raw, '\s*,\s*\|\s\+'), '!empty(v:val)')
endfunction

function! rtl#project#ConfigGet(key, default) abort
  return get(rtl#project#Config(), a:key, a:default)
endfunction

" Directories to scan (absolute), existing ones only.
function! rtl#project#SrcDirs() abort
  let root = rtl#project#Root()
  let dirs = []
  for d in rtl#project#ConfigList('src_dirs', ['.'])
    let abs = d =~# '^/' ? d : root . '/' . d
    let abs = simplify(abs)
    if isdirectory(abs)
      call add(dirs, substitute(abs, '/$', '', ''))
    endif
  endfor
  return empty(dirs) ? [root] : dirs
endfunction

function! rtl#project#IncludeDirs() abort
  let root = rtl#project#Root()
  let out = []
  for d in rtl#project#ConfigList('include_dirs')
    call add(out, simplify(d =~# '^/' ? d : root . '/' . d))
  endfor
  return out
endfunction

function! rtl#project#Extensions() abort
  return rtl#project#ConfigList('extensions', g:rtl_extensions)
endfunction

function! rtl#project#ExcludeDirs() abort
  return g:rtl_exclude_dirs + rtl#project#ConfigList('exclude_dirs')
endfunction

" Absolute path of the project filelist (.f), or '' if none.
function! rtl#project#Filelist() abort
  let root = rtl#project#Root()
  let fl = rtl#project#ConfigGet('filelist', '')
  if !empty(fl)
    let fl = fl =~# '^/' ? fl : root . '/' . fl
    return filereadable(fl) ? fl : ''
  endif
  for cand in ['filelist.f', 'files.f', 'sources.f', 'sim/filelist.f', 'rtl/filelist.f']
    if filereadable(root . '/' . cand)
      return root . '/' . cand
    endif
  endfor
  return ''
endfunction

" ----------------------------------------------------------- File list ---
" Cached, bounded enumeration of RTL sources.  Never called per keystroke:
" completion uses tags / buffer scans; this is used by :RtlTags, :RtlGrep,
" :RtlFind and project lint.
function! rtl#project#Files(...) abort
  let force = a:0 ? a:1 : 0
  let root = rtl#project#Root()
  let now = localtime()
  if !force && has_key(s:file_cache, root)
        \ && now - s:file_cache[root].time < g:rtl_cache_seconds
    return s:file_cache[root].files
  endif
  let files = s:Scan()
  let s:file_cache[root] = {'time': now, 'files': files}
  return files
endfunction

function! rtl#project#Refresh() abort
  let files = rtl#project#Files(1)
  if exists('b:rtl_root') | unlet b:rtl_root | endif
  let s:root_cache = {}
  let s:cfg_cache = {}
  echo 'RTL: project ' . rtl#project#Root() . ' - ' . len(files) . ' source files'
endfunction

function! s:Scan() abort
  let dirs = rtl#project#SrcDirs()
  let exts = rtl#project#Extensions()
  let excl = rtl#project#ExcludeDirs()
  let maxf = str2nr(rtl#project#ConfigGet('max_files', g:rtl_max_files))
  let files = []
  if executable('find') && !has('win32')
    " POSIX find with -prune for excluded dirs.  Every argument is
    " shell-escaped so spaces in paths are safe.
    let cmd = 'find'
    for d in dirs
      let cmd .= ' ' . shellescape(d)
    endfor
    let cmd .= ' \( '
    let first = 1
    for e in excl
      let cmd .= (first ? '' : ' -o ') . '-name ' . shellescape(e)
      let first = 0
    endfor
    let cmd .= ' \) -prune -o -type f \( '
    let first = 1
    for e in exts
      let cmd .= (first ? '' : ' -o ') . '-name ' . shellescape('*.' . e)
      let first = 0
    endfor
    let cmd .= ' \) -print'
    let out = system(cmd)
    if !v:shell_error
      let files = split(out, '\n')
    endif
  endif
  if empty(files)
    " Pure-Vim fallback: glob with ** (depth limited by Vim to 100 levels)
    for d in dirs
      for e in exts
        let hits = split(glob(escape(d, '[]*?{}') . '/**/*.' . e, 1), '\n')
        for h in hits
          if !s:Excluded(h, excl)
            call add(files, h)
          endif
        endfor
      endfor
    endfor
  endif
  if len(files) > maxf
    echohl WarningMsg
    echomsg 'RTL: project has ' . len(files) . ' files; truncated to ' . maxf
          \ . ' (set max_files in .rtlproject or g:rtl_max_files)'
    echohl None
    let files = files[: maxf - 1]
  endif
  return sort(files)
endfunction

function! s:Excluded(path, excl) abort
  for part in split(a:path, '/')
    if index(a:excl, part) >= 0
      return 1
    endif
  endfor
  return 0
endfunction

" ------------------------------------------------------- :RtlFind etc. ---
function! rtl#project#CompleteFile(lead, line, pos) abort
  let lead = tolower(a:lead)
  let out = []
  for f in rtl#project#Files()
    if stridx(tolower(fnamemodify(f, ':t')), lead) >= 0
      call add(out, fnamemodify(f, ':t'))
    endif
  endfor
  return out
endfunction

function! rtl#project#Find(name) abort
  let name = a:name
  let hits = filter(copy(rtl#project#Files()),
        \ 'fnamemodify(v:val, ":t") ==# name')
  if empty(hits)
    let hits = filter(copy(rtl#project#Files()),
          \ 'stridx(tolower(fnamemodify(v:val, ":t")), tolower(name)) >= 0')
  endif
  if empty(hits)
    echohl WarningMsg | echomsg 'RTL: no project file matches "' . name . '"' | echohl None
    return
  endif
  if len(hits) == 1
    execute 'edit ' . fnameescape(hits[0])
    return
  endif
  let items = map(copy(hits), '{"filename": v:val, "lnum": 1, "text": fnamemodify(v:val, ":t")}')
  call setqflist(items, 'r')
  copen
endfunction

function! rtl#project#ListFiles() abort
  let files = rtl#project#Files()
  let items = map(copy(files), '{"filename": v:val, "lnum": 1, "text": fnamemodify(v:val, ":t")}')
  call setqflist(items, 'r')
  copen
  echo 'RTL: ' . len(files) . ' source files under ' . rtl#project#Root()
endfunction

" Toggle a netrw tree rooted at the project root.
function! rtl#project#Explore() abort
  let root = rtl#project#Root()
  for w in range(1, winnr('$'))
    if getbufvar(winbufnr(w), '&filetype') ==# 'netrw'
      execute w . 'wincmd w'
      close
      return
    endif
  endfor
  execute 'Lexplore ' . fnameescape(root)
endfunction

" Set 'path' for gf / :find from project dirs.  Called by ftplugins.
function! rtl#project#SetPath() abort
  let dirs = ['.', expand('%:p:h')] + rtl#project#IncludeDirs() + rtl#project#SrcDirs()
  let parts = []
  for d in dirs
    call add(parts, escape(d, ' ,'))
  endfor
  let &l:path = join(parts, ',')
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
