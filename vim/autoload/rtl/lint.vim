" autoload/rtl/lint.vim -- external diagnostics into the quickfix list
"
" Tools (all optional, all auto-detected with executable()):
"   verilator  --lint-only       Verilog/SV: syntax, elaboration-level lint
"                                (undeclared identifiers, width, port
"                                connection mismatches, unused/undriven ...)
"   iverilog   -t null           Verilog/SV: parse + elaborate, no output
"   verible-verilog-lint         Verilog/SV: syntax + style lint (parser only,
"                                no elaboration => no undeclared-identifier
"                                or port-width checks)
"   ghdl       -s                VHDL: syntax check only (no analysis)
"
" What these report is what the tool implements; nothing here is a
" substitute for simulation, synthesis or a full lint/CDC flow.
"
" Asynchronous when Vim has +job; synchronous system() otherwise.

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_lint_tool       = get(g:, 'rtl_lint_tool', '')    " '' = auto
let g:rtl_verilator_args  = get(g:, 'rtl_verilator_args', '-Wall -Wno-fatal -Wno-DECLFILENAME')
let g:rtl_iverilog_args   = get(g:, 'rtl_iverilog_args', '-g2012')
let g:rtl_verible_lint_args = get(g:, 'rtl_verible_lint_args', '')
let g:rtl_ghdl_args       = get(g:, 'rtl_ghdl_args', '--std=08')
let g:rtl_verilator_exe   = get(g:, 'rtl_verilator_exe', 'verilator')
let g:rtl_iverilog_exe    = get(g:, 'rtl_iverilog_exe', 'iverilog')
let g:rtl_verible_lint_exe = get(g:, 'rtl_verible_lint_exe', 'verible-verilog-lint')
let g:rtl_ghdl_exe        = get(g:, 'rtl_ghdl_exe', 'ghdl')

let s:tools = {
      \ 'verilator': {'exe': 'rtl_verilator_exe', 'fts': ['verilog', 'systemverilog'],
      \   'efm': '%-G%%Error: Exiting due to%.%#,%-G%%Error: Command Failed%.%#,'
      \        . '%%%trror-%\w%\+: %f:%l:%c: %m,%%%trror: %f:%l:%c: %m,'
      \        . '%%%trror-%\w%\+: %f:%l: %m,%%%trror: %f:%l: %m,'
      \        . '%%%tarning-%\w%\+: %f:%l:%c: %m,%%%tarning: %f:%l:%c: %m,'
      \        . '%%%tarning-%\w%\+: %f:%l: %m,%%%tarning: %f:%l: %m,'
      \        . '%%%trror: %m,%-G%.%#'},
      \ 'iverilog': {'exe': 'rtl_iverilog_exe', 'fts': ['verilog', 'systemverilog'],
      \   'efm': '%-GI give up.,%-G%\d%\+ error(s) during elaboration.,'
      \        . '%f:%l: %tarning: %m,%f:%l: %trror: %m,%f:%l: %m,%-G%.%#'},
      \ 'verible': {'exe': 'rtl_verible_lint_exe', 'fts': ['verilog', 'systemverilog'],
      \   'efm': '%f:%l:%c-%*[0-9]: %m,%f:%l:%c: %m,%-G%.%#', 'warn_default': 1},
      \ 'ghdl': {'exe': 'rtl_ghdl_exe', 'fts': ['vhdl'],
      \   'efm': '%f:%l:%c:%*[ ]%trror: %m,%f:%l:%c:%*[ ]%tarning: %m,%f:%l:%c: %m,%-G%.%#'},
      \ }

let s:job = {}          " running lint job (one at a time)
let s:signs = {}        " bufnr -> [sign ids]
let s:next_sign = 7000
let s:signs_defined = 0

" ------------------------------------------------------------ helpers ---
function! rtl#lint#ToolExe(tool) abort
  if !has_key(s:tools, a:tool) | return '' | endif
  let exe = get(g:, s:tools[a:tool].exe, a:tool)
  return executable(exe) ? exe : ''
endfunction

function! rtl#lint#Available(ft) abort
  let out = []
  for t in ['verilator', 'iverilog', 'verible', 'ghdl']
    if index(s:tools[t].fts, a:ft) >= 0 && !empty(rtl#lint#ToolExe(t))
      call add(out, t)
    endif
  endfor
  return out
endfunction

function! rtl#lint#CompleteTool(lead, line, pos) abort
  return filter(['verilator', 'iverilog', 'verible', 'ghdl'], 'v:val =~# "^" . a:lead')
endfunction

function! s:ChooseTool(explicit, ft) abort
  let want = !empty(a:explicit) ? a:explicit : rtl#project#ConfigGet('lint_tool', g:rtl_lint_tool)
  if !empty(want)
    if !has_key(s:tools, want)
      echohl ErrorMsg | echomsg 'RTL: unknown lint tool "' . want . '" (verilator|iverilog|verible|ghdl)' | echohl None
      return ''
    endif
    if empty(rtl#lint#ToolExe(want))
      echohl ErrorMsg
      echomsg 'RTL: ' . want . ' not found in $PATH (set g:rtl_' . want . '_exe or PATH, see :RtlDoctor)'
      echohl None
      return ''
    endif
    if index(s:tools[want].fts, a:ft) < 0
      echohl ErrorMsg | echomsg 'RTL: ' . want . ' does not handle filetype ' . a:ft | echohl None
      return ''
    endif
    return want
  endif
  let avail = rtl#lint#Available(a:ft)
  if empty(avail)
    echohl WarningMsg
    echomsg 'RTL: no lint tool found for ' . a:ft . ' (install verilator, iverilog, verible or ghdl; see :RtlDoctor)'
    echohl None
    return ''
  endif
  return avail[0]
endfunction

function! s:SplitArgs(str) abort
  return filter(split(a:str, '\s\+'), '!empty(v:val)')
endfunction

" Command as an argument LIST (no shell quoting needed for job_start).
function! s:BuildCmd(tool, project) abort
  let exe = rtl#lint#ToolExe(a:tool)
  let root = rtl#project#Root()
  let cfg = rtl#project#Config()
  let file = expand('%:p')
  let incs = rtl#project#IncludeDirs()
  if !a:project
    " `include "x.vh" next to the file being linted must resolve
    call insert(incs, fnamemodify(file, ':h'))
  endif
  let defs = rtl#project#ConfigList('defines')
  let filelist = a:project ? rtl#project#Filelist() : ''
  let files = []
  if a:project && empty(filelist)
    let files = rtl#project#Files()
    if a:tool ==# 'ghdl'
      call filter(files, 'v:val =~? "\\.vhdl\\?$"')
    else
      call filter(files, 'v:val =~? "\\.\\(v\\|sv\\|vh\\|svh\\)$"')
    endif
  endif
  if a:tool ==# 'verilator'
    let cmd = [exe, '--lint-only'] + s:SplitArgs(get(cfg, 'verilator_args', g:rtl_verilator_args))
    for d in incs | call add(cmd, '+incdir+' . d) | endfor
    for d in defs | call add(cmd, '+define+' . d) | endfor
    let top = get(cfg, 'top', '')
    if a:project && !empty(top)
      let cmd += ['--top-module', top]
    endif
    if !empty(filelist)
      let cmd += ['-f', filelist]
    elseif a:project
      let cmd += files
    else
      let cmd += [file]
    endif
  elseif a:tool ==# 'iverilog'
    let cmd = [exe, '-t', 'null'] + s:SplitArgs(get(cfg, 'iverilog_args', g:rtl_iverilog_args))
    for d in incs | call add(cmd, '-I' . d) | endfor
    for d in defs | call add(cmd, '-D' . d) | endfor
    let top = get(cfg, 'top', '')
    if a:project && !empty(top)
      let cmd += ['-s', top]
    endif
    if !empty(filelist)
      let cmd += ['-f', filelist]
    elseif a:project
      let cmd += files
    else
      let cmd += [file]
    endif
  elseif a:tool ==# 'verible'
    let cmd = [exe] + s:SplitArgs(get(cfg, 'verible_lint_args', g:rtl_verible_lint_args))
    if a:project
      if !empty(filelist)
        " verible-verilog-lint takes files, not .f lists: expand the list
        let files = rtl#lint#ReadFilelist(filelist)
      endif
      let cmd += files
    else
      let cmd += [file]
    endif
  elseif a:tool ==# 'ghdl'
    let cmd = [exe, '-s'] + s:SplitArgs(get(cfg, 'ghdl_args', g:rtl_ghdl_args))
    if a:project
      let cmd += empty(filelist) ? files : rtl#lint#ReadFilelist(filelist)
    else
      let cmd += [file]
    endif
  else
    return []
  endif
  return cmd
endfunction

" Expand a simulator .f file into absolute source paths (handles -f
" nesting, +incdir+/+define+/-y skipped, blank/comment lines skipped).
function! rtl#lint#ReadFilelist(path, ...) abort
  let depth = a:0 ? a:1 : 0
  if depth > 8 || !filereadable(a:path) | return [] | endif
  let base = fnamemodify(a:path, ':p:h')
  let out = []
  let i = 0
  let lines = readfile(a:path)
  while i < len(lines)
    let l = substitute(lines[i], '\s*\%(//\|#\).*$', '', '')
    let l = substitute(l, '^\s\+\|\s\+$', '', 'g')
    let i += 1
    if empty(l) | continue | endif
    if l =~# '^-f\s\+'
      let sub = substitute(l, '^-f\s\+', '', '')
      let sub = sub =~# '^/' ? sub : base . '/' . sub
      let out += rtl#lint#ReadFilelist(sub, depth + 1)
    elseif l =~# '^[+-]'
      continue
    else
      let l = substitute(l, '\$\(\w\+\)', '\=getenv(submatch(1))', 'g')
      call add(out, l =~# '^/' ? l : simplify(base . '/' . l))
    endif
  endwhile
  return out
endfunction

" ----------------------------------------------------------------- run ---
function! rtl#lint#Run(tool, project) abort
  let ft = &filetype
  if ft !~# '^\%(verilog\|systemverilog\|vhdl\)$'
    echohl WarningMsg | echomsg 'RTL: lint works in verilog/systemverilog/vhdl buffers' | echohl None
    return
  endif
  if &modified
    if &autowrite || &autowriteall
      silent! write
    else
      echohl WarningMsg | echomsg 'RTL: buffer not saved; lint runs on the file on disk' | echohl None
    endif
  endif
  let tool = s:ChooseTool(a:tool, ft)
  if empty(tool) | return | endif
  let cmd = s:BuildCmd(tool, a:project)
  if empty(cmd) | return | endif
  let efm = s:tools[tool].efm
  let title = (a:project ? 'project' : fnamemodify(expand('%'), ':t')) . ' [' . tool . ']'
  let root = rtl#project#Root()
  if has('job') && has('channel')
    if !empty(s:job) && job_status(get(s:job, 'job', '')) ==# 'run'
      echohl WarningMsg | echomsg 'RTL: a lint job is already running' | echohl None
      return
    endif
    let s:job = {'lines': [], 'efm': efm, 'title': title, 'bufnr': bufnr('%'),
          \ 'tool': tool, 'root': root}
    let opts = {'in_io': 'null', 'out_mode': 'nl', 'err_mode': 'nl',
          \ 'out_cb': function('s:OnOut'), 'err_cb': function('s:OnOut'),
          \ 'exit_cb': function('s:OnExit')}
    if has('patch-8.0.0902') | let opts.cwd = root | endif
    let s:job.job = job_start(cmd, opts)
    if job_status(s:job.job) ==# 'fail'
      echohl ErrorMsg | echomsg 'RTL: could not start ' . tool | echohl None
      let s:job = {}
      return
    endif
    echo 'RTL: running ' . tool . ' ...'
  else
    let shellcmd = join(map(copy(cmd), 'shellescape(v:val)'), ' ') . ' 2>&1'
    let cwd = getcwd()
    try
      execute 'lcd ' . fnameescape(root)
      let out = system(shellcmd)
    finally
      execute 'lcd ' . fnameescape(cwd)
    endtry
    call s:Publish(split(out, '\n'), efm, title, bufnr('%'), tool, root)
  endif
endfunction

function! s:OnOut(ch, msg) abort
  call add(s:job.lines, a:msg)
endfunction

function! s:OnExit(job, status) abort
  let j = s:job
  let s:job = {}
  call s:Publish(j.lines, j.efm, j.title, j.bufnr, j.tool, j.root)
endfunction

function! s:Publish(lines, efm, title, bufnr, tool, root) abort
  let save_efm = &errorformat
  let save_cwd = getcwd()
  try
    " relative file names in tool output are relative to the project root
    execute 'lcd ' . fnameescape(a:root)
    let &errorformat = a:efm
    cgetexpr a:lines
  finally
    let &errorformat = save_efm
    execute 'lcd ' . fnameescape(save_cwd)
  endtry
  let qf = getqflist()
  call filter(qf, 'v:val.valid')
  let nerr = 0
  let nwarn = 0
  for e in qf
    if e.type ==? 'w' || e.text =~? '^\s*warning'
          \ || (get(s:tools[a:tool], 'warn_default', 0) && e.text !~? 'syntax error')
      let nwarn += 1
    else
      let nerr += 1
    endif
  endfor
  if exists('*setqflist') && has('patch-7.4.2200')
    call setqflist([], 'a', {'title': 'RTL lint: ' . a:title})
  endif
  call s:PlaceSigns(qf, a:tool)
  for b in range(1, bufnr('$'))
    if bufexists(b) | call setbufvar(b, 'rtl_diag', '') | endif
  endfor
  let msg = 'RTL ' . a:tool . ': ' . nerr . ' error(s), ' . nwarn . ' warning(s)'
  call setbufvar(a:bufnr, 'rtl_diag', (nerr + nwarn) ? ('E' . nerr . ' W' . nwarn) : 'ok')
  if empty(qf)
    cclose
    echo msg
  else
    copen
    wincmd p
    echo msg . ' - ]q / [q to navigate'
  endif
  redrawstatus
endfunction

" --------------------------------------------------------------- signs ---
function! s:DefineSigns() abort
  if s:signs_defined || !has('signs') | return | endif
  sign define RtlError text=>> texthl=ErrorMsg
  sign define RtlWarn  text=-- texthl=WarningMsg
  sign define RtlInfo  text=.. texthl=Comment
  let s:signs_defined = 1
endfunction

function! rtl#lint#ClearSigns(...) abort
  if !has('signs') | return | endif
  let bufs = a:0 ? [a:1] : keys(s:signs)
  for b in bufs
    for id in get(s:signs, b, [])
      silent! execute 'sign unplace ' . id . ' buffer=' . b
    endfor
    if has_key(s:signs, b) | unlet s:signs[b] | endif
  endfor
endfunction

function! s:PlaceSigns(items, tool) abort
  if !has('signs') | return | endif
  call s:DefineSigns()
  call rtl#lint#ClearSigns()
  for e in a:items
    if e.bufnr <= 0 || e.lnum <= 0 | continue | endif
    let name = (e.type ==? 'w' || e.text =~? '^\s*warning'
          \ || (get(s:tools[a:tool], 'warn_default', 0) && e.text !~? 'syntax error')) ? 'RtlWarn' : 'RtlError'
    let id = s:next_sign
    let s:next_sign += 1
    silent! execute 'sign place ' . id . ' line=' . e.lnum . ' name=' . name . ' buffer=' . e.bufnr
    let s:signs[e.bufnr] = get(s:signs, e.bufnr, []) + [id]
  endfor
endfunction

" Used by the LSP client for publishDiagnostics (location list + signs).
function! rtl#lint#PlaceDiagSigns(bufnr, items) abort
  if !has('signs') | return | endif
  call s:DefineSigns()
  call rtl#lint#ClearSigns(a:bufnr)
  for e in a:items
    let name = e.type ==# 'E' ? 'RtlError' : (e.type ==# 'W' ? 'RtlWarn' : 'RtlInfo')
    let id = s:next_sign
    let s:next_sign += 1
    silent! execute 'sign place ' . id . ' line=' . e.lnum . ' name=' . name . ' buffer=' . a:bufnr
    let s:signs[a:bufnr] = get(s:signs, a:bufnr, []) + [id]
  endfor
endfunction

function! rtl#lint#Clear() abort
  call rtl#lint#ClearSigns()
  call setqflist([], 'r')
  for b in range(1, bufnr('$'))
    if bufexists(b) | call setbufvar(b, 'rtl_diag', '') | endif
  endfor
  cclose
  echo 'RTL: diagnostics cleared'
endfunction

function! rtl#lint#ShowDiagnostics() abort
  if !empty(getloclist(0))
    lopen
  elseif !empty(getqflist())
    copen
  else
    echo 'RTL: no diagnostics (run :RtlLint, :RtlLintProject, or start the LSP)'
  endif
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
