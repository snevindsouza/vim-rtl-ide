" autoload/rtl/doctor.vim -- :RtlDoctor  reports Vim features, optional
" tools, project detection and what is lost when something is missing.
let s:save_cpo = &cpo | set cpo&vim

function! s:Row(name, ok, detail) abort
  return printf('  %-28s %s  %s', a:name, a:ok ? '[ok]  ' : '[--]  ', a:detail)
endfunction

function! rtl#doctor#Run() abort
  let lines = ['RTL IDE doctor  (Vim ' . v:version / 100 . '.' . v:version % 100
        \ . (exists('v:versionlong') ? ', ' . v:versionlong : '') . ')', '']
  call add(lines, 'Vim features:')
  call add(lines, s:Row('+eval', has('eval'), 'required for everything'))
  call add(lines, s:Row('+syntax', has('syntax'), 'highlighting, comment-aware Enter'))
  call add(lines, s:Row('+quickfix', has('quickfix'), 'lint results, grep, references'))
  call add(lines, s:Row('+insert_expand', has('insert_expand'), 'completion popup'))
  call add(lines, s:Row('+job +channel', has('job') && has('channel'), 'async lint, LSP client'))
  call add(lines, s:Row('json_encode/json_decode', exists('*json_encode'), 'LSP client'))
  call add(lines, s:Row('+timers', has('timers'), 'debounced LSP didChange (fallback: InsertLeave)'))
  call add(lines, s:Row('+popupwin', has('popupwin'), 'hover popup (fallback: echo)'))
  call add(lines, s:Row('+signs', has('signs'), 'gutter markers for diagnostics'))
  call add(lines, s:Row('+persistent_undo', has('persistent_undo'), 'undo across sessions'))
  call add(lines, s:Row('+clipboard', has('clipboard'), 'system clipboard (needs X over SSH); OSC52 <Leader>y otherwise'))
  call add(lines, s:Row('matchit loaded', exists('g:loaded_matchit'), '% between begin/end, module/endmodule'))
  call add(lines, '')
  call add(lines, 'Optional tools ($PATH or g:rtl_*_exe):')
  let ctags = rtl#tags#CtagsExe()
  call add(lines, s:Row('ctags (universal/exuberant)', !empty(ctags),
        \ empty(ctags) ? 'missing: :RtlTags uses the built-in Vimscript indexer' : ctags . ' (' . rtl#tags#CtagsFlavour(ctags) . ')'))
  for [tool, exe, what] in [
        \ ['verilator', get(g:, 'rtl_verilator_exe', 'verilator'), 'Verilog/SV lint + elaboration checks'],
        \ ['iverilog', get(g:, 'rtl_iverilog_exe', 'iverilog'), 'Verilog/SV parse + elaboration (-t null)'],
        \ ['verible-verilog-lint', get(g:, 'rtl_verible_lint_exe', 'verible-verilog-lint'), 'Verilog/SV syntax + style lint'],
        \ ['ghdl', get(g:, 'rtl_ghdl_exe', 'ghdl'), 'VHDL syntax check (-s)'],
        \ ]
    let found = executable(exe)
    call add(lines, s:Row(tool, found, found ? (exists('*exepath') ? exepath(exe) : exe) . '  (' . what . ')' : 'missing: ' . what . ' unavailable'))
  endfor
  for g in ['verilog', 'vhdl']
    let cmd = rtl#lsp#Command(g)
    call add(lines, s:Row('LSP server (' . g . ')', !empty(cmd),
          \ empty(cmd) ? 'missing: no hover/definition/references/rename/format from a server; tags & text search still work'
          \ : join(cmd, ' ')))
  endfor
  call add(lines, s:Row('base64 (OSC52)', executable('base64'), 'terminal clipboard yank (pure-Vim fallback exists)'))
  call add(lines, '')
  call add(lines, 'Project:')
  let root = rtl#project#Root()
  call add(lines, '  root        ' . root)
  call add(lines, '  config      ' . (filereadable(root . '/.rtlproject') ? root . '/.rtlproject' : '(none; defaults)'))
  call add(lines, '  filelist    ' . (empty(rtl#project#Filelist()) ? '(none)' : rtl#project#Filelist()))
  call add(lines, '  tags        ' . (filereadable(root . '/tags') ? root . '/tags (' . strftime('%Y-%m-%d %H:%M', getftime(root . '/tags')) . ')' : '(none; run :RtlTags)'))
  call add(lines, '  lint tool   ' . (empty(rtl#project#ConfigGet('lint_tool', g:rtl_lint_tool)) ? 'auto: ' . join(rtl#lint#Available(&filetype =~# '^\%(verilog\|systemverilog\|vhdl\)$' ? &filetype : 'verilog'), ', ') : rtl#project#ConfigGet('lint_tool', g:rtl_lint_tool)))
  call add(lines, '  src dirs    ' . join(rtl#project#SrcDirs(), ', '))
  call add(lines, '  extensions  ' . join(rtl#project#Extensions(), ', '))
  call add(lines, '')
  call add(lines, 'Config: ~/.vimrc.local for overrides, <root>/.rtlproject per project, :help rtl-ide')
  silent botright new
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  call setline(1, lines)
  setlocal nomodifiable nonumber norelativenumber
  file RTL-doctor
  nnoremap <silent> <buffer> q :close<CR>
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
