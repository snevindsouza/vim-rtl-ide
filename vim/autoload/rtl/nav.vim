" autoload/rtl/nav.vim -- navigation
"
"   Definition:  LSP textDocument/definition if a server is running and
"                advertises it; otherwise the tags file (:tjump); otherwise
"                a declaration search in the current buffer.
"   References:  LSP textDocument/references if available; otherwise a
"                whole-word TEXT SEARCH over project files (vimgrep).  The
"                quickfix title says which one you got.
"   Instances:   text search for "<module> ... (" instantiation heads.
"   Grep:        :vimgrep over the cached project file list (pure Vim, no
"                external grep needed, paths with spaces are safe).

let s:save_cpo = &cpo | set cpo&vim

function! s:Word() abort
  let w = expand('<cword>')
  if w !~# '^\h\w*$'
    echohl WarningMsg | echomsg 'RTL: no identifier under cursor' | echohl None
    return ''
  endif
  return w
endfunction

function! s:LspReady(cap) abort
  return exists('*rtl#lsp#Has') && rtl#lsp#Has(a:cap)
endfunction

" --------------------------------------------------------- definition ---
function! rtl#nav#Definition() abort
  let w = s:Word()
  if empty(w) | return | endif
  if s:LspReady('definitionProvider')
    if rtl#lsp#Definition()
      return
    endif
    echo 'RTL: LSP found no definition, trying tags'
  endif
  if !empty(tagfiles()) && !empty(taglist('^' . w . '$'))
    try
      execute 'tjump ' . w
    catch
      echohl ErrorMsg | echomsg substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '') | echohl None
    endtry
    return
  endif
  " buffer-local fallback: first declaration line mentioning the word
  let pat = '\C^\s*\%(module\|task\|function\|input\|output\|inout\|wire\|reg\|logic\|parameter\|localparam\|integer\|genvar\|typedef\|signal\|constant\|variable\|entity\|architecture\|component\)\>.*\<' . w . '\>'
  let lnum = search(pat, 'wn')
  if lnum > 0
    normal! m'
    call cursor(lnum, 1)
    call search('\<' . w . '\>', 'c', lnum)
    echo 'RTL: declaration in current buffer (no tags: run :RtlTags for project-wide jumps)'
    return
  endif
  " last resort: is it a module defined somewhere in the project?
  let f = rtl#symbols#FindModuleFile(w)
  if !empty(f)
    normal! m'
    execute 'edit ' . fnameescape(f)
    call search('\C^\s*\%(module\|interface\)\s\+' . w . '\>', 'w')
    return
  endif
  echohl WarningMsg | echomsg 'RTL: no definition found for "' . w . '" (try :RtlTags)' | echohl None
endfunction

" --------------------------------------------------------- references ---
function! rtl#nav#References() abort
  let w = s:Word()
  if empty(w) | return | endif
  if s:LspReady('referencesProvider')
    if rtl#lsp#References()
      return
    endif
  endif
  call s:VimGrep('\C\<' . w . '\>', 'text references (word search): ' . w)
endfunction

" --------------------------------------------------------- instances ---
function! rtl#nav#Instances(name) abort
  let w = empty(a:name) ? s:Word() : a:name
  if empty(w) | return | endif
  " instantiation head:  ^ <module> [#(] <inst> ... (   or  ^ <module> #(
  call s:VimGrep('\C^\s*' . w . '\s\+\%(#\|\h\w*\s*\%(\[[^]]*\]\s*\)\?(\|\h\w*\s*$\)', 'instances of ' . w)
endfunction

" --------------------------------------------------------------- grep ---
function! rtl#nav#Grep(pattern) abort
  call s:VimGrep(a:pattern, 'grep: ' . a:pattern)
endfunction

function! rtl#nav#GrepWord() abort
  let w = s:Word()
  if empty(w) | return | endif
  call s:VimGrep('\C\<' . w . '\>', 'grep: ' . w)
endfunction

function! s:VimGrep(pattern, title) abort
  let files = rtl#project#Files()
  if empty(files)
    echohl WarningMsg | echomsg 'RTL: no project files (root: ' . rtl#project#Root() . ')' | echohl None
    return
  endif
  let args = join(map(copy(files), 'fnameescape(v:val)'), ' ')
  try
    " 'j' = do not jump, 'g' = all matches per line
    execute 'noautocmd vimgrep /' . escape(a:pattern, '/') . '/gj ' . args
  catch /E480/
    echo 'RTL: no matches for ' . a:pattern
    return
  catch
    echohl ErrorMsg | echomsg substitute(v:exception, '^Vim\%((\a\+)\)\=:', '', '') | echohl None
    return
  endtry
  if has('patch-7.4.2200')
    call setqflist([], 'a', {'title': 'RTL ' . a:title})
  endif
  let n = len(getqflist())
  copen
  echo 'RTL: ' . n . ' match(es) - ' . a:title
endfunction

" ---------------------------------------------------------- buffers ---
function! rtl#nav#AltBuffer() abort
  if bufnr('#') > 0 && buflisted(bufnr('#'))
    buffer #
  else
    echo 'RTL: no alternate buffer'
  endif
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
