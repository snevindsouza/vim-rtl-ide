" autoload/rtl/complete.vim -- context-aware omni completion (CTRL-X CTRL-O)
"
" Sources, in priority order, deduplicated:
"   [LSP]   textDocument/completion when a language server that advertises
"           completionProvider is running (optional; Verible does not).
"   [port]  port names of the module being instantiated, when the cursor is
"           inside   mod inst ( .| ...  -- parsed from the module's header.
"   [param] parameter names inside   mod #( .| ...
"   [sig]   declarations in the current buffer (ports, nets, regs, params,
"           tasks, functions, typedefs, `defines)
"   [buf]   declarations in other loaded Verilog/SV buffers
"   [tag]   modules/tasks/functions from the project tags file
"   [kw]    language keywords / constructs from ~/.vim/dict/<ft>.dict
"
" None of this is semantic: it is declaration pattern matching plus the
" tags index.  It never scans the filesystem; project data comes from the
" tags file (:RtlTags) and in-memory buffers.

let s:save_cpo = &cpo | set cpo&vim

let s:dict_cache = {}

function! s:Dict(ft) abort
  if has_key(s:dict_cache, a:ft) | return s:dict_cache[a:ft] | endif
  let words = []
  for f in split(globpath(&runtimepath, 'dict/' . a:ft . '.dict'), '\n')
    let words += filter(readfile(f), 'v:val !~# "^\\s*\\(#\\|$\\)"')
  endfor
  let s:dict_cache[a:ft] = words
  return words
endfunction

" Omni function (see :help complete-functions).
function! rtl#complete#Omni(findstart, base) abort
  if a:findstart
    let line = getline('.')
    let col = col('.') - 1
    " `include "   -> file name completion start
    if line =~# '^\s*`include\s\+"[^"]*$'
      let s:mode = 'include'
      return matchend(line, '^\s*`include\s\+"')
    endif
    let start = col
    while start > 0 && line[start - 1] =~# '[A-Za-z0-9_$`]'
      let start -= 1
    endwhile
    " after a '.' inside an instantiation: port/param context
    let s:mode = 'ident'
    let s:dot = (start > 0 && line[start - 1] ==# '.')
    return start
  endif

  let ft = &filetype
  let items = []
  let seen = {}

  if get(s:, 'mode', '') ==# 'include'
    return s:IncludeFiles(a:base)
  endif

  " 1. LSP (only if the server advertises completion; cheap no-op otherwise)
  if exists('*rtl#lsp#Completion')
    for it in rtl#lsp#Completion(a:base)
      call s:Push(items, seen, it)
    endfor
  endif

  " 2. instantiation context
  if ft =~# '^\%(verilog\|systemverilog\)$'
    let ctx = rtl#symbols#InstContext()
    if !empty(ctx)
      let info = rtl#symbols#ModuleInfo(ctx.module)
      if !empty(info)
        if ctx.section ==# 'params'
          for p in info.params
            call s:Push(items, seen, {'word': p.name, 'kind': 'P',
                  \ 'menu': '[param] ' . ctx.module . (empty(p.default) ? '' : ' = ' . p.default)})
          endfor
        else
          for p in info.ports
            call s:Push(items, seen, {'word': p.name, 'kind': 'p',
                  \ 'menu': '[port] ' . p.dir . ' ' . p.range})
          endfor
        endif
        " when typing after '.', these are the only sensible answers
        if s:dot
          return s:Filter(items, a:base)
        endif
      endif
    endif
  endif

  " 3. current buffer declarations
  for sym in rtl#symbols#Buffer(bufnr('%'))
    call s:Push(items, seen, {'word': sym.word, 'kind': s:KindChar(sym.kind),
          \ 'menu': '[sig] ' . sym.kind})
  endfor

  " 4. other loaded RTL buffers
  for b in range(1, bufnr('$'))
    if b == bufnr('%') || !bufloaded(b) | continue | endif
    if getbufvar(b, '&filetype') !~# '^\%(verilog\|systemverilog\|vhdl\)$' | continue | endif
    for sym in rtl#symbols#Buffer(b)
      call s:Push(items, seen, {'word': sym.word, 'kind': s:KindChar(sym.kind),
            \ 'menu': '[buf] ' . sym.menu})
    endfor
  endfor

  " 5. tags (modules, tasks, functions ... ) - bounded by prefix
  if !empty(a:base) && !empty(tagfiles())
    for t in taglist('^' . a:base)
      call s:Push(items, seen, {'word': t.name, 'kind': get(t, 'kind', 't')[0],
            \ 'menu': '[tag] ' . fnamemodify(t.filename, ':t')})
    endfor
  endif

  " 6. keywords
  for w in s:Dict(ft)
    call s:Push(items, seen, {'word': w, 'kind': 'k', 'menu': '[kw]'})
  endfor

  return s:Filter(items, a:base)
endfunction

function! s:Push(items, seen, it) abort
  if has_key(a:seen, a:it.word) | return | endif
  let a:seen[a:it.word] = 1
  call add(a:items, a:it)
endfunction

function! s:KindChar(kind) abort
  return get({'module': 'm', 'task': 't', 'function': 'f', 'port': 'p', 'net': 'w',
        \ 'reg': 'r', 'var': 'v', 'param': 'P', 'typedef': 'T', 'define': 'd',
        \ 'interface': 'i', 'package': 'K', 'class': 'C'}, a:kind, 's')
endfunction

function! s:Filter(items, base) abort
  if empty(a:base) | return a:items | endif
  let pre = []
  let sub = []
  let lb = tolower(a:base)
  for it in a:items
    let lw = tolower(it.word)
    if stridx(lw, lb) == 0
      call add(pre, it)
    elseif stridx(lw, lb) > 0
      call add(sub, it)
    endif
  endfor
  return pre + sub
endfunction

function! s:IncludeFiles(base) abort
  let out = []
  let seen = {}
  for f in rtl#project#Files()
    let t = fnamemodify(f, ':t')
    if stridx(t, a:base) == 0 && !has_key(seen, t)
      let seen[t] = 1
      call add(out, {'word': t, 'kind': 'F', 'menu': '[inc] ' . fnamemodify(f, ':h:t')})
    endif
  endfor
  return out
endfunction

" ------------------------------------------- insert-mode trigger keys ---
" Smart <Tab>: completion after an identifier character or '.', a real tab
" (or indent) otherwise.  Buffer-local, see ftplugin.
function! rtl#complete#SmartTab() abort
  if pumvisible()
    return "\<C-n>"
  endif
  let col = col('.') - 1
  let line = getline('.')
  if col <= 0 || line[col - 1] !~# '[A-Za-z0-9_$`.]'
    return "\<Tab>"
  endif
  return "\<C-x>\<C-o>"
endfunction

function! rtl#complete#SmartSTab() abort
  return pumvisible() ? "\<C-p>" : "\<S-Tab>"
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
