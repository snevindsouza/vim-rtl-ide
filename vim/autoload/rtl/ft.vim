" autoload/rtl/ft.vim -- buffer-local setup shared by the RTL ftplugins
"
" Called from after/ftplugin/{verilog,systemverilog,vhdl}.vim, i.e. AFTER
" Vim's own ftplugin/indent/syntax for the language have run, so stock
" behaviour (indentexpr, matchit words, comments) is kept and only
" extended.  Everything here is buffer-local: mappings use <buffer>,
" options use setlocal, autocommands are filtered by <buffer>.

let s:save_cpo = &cpo | set cpo&vim

function! rtl#ft#Setup(lang) abort
  " ---- language specifics ------------------------------------------
  if a:lang ==# 'vhdl'
    let b:rtl_comment_leader = '--'
    setlocal commentstring=--\ %s
    setlocal comments=:--
    setlocal iskeyword=@,48-57,_,192-255
  else
    let b:rtl_comment_leader = '//'
    setlocal commentstring=//\ %s
    setlocal comments=sO:*\ -,mO:*\ \ ,exO:*/,s1:/*,mb:*,ex:*/,://
    " `define / `include and $signed etc. are part of a word for completion
    setlocal iskeyword=@,48-57,_,192-255,`,$
    " Vim's indent/verilog.vim re-indents these as they are typed
    setlocal indentkeys+==end,=endcase,=endmodule,=endfunction,=endtask,=endgenerate,=else,=join
    " stock indent scripts: indent the body of a module by one level
    let b:verilog_indent_modules = 1
    let b:systemverilog_indent_modules = 1
  endif
  setlocal formatoptions-=c formatoptions-=r formatoptions-=o
  setlocal formatoptions+=q
  setlocal textwidth=0
  setlocal expandtab shiftwidth=2 softtabstop=2 tabstop=2

  " ---- project, path, tags -----------------------------------------
  call rtl#project#Root()
  call rtl#project#SetPath()
  call rtl#tags#SetTagsOption()
  setlocal suffixesadd=.v,.sv,.vh,.svh,.vhd,.vhdl
  if a:lang !=# 'vhdl'
    setlocal include=^\\s*`include
    setlocal define=^\\s*`define\\s*
  endif

  " ---- completion --------------------------------------------------
  setlocal omnifunc=rtl#complete#Omni
  setlocal completefunc=rtl#complete#Omni
  setlocal completeopt=menuone,longest
  if has('patch-7.4.775')
    setlocal completeopt+=noinsert
  endif
  " keyword completion (<C-n>/<C-p>) also looks in the dictionary and tags
  for f in split(globpath(&runtimepath, 'dict/' . a:lang . '.dict'), '\n')
    execute 'setlocal dictionary+=' . fnameescape(f)
  endfor
  setlocal complete=.,w,b,u,t,k
  setlocal infercase

  " ---- mappings (buffer-local) -------------------------------------
  " completion triggers
  inoremap <buffer> <silent> <C-Space> <C-x><C-o>
  inoremap <buffer> <silent> <C-@>     <C-x><C-o>
  if get(g:, 'rtl_smart_tab', 1)
    inoremap <buffer> <silent> <expr> <Tab>   rtl#complete#SmartTab()
    inoremap <buffer> <silent> <expr> <S-Tab> rtl#complete#SmartSTab()
  endif
  " Enter: matching end after begin (Verilog/SV only)
  if a:lang !=# 'vhdl'
    inoremap <buffer> <silent> <expr> <CR> rtl#edit#CR()
  endif
  " comments
  nnoremap <buffer> <silent> <Leader>/ :call rtl#edit#ToggleComment()<CR>
  xnoremap <buffer> <silent> <Leader>/ :call rtl#edit#ToggleComment()<CR>
  " navigation
  nnoremap <buffer> <silent> <Leader>gd :RtlDefinition<CR>
  nnoremap <buffer> <silent> <Leader>gr :RtlReferences<CR>
  nnoremap <buffer> <silent> <Leader>gi :RtlInstances<CR>
  nnoremap <buffer> <silent> <Leader>gs :RtlSymbols<CR>
  nnoremap <buffer> <silent> <Leader>gn :RtlRename<CR>
  nnoremap <buffer> <silent> <Leader>gf gf
  nnoremap <buffer> <silent> <Leader>gp :execute 'ptjump ' . expand('<cword>')<CR>
  nnoremap <buffer> <silent> K :RtlHover<CR>
  " lint
  nnoremap <buffer> <silent> <Leader>ll :RtlLint<CR>
  nnoremap <buffer> <silent> <Leader>lp :RtlLintProject<CR>
  nnoremap <buffer> <silent> <Leader>ld :RtlDiagnostics<CR>
  nnoremap <buffer> <silent> <Leader>lx :RtlClearDiagnostics<CR>
  nnoremap <buffer> <silent> <Leader>lf :RtlFormat<CR>
  " templates
  nnoremap <buffer> <silent> <Leader>it :RtlTemplate<CR>
  nnoremap <buffer> <silent> <Leader>im :RtlModule<CR>
  nnoremap <buffer> <silent> <Leader>ii :RtlInstantiate<CR>
  if a:lang !=# 'vhdl'
    nnoremap <buffer> <silent> <Leader>ia :RtlTemplate always_ff<CR>
    nnoremap <buffer> <silent> <Leader>ic :RtlTemplate always_comb<CR>
    nnoremap <buffer> <silent> <Leader>is :RtlTemplate case<CR>
  else
    nnoremap <buffer> <silent> <Leader>ia :RtlTemplate process_sync<CR>
    nnoremap <buffer> <silent> <Leader>ic :RtlTemplate process_comb<CR>
    nnoremap <buffer> <silent> <Leader>is :RtlTemplate case<CR>
  endif

  " ---- LSP document sync (buffer-local autocommands) ----------------
  if rtl#lsp#Supported()
    augroup RtlLspBuf
      autocmd! * <buffer>
      autocmd BufEnter      <buffer> call rtl#lsp#OnEnter()
      autocmd TextChanged   <buffer> call rtl#lsp#OnChange()
      autocmd TextChangedI  <buffer> call rtl#lsp#OnChange()
      autocmd InsertLeave   <buffer> call rtl#lsp#OnInsertLeave()
      autocmd BufWritePost  <buffer> call rtl#lsp#OnSave()
      autocmd BufUnload     <buffer> call rtl#lsp#OnClose(str2nr(expand('<abuf>')))
    augroup END
    " first open of this buffer: start/attach now
    call rtl#lsp#OnEnter()
  endif

  " ---- undo on :setfiletype change ---------------------------------
  let b:undo_ftplugin = get(b:, 'undo_ftplugin', '')
        \ . '|setlocal commentstring< comments< iskeyword< indentkeys< formatoptions<'
        \ . ' textwidth< expandtab< shiftwidth< softtabstop< tabstop< path< tags<'
        \ . ' suffixesadd< include< define< omnifunc< completefunc< completeopt<'
        \ . ' dictionary< complete< infercase<'
        \ . '|silent! iunmap <buffer> <C-Space>|silent! iunmap <buffer> <C-@>'
        \ . '|silent! iunmap <buffer> <Tab>|silent! iunmap <buffer> <S-Tab>'
        \ . '|silent! iunmap <buffer> <CR>|silent! nunmap <buffer> K'
        \ . '|unlet! b:did_rtl_ftplugin b:rtl_comment_leader b:verilog_indent_modules b:systemverilog_indent_modules'
        \ . '|execute "silent! autocmd! RtlLspBuf * <buffer>"'
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
