" tests/rtl_test.vim -- headless test suite, run by tests/run_tests.sh:
"   vim -N -i NONE -u "$HOME/.vimrc" -es -c "let g:rtl_test_out='...'" \
"       -c "let g:rtl_test_proj='...'" -S tests/rtl_test.vim
" Each test appends "PASS|FAIL|SKIP  Tnn  description" to g:rtl_test_out.
" The script exits with status 1 (:cquit) if any test FAILed.

let s:results = []
let s:fail = 0

function! s:Report(status, id, desc, ...) abort
  let line = printf('%-4s %-4s %s', a:status, a:id, a:desc)
  if a:0 && !empty(a:1) | let line .= '  -- ' . a:1 | endif
  call add(s:results, line)
  if a:status ==# 'FAIL' | let s:fail += 1 | endif
endfunction

function! s:Check(id, desc, cond, ...) abort
  call s:Report(a:cond ? 'PASS' : 'FAIL', a:id, a:desc, a:0 ? a:1 : '')
endfunction

" Run a test body (funcref) and turn exceptions into FAIL.
function! s:Run(id, desc, Fn) abort
  try
    call a:Fn(a:id, a:desc)
  catch
    call s:Report('FAIL', a:id, a:desc, 'exception: ' . v:exception . ' @ ' . v:throwpoint)
  endtry
endfunction

let s:proj = g:rtl_test_proj         " copy of tests/rtl, path may contain spaces
let s:out  = g:rtl_test_out
" never start a real language server during the automated tests
let g:rtl_lsp_autostart = 0

" T01 ---------------------------------------------------------------------
function! s:T01(id, desc) abort
  " vimrc was loaded headlessly and the core module is reachable
  call rtl#project#Root()
  call s:Check(a:id, a:desc, exists(':RtlDoctor') == 2 && exists('*rtl#project#Root'),
        \ 'v:version=' . v:version . ' errmsg="' . v:errmsg . '"')
endfunction
call s:Run('T01', 'headless startup, vimrc loaded, :Rtl commands defined', function('s:T01'))

" T02 ---------------------------------------------------------------------
function! s:T02(id, desc) abort
  " every module parses (sourcing a file with a syntax error throws)
  let errs = []
  for f in split(globpath(&runtimepath, 'autoload/rtl/*.vim'), '\n')
        \ + split(globpath(&runtimepath, 'after/ftplugin/*.vim'), '\n')
        \ + split(globpath(&runtimepath, 'ftdetect/rtl.vim'), '\n')
    if f =~# 'after/ftplugin'
      " ftplugins need a buffer; just check they are readable and short
      if !filereadable(f) | call add(errs, f) | endif
      continue
    endif
    let v:errmsg = ''
    try
      execute 'source ' . fnameescape(f)
    catch
      call add(errs, fnamemodify(f, ':t') . ': ' . v:exception)
    endtry
    if !empty(v:errmsg) | call add(errs, fnamemodify(f, ':t') . ': ' . v:errmsg) | endif
  endfor
  call s:Check(a:id, a:desc, empty(errs), join(errs, '; '))
endfunction
call s:Run('T02', 'configuration syntax: all modules source without error', function('s:T02'))

" T03 ---------------------------------------------------------------------
function! s:T03(id, desc) abort
  execute 'edit ' . fnameescape(s:proj . '/counter.v')
  let save = [get(g:, 'rtl_verilator_exe', ''), get(g:, 'rtl_lsp_command', ''), g:rtl_lsp_autostart]
  let g:rtl_verilator_exe = 'rtl_test_no_such_tool_xyz'
  let g:rtl_lsp_command = 'rtl_test_no_such_ls_xyz'
  let g:rtl_lsp_autostart = 0
  let v:errmsg = ''
  let msgs = ''
  redir => msgs
  silent call rtl#lint#Run('verilator', 0)
  silent call rtl#lsp#Start(1)
  silent call rtl#lsp#Hover()
  silent call rtl#lsp#Rename('x')
  silent call rtl#lsp#Format()
  redir END
  let [g:rtl_verilator_exe, g:rtl_lsp_command, g:rtl_lsp_autostart] = save
  let cmd = rtl#lsp#Command('verilog')
  call s:Check(a:id, a:desc,
        \ empty(v:errmsg) && msgs =~# 'not found\|no language server\|unavailable\|no server'
        \ && (empty(cmd) || executable(cmd[0])),
        \ 'messages: ' . substitute(msgs, '\n', ' | ', 'g'))
endfunction
call s:Run('T03', 'missing optional tools: clear message, no error, no crash', function('s:T03'))

" T04 ---------------------------------------------------------------------
function! s:T04(id, desc) abort
  execute 'edit ' . fnameescape(s:proj . '/counter.v')
  let g:rtl_lsp_autostart = 0
  " buffer symbols
  let words = map(copy(rtl#symbols#Buffer(bufnr('%'))), 'v:val.word')
  let have = ['counter', 'WIDTH', 'INIT', 'clk', 'rst_n', 'en', 'q', 'wrap', 'q_nxt', 'wrap_r', 'MAXV', 'next_val']
  let missing = filter(copy(have), 'index(words, v:val) < 0')
  " omni on a prefix in the same buffer
  let items = map(rtl#complete#Omni(0, 'q_'), 'v:val.word')
  let ok1 = empty(missing) && index(items, 'q_nxt') >= 0
  " keyword source present
  let kw = map(rtl#complete#Omni(0, 'endmod'), 'v:val.word')
  let ok2 = index(kw, 'endmodule') >= 0
  " instantiation context in top.v: ports after '.', params inside #(
  execute 'edit ' . fnameescape(s:proj . '/top.v')
  call cursor(16, 1) | normal! $
  let ctx = rtl#symbols#InstContext()
  let info = rtl#symbols#ModuleInfo('counter')
  let ports = map(copy(get(info, 'ports', [])), 'v:val.name')
  let params = map(copy(get(info, 'params', [])), 'v:val.name')
  let ok3 = get(ctx, 'module', '') ==# 'counter' && get(ctx, 'section', '') ==# 'ports'
        \ && ports ==# ['clk', 'rst_n', 'en', 'q', 'wrap'] && params ==# ['WIDTH', 'INIT']
  call cursor(13, 1) | normal! $
  let ctx2 = rtl#symbols#InstContext()
  let ok4 = get(ctx2, 'section', '') ==# 'params'
  " simulate typing ".r" on the port line and ask omni
  call cursor(17, 1)
  call setline(17, '    .r')
  normal! $
  let s = rtl#complete#Omni(1, '')
  let pl = map(rtl#complete#Omni(0, 'r'), 'v:val.word')
  silent! undo
  let ok5 = index(pl, 'rst_n') >= 0 && index(pl, 'WIDTH') < 0
  call s:Check(a:id, a:desc, ok1 && ok2 && ok3 && ok4 && ok5,
        \ printf('syms=%d missing=%s omni(q_)=%s kw=%d ctx=%s ports=%s params=%s ctx2=%s portcomp=%s',
        \ ok1, string(missing), string(items[:3]), ok2, string(ctx), string(ports), string(params), string(ctx2), string(pl[:3])))
  set nomodified
endfunction
call s:Run('T04', 'completion: buffer symbols, keywords, port/param context', function('s:T04'))

" T05 ---------------------------------------------------------------------
function! s:T05(id, desc) abort
  execute 'edit ' . fnameescape(s:proj . '/top.v')
  let g:rtl_lsp_autostart = 0
  let root = rtl#project#Root()
  let ok0 = root ==# s:proj
  let msgs = ''
  redir => msgs
  silent RtlTags
  redir END
  let tf = root . '/tags'
  let tl = taglist('^counter$')
  let ok1 = filereadable(tf) && !empty(tl)
  " definition jump from the instantiation to the module
  call search('^\s*counter #', 'w')
  normal! 0
  call search('counter', 'c', line('.'))
  silent call rtl#nav#Definition()
  let ok2 = expand('%:t') ==# 'counter.v' && getline('.') =~# 'module counter'
  " instances search
  silent call rtl#nav#Instances('counter')
  let qf = getqflist()
  let ok3 = len(qf) >= 1 && bufname(qf[0].bufnr) =~# 'top\.v$'
  " gf on `include
  execute 'edit ' . fnameescape(s:proj . '/top.v')
  call search('`include', 'w')
  let found = findfile('defs.vh', &path)
  let ok4 = !empty(found)
  call s:Check(a:id, a:desc, ok0 && ok1 && ok2 && ok3 && ok4,
        \ printf('root=%s tags=%d def=%d(%s) inst=%d incl=%d  %s', ok0, ok1, ok2, expand('%:t'), ok3, ok4,
        \ substitute(msgs, '\n', ' ', 'g')))
  cclose
endfunction
call s:Run('T05', 'navigation: root, tags, definition jump, instances, include path', function('s:T05'))

" T06 ---------------------------------------------------------------------
function! s:T06(id, desc) abort
  let tools = rtl#lint#Available('verilog')
  if empty(tools)
    call s:Report('SKIP', a:id, a:desc, 'no verilator/iverilog/verible in PATH (lint unavailable here)')
    return
  endif
  execute 'edit ' . fnameescape(s:proj . '/bad.v')
  let g:rtl_lsp_autostart = 0
  silent call rtl#lint#Run(tools[0], 0)
  " async: wait for the job
  let n = 0
  while n < 300 && getbufvar('%', 'rtl_diag', '') ==# ''
    sleep 50m
    let n += 1
  endwhile
  let qf = filter(getqflist(), 'v:val.valid')
  call s:Check(a:id, a:desc, !empty(qf) && get(b:, 'rtl_diag', '') =~# '^E',
        \ tools[0] . ': ' . len(qf) . ' entries, diag=' . get(b:, 'rtl_diag', '') . ' first="' . (empty(qf) ? '' : qf[0].text) . '"')
  cclose
endfunction
call s:Run('T06', 'diagnostics on intentionally broken RTL (needs an external tool)', function('s:T06'))

" T07 ---------------------------------------------------------------------
function! s:T07(id, desc) abort
  enew!
  set filetype=verilog
  let g:rtl_lsp_autostart = 0
  call setline(1, ['module m;', 'always @(posedge clk) begin', 'if (a) begin', 'if (b) begin',
        \ 'x <= 1;', 'end', 'y <= 2;', 'end', 'end', 'endmodule'])
  normal! gg=G
  let ind = map(range(1, line('$')), 'indent(v:val)')
  " expectations: nested blocks strictly deeper, each end matches its begin
  let ok = !empty(&indentexpr)
        \ && ind[0] == 0 && ind[9] == 0
        \ && ind[1] >= ind[0] && ind[2] > ind[1] && ind[3] > ind[2] && ind[4] > ind[3]
        \ && ind[5] == ind[3] && ind[6] == ind[3] && ind[7] == ind[2] && ind[8] == ind[1]
  call s:Check(a:id, a:desc, ok, 'indentexpr=' . &indentexpr . ' indents=' . string(ind))
  bwipeout!
endfunction
call s:Run('T07', 'nested begin/end indentation via stock indentexpr', function('s:T07'))

" T08 ---------------------------------------------------------------------
function! s:T08(id, desc) abort
  enew!
  set filetype=verilog
  call setline(1, ['  assign a = b;', '    assign c = d;', '', '  assign e = f;'])
  1,4call rtl#edit#ToggleComment()
  let c1 = getline(1, 4) ==# ['  // assign a = b;', '  //   assign c = d;', '', '  // assign e = f;']
  1,4call rtl#edit#ToggleComment()
  let c2 = getline(1, 4) ==# ['  assign a = b;', '    assign c = d;', '', '  assign e = f;']
  1call rtl#edit#ToggleComment()
  let c3 = getline(1) ==# '  // assign a = b;'
  1call rtl#edit#ToggleComment()
  let c4 = getline(1) ==# '  assign a = b;'
  bwipeout!
  enew!
  set filetype=vhdl
  call setline(1, ['  q <= d;'])
  1call rtl#edit#ToggleComment()
  let c5 = getline(1) ==# '  -- q <= d;'
  bwipeout!
  call s:Check(a:id, a:desc, c1 && c2 && c3 && c4 && c5, printf('%d%d%d%d%d', c1, c2, c3, c4, c5))
endfunction
call s:Run('T08', 'line and block comment toggle keeps indentation (// and --)', function('s:T08'))

" T09 ---------------------------------------------------------------------
function! s:T09(id, desc) abort
  enew!
  set filetype=verilog
  let g:rtl_lsp_autostart = 0
  " the handler reads the cursor as it is in insert mode (after the last
  " character); emulate that from normal mode with virtualedit
  let save_ve = &virtualedit
  set virtualedit=onemore
  " 1. begin without end -> inserts
  call setline(1, ['always @* begin', '  x = 1;', 'endmodule'])
  call cursor(1, col([1, '$']))
  let r1 = rtl#edit#CR()
  " 2. begin already closed -> plain CR
  call setline(1, ['always @* begin', '  x = 1;', 'end', 'endmodule'])
  call cursor(1, col([1, '$']))
  let r2 = rtl#edit#CR()
  " 3. word 'begin' in a comment -> plain CR (needs syntax)
  call setline(1, ['// this is a begin', 'endmodule'])
  syntax enable
  call cursor(1, col([1, '$']))
  let r3 = rtl#edit#CR()
  " 4. text after the cursor -> plain CR
  call setline(1, ['if (a) begin x = 1; end', 'endmodule'])
  call cursor(1, 13)
  let r4 = rtl#edit#CR()
  " 5. named block
  call setline(1, ['if (a) begin : blk', 'endmodule'])
  call cursor(1, col([1, '$']))
  let r5 = rtl#edit#CR()
  " 6. nested begin inside an already closed outer block -> inserts
  call setline(1, ['module m;', 'always @* begin', '  if (a) begin', 'end', 'endmodule'])
  call cursor(3, col([3, '$']))
  let r7 = rtl#edit#CR()
  " 7. nested begin whose own end exists -> plain CR
  call setline(1, ['module m;', 'always @* begin', '  if (a) begin', '  end', 'end', 'endmodule'])
  call cursor(3, col([3, '$']))
  let r8 = rtl#edit#CR()
  let &virtualedit = save_ve
  " 6. end-to-end through the mapping with feedkeys (best effort in -es)
  %delete _
  call setline(1, ['module m;', 'endmodule'])
  call cursor(1, 1)
  let r6 = ''
  let g:rtl_test_cr_trace = []
  let mapinfo = maparg('<CR>', 'i', 0, 1)
  try
    call feedkeys("oalways @* begin\<CR>x = 1;\<Esc>", 'xt')
    let r6 = string(getline(1, '$')) . ' trace=' . string(g:rtl_test_cr_trace)
          \ . ' map=' . string(get(mapinfo, 'rhs', '')) . '/buffer=' . get(mapinfo, 'buffer', -1)
          \ . ' fterr=' . get(b:, 'rtl_ftplugin_error', '')
  catch
    let r6 = 'feedkeys-exception'
  endtry
  let e2e = getline(1, '$') ==# ['module m;', '  always @* begin', '    x = 1;', '  end', 'endmodule']
        \ || getline(1, '$') ==# ['module m;', 'always @* begin', '  x = 1;', 'end', 'endmodule']
        \ || (getline(1, '$') ==# ['module m;', 'always @* begin', 'x = 1;', 'end', 'endmodule'])
  let ok = r1 ==# "\<CR>end\<C-o>O" && r2 ==# "\<CR>" && r3 ==# "\<CR>" && r4 ==# "\<CR>"
        \ && r5 ==# "\<CR>end\<C-o>O" && r7 ==# "\<CR>end\<C-o>O" && r8 ==# "\<CR>"
  unlet g:rtl_test_cr_trace
  bwipeout!
  " e2e through feedkeys is best-effort in -es mode; the function-level
  " checks decide, the e2e result is reported for the interactive check
  call s:Check(a:id, a:desc, ok,
        \ printf('insert=%d closed=%d comment=%d midline=%d named=%d nested=%d nested-closed=%d feedkeys-e2e=%d(informational: -es feeds the <CR> before the last typed char lands) buffer=%s',
        \ r1 ==# "\<CR>end\<C-o>O", r2 ==# "\<CR>", r3 ==# "\<CR>", r4 ==# "\<CR>", r5 ==# "\<CR>end\<C-o>O",
        \ r7 ==# "\<CR>end\<C-o>O", r8 ==# "\<CR>", e2e, r6))
endfunction
call s:Run('T09', 'Enter handler: inserts end once, never in comments/closed/mid-line', function('s:T09'))

" T10 ---------------------------------------------------------------------
function! s:T10(id, desc) abort
  " g:rtl_test_proj is created by run_tests.sh inside a directory with a
  " space in its name; everything above already ran there.  Verify the
  " file list, the tags file and :RtlFind handle it.
  let has_space = s:proj =~# ' '
  execute 'edit ' . fnameescape(s:proj . '/counter.v')
  let files = rtl#project#Files(1)
  let ok1 = index(files, s:proj . '/counter.v') >= 0 || index(files, resolve(s:proj) . '/counter.v') >= 0
  silent RtlTags
  let ok2 = filereadable(s:proj . '/tags') && !empty(taglist('^top$'))
  silent call rtl#project#Find('top.v')
  let ok3 = expand('%:t') ==# 'top.v'
  let f = rtl#symbols#FindModuleFile('counter')
  let ok4 = f =~# 'counter\.v$'
  call s:Check(a:id, a:desc, has_space && ok1 && ok2 && ok3 && ok4,
        \ printf('space=%d files=%d tags=%d find=%d modfile=%d proj=%s', has_space, ok1, ok2, ok3, ok4, s:proj))
endfunction
call s:Run('T10', 'paths containing spaces (project, tags, find, module lookup)', function('s:T10'))

" T11 ---------------------------------------------------------------------
function! s:T11(id, desc) abort
  let vimrc = expand($MYVIMRC)
  if empty(vimrc) || !filereadable(vimrc) | let vimrc = expand('~/.vimrc') | endif
  execute 'source ' . fnameescape(vimrc)
  execute 'source ' . fnameescape(vimrc)
  let au = ''
  redir => au
  silent autocmd RtlIde FileType
  redir END
  " exactly one 'FileType *' line for our augroup
  let n = len(filter(split(au, '\n'), 'v:val =~# "formatoptions"'))
  " ftplugin re-entry: set filetype twice, buffer-local <CR> mapping once
  enew!
  set filetype=verilog
  set filetype=verilog
  let mi = maparg('<CR>', 'i', 0, 1)
  let m = (get(mi, 'buffer', 0) && get(mi, 'rhs', '') =~# 'rtl#edit#CR') ? 1 : 0
  let maps = ''
  redir => maps
  silent imap <buffer>
  redir END
  let m_listed = len(filter(split(maps, '\n'), 'v:val =~# "rtl#edit#CR"'))
  let b = 0
  if exists('#RtlLspBuf')
    let bau = ''
    redir => bau
    silent autocmd RtlLspBuf BufEnter <buffer>
    redir END
    let b = len(filter(split(bau, '\n'), 'v:val =~# "OnEnter"'))
  endif
  bwipeout!
  call s:Check(a:id, a:desc, n == 1 && m == 1 && m_listed == 1 && (b <= 1),
        \ printf('RtlIde FileType entries=%d, <CR> maparg=%d listed=%d, buffer BufEnter autocmds=%d, did_rtl=%d fterr=%s',
        \ n, m, m_listed, b, exists('b:did_rtl_ftplugin'), get(b:, 'rtl_ftplugin_error', '')))
endfunction
call s:Run('T11', 'repeated sourcing: no duplicate autocommands or mappings', function('s:T11'))

" T12 ---------------------------------------------------------------------
function! s:T12(id, desc) abort
  let rtp = &runtimepath
  let rtp_user = join(filter(split(rtp, ','), 'v:val !~# "pack/dist/"'), ',')
  let bad = rtp_user =~# 'plugged\|bundle\|pack/\|dein\|vim-plug'
  let plugdir = !empty(globpath(expand('~/.vim'), 'plugin/*.vim')) || isdirectory(expand('~/.vim/pack'))
  let scripts = ''
  redir => scripts
  silent scriptnames
  redir END
  let foreign = filter(split(scripts, '\n'), 'v:val !~# "/\\.vim/\\|\\$VIM\\|/usr/\\|/opt/\\|/snap/\\|vimrc\\|rtl_test\\|/vim/\\|/nix/"')
  call s:Check(a:id, a:desc, !bad && !plugdir,
        \ 'rtp (minus Vim''s own pack/dist matchit) has no plugin dirs; ~/.vim has no plugin/ or pack/; foreign scripts: ' . string(foreign))
endfunction
call s:Run('T12', 'no plugins or plugin managers in use', function('s:T12'))

" T13 is a shell-level test in run_tests.sh (installer backup).

" ----------------------------------------------------------------- done ---
call writefile(s:results, s:out)
if s:fail > 0
  cquit
endif
qall!
