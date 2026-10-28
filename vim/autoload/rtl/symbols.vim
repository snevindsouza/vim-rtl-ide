" autoload/rtl/symbols.vim -- lightweight Verilog/SystemVerilog symbol
" extraction in pure Vimscript.
"
" This is TEXT PATTERN analysis, not elaboration: it reads declarations
" (module headers, wire/reg/logic/parameter/task/function lines) and is
" accurate for ordinary synthesizable RTL.  It is used for completion,
" :RtlInstantiate and tag generation when ctags is missing.

let s:save_cpo = &cpo | set cpo&vim

" Verilog-2005 keywords that can start a declaration of a named object.
let s:decl_kinds = {
      \ 'input': 'port', 'output': 'port', 'inout': 'port',
      \ 'wire': 'net', 'tri': 'net', 'tri0': 'net', 'tri1': 'net',
      \ 'wand': 'net', 'wor': 'net', 'supply0': 'net', 'supply1': 'net',
      \ 'reg': 'reg', 'logic': 'reg', 'bit': 'reg', 'byte': 'reg',
      \ 'integer': 'var', 'int': 'var', 'genvar': 'var', 'real': 'var',
      \ 'time': 'var', 'shortint': 'var', 'longint': 'var',
      \ 'parameter': 'param', 'localparam': 'param', 'specparam': 'param',
      \ }
let s:decl_re = '\C^\s*\%(' . join(keys(s:decl_kinds), '\|') . '\)\>'

let s:buf_cache = {}   " bufnr -> {tick, syms}

" ------------------------------------------------- comment stripping ---
function! s:StripComments(lines) abort
  let out = []
  let in_block = 0
  for l in a:lines
    let line = l
    if in_block
      let e = matchend(line, '\*/')
      if e < 0 | continue | endif
      let line = strpart(line, e)
      let in_block = 0
    endif
    " remove complete /* */ on one line, then a trailing // comment
    let line = substitute(line, '/\*.\{-}\*/', ' ', 'g')
    let s = match(line, '/\*')
    if s >= 0
      let line = strpart(line, 0, s)
      let in_block = 1
    endif
    let line = substitute(line, '//.*$', '', '')
    call add(out, line)
  endfor
  return out
endfunction

" ------------------------------------------------------ buffer symbols ---
" Returns a list of {word, kind, menu} for declarations in buffer `bufnr`.
" Cached on b:changedtick, so repeated completion in an unchanged buffer
" costs nothing.
function! rtl#symbols#Buffer(bufnr) abort
  let tick = getbufvar(a:bufnr, 'changedtick', -1)
  let key = string(a:bufnr)
  if has_key(s:buf_cache, key) && s:buf_cache[key].tick == tick
    return s:buf_cache[key].syms
  endif
  let lines = getbufline(a:bufnr, 1, '$')
  let syms = rtl#symbols#FromLines(lines, fnamemodify(bufname(a:bufnr), ':t'))
  let s:buf_cache[key] = {'tick': tick, 'syms': syms}
  return syms
endfunction

" Core scanner used for buffers and for files on disk (tag index).
" Each item: {word, kind, menu, lnum, line}
function! rtl#symbols#FromLines(raw_lines, label) abort
  let lines = s:StripComments(a:raw_lines)
  let syms = []
  let seen = {}
  let lnum = 0
  for line in lines
    let lnum += 1
    " module / interface / package / primitive
    let m = matchlist(line, '\C^\s*\(module\|macromodule\|interface\|package\|primitive\|program\|class\)\s\+\(\h\w*\)')
    if !empty(m)
      call s:Add(syms, seen, m[2], m[1] ==# 'module' || m[1] ==# 'macromodule' ? 'module' : m[1], a:label, lnum, line)
      continue
    endif
    " task / function  (function [automatic] [type] [range] name)
    let m = matchlist(line, '\C^\s*\(task\|function\)\>.\{-}\<\(\h\w*\)\s*[(;]')
    if empty(m)
      let m = matchlist(line, '\C^\s*\(task\|function\)\>.\{-}\<\(\h\w*\)\s*$')
    endif
    if !empty(m)
      call s:Add(syms, seen, m[2], m[1], a:label, lnum, line)
      continue
    endif
    " typedef
    let m = matchlist(line, '\C^\s*typedef\>.\{-}\<\(\h\w*\)\s*;')
    if !empty(m)
      call s:Add(syms, seen, m[1], 'typedef', a:label, lnum, line)
      continue
    endif
    " `define
    let m = matchlist(line, '^\s*`define\s\+\(\h\w*\)')
    if !empty(m)
      call s:Add(syms, seen, m[1], 'define', a:label, lnum, line)
      continue
    endif
    " data / port / parameter declarations
    if line =~# s:decl_re
      let kw = matchstr(line, '^\s*\zs\h\w*')
      let kind = s:decl_kinds[kw]
      for name in s:DeclNames(line)
        call s:Add(syms, seen, name, kind, a:label, lnum, line)
      endfor
    endif
  endfor
  return syms
endfunction

function! s:Add(syms, seen, word, kind, label, lnum, line) abort
  if has_key(a:seen, a:word) | return | endif
  let a:seen[a:word] = 1
  call add(a:syms, {'word': a:word, 'kind': a:kind, 'menu': a:label,
        \ 'lnum': a:lnum, 'line': a:line})
endfunction

" Names declared on one declaration line.
"   "input wire [7:0] a, b,"           -> [a, b]
"   "reg [3:0] cnt = 0, flag;"         -> [cnt, flag]
"   "parameter integer W = 8, D = 2;"  -> [W, D]
"   "output reg [W-1:0] q [0:3]"       -> [q]
function! s:DeclNames(line) abort
  let txt = a:line
  " drop everything after '=' inside each comma item later; first cut ';'
  let txt = substitute(txt, ';.*$', '', '')
  " drop the trailing ')' of an ANSI header end
  let txt = substitute(txt, ')\s*$', '', '')
  " remove bracketed ranges / dimensions (possibly nested params)
  let txt = substitute(txt, '\[[^][]*\]', ' ', 'g')
  let txt = substitute(txt, '\[[^][]*\]', ' ', 'g')
  " remove leading keywords and type words
  let txt = substitute(txt, '^\s*\%(input\|output\|inout\|wire\|tri\|tri0\|tri1\|wand\|wor\|supply0\|supply1\|reg\|logic\|bit\|byte\|integer\|int\|genvar\|real\|time\|shortint\|longint\|parameter\|localparam\|specparam\|signed\|unsigned\|var\|const\|automatic\|static\)\>\s*', '', '')
  while txt =~# '^\s*\%(wire\|reg\|logic\|bit\|byte\|integer\|int\|real\|time\|signed\|unsigned\|var\)\>'
    let txt = substitute(txt, '^\s*\h\w*\>\s*', '', '')
  endwhile
  let names = []
  for item in split(txt, ',')
    let item = substitute(item, '=.*$', '', '')
    " type name may precede: "my_t foo" -> last identifier is the name
    let ids = []
    call substitute(item, '\<\h\w*\>', '\=add(ids, submatch(0))', 'g')
    if !empty(ids)
      call add(names, ids[-1])
    endif
  endfor
  return names
endfunction

" ------------------------------------------------------- module lookup ---
" Find the file defining module `name`.  Order: tags file (ctags or our
" own index), then open buffers, then a bounded grep over project files.
function! rtl#symbols#FindModuleFile(name) abort
  " 1. tags
  for t in taglist('^' . a:name . '$')
    if get(t, 'kind', '') =~# '^[mi]' && filereadable(t.filename)
      return t.filename
    endif
  endfor
  " 2. open buffers
  for b in range(1, bufnr('$'))
    if !bufloaded(b) | continue | endif
    if getbufvar(b, '&filetype') !~# '^\%(verilog\|systemverilog\)$' | continue | endif
    for l in getbufline(b, 1, '$')
      if l =~# '^\s*\%(module\|macromodule\|interface\)\s\+' . a:name . '\>'
        return fnamemodify(bufname(b), ':p')
      endif
    endfor
  endfor
  " 3. project files: a file named <name>.v/.sv is tried first, then scan
  let files = rtl#project#Files()
  for f in files
    if fnamemodify(f, ':t:r') ==# a:name
      for l in readfile(f, '', 400)
        if l =~# '^\s*\%(module\|macromodule\|interface\)\s\+' . a:name . '\>'
          return f
        endif
      endfor
    endif
  endfor
  for f in files
    if f !~? '\.\%(v\|sv\|vh\|svh\)$' | continue | endif
    for l in readfile(f)
      if l =~# '^\s*\%(module\|macromodule\|interface\)\s\+' . a:name . '\>'
        return f
      endif
    endfor
  endfor
  return ''
endfunction

" Module header information:
"   {name, file, params: [{name, default}], ports: [{name, dir, range}]}
" Returns {} when the module cannot be found.
function! rtl#symbols#ModuleInfo(name) abort
  let file = rtl#symbols#FindModuleFile(a:name)
  if empty(file) | return {} | endif
  let bnr = bufnr(file)
  if bnr > 0 && bufloaded(bnr)
    let lines = getbufline(bnr, 1, '$')
  else
    let lines = readfile(file)
  endif
  let lines = s:StripComments(lines)
  " locate header: from 'module name' to the first ';' at paren depth 0
  let start = -1
  let i = 0
  for l in lines
    if l =~# '^\s*\%(module\|macromodule\|interface\)\s\+' . a:name . '\>'
      let start = i
      break
    endif
    let i += 1
  endfor
  if start < 0 | return {} | endif
  let header = ''
  let depth = 0
  let done = 0
  for l in lines[start :]
    for ch in split(l, '\zs')
      if ch ==# '(' | let depth += 1
      elseif ch ==# ')' | let depth -= 1
      elseif ch ==# ';' && depth <= 0
        let done = 1
        break
      endif
      let header .= ch
    endfor
    if done | break | endif
    let header .= ' '
    if len(header) > 200000 | break | endif
  endfor
  let header = substitute(header, '^\s*\%(module\|macromodule\|interface\)\s\+' . a:name . '\>', '', '')
  let info = {'name': a:name, 'file': file, 'params': [], 'ports': []}
  " parameters:  #( ... )
  let pm = matchstr(header, '^\s*#\s*(')
  let rest = header
  if !empty(pm)
    let [body, rest] = s:ParenBody(strpart(header, len(pm) - 1))
    for item in s:SplitTop(body)
      let item = substitute(item, '^\s*\%(parameter\|localparam\)\>', '', '')
      let m = matchlist(item, '\<\(\h\w*\)\s*=\s*\(.*\)$')
      if !empty(m)
        call add(info.params, {'name': m[1], 'default': substitute(m[2], '\s*$', '', '')})
      else
        let ids = []
        call substitute(substitute(item, '\[[^][]*\]', '', 'g'), '\<\h\w*\>', '\=add(ids, submatch(0))', 'g')
        if !empty(ids)
          call add(info.params, {'name': ids[-1], 'default': ''})
        endif
      endif
    endfor
  endif
  " ports: ( ... )
  let pp = match(rest, '(')
  if pp >= 0
    let [body, rest2] = s:ParenBody(strpart(rest, pp))
    let dir = ''
    let range = ''
    for item in s:SplitTop(body)
      let item = substitute(item, '^\s\+\|\s\+$', '', 'g')
      if empty(item) | continue | endif
      let d = matchstr(item, '^\%(input\|output\|inout\|ref\)\>')
      if !empty(d)
        let dir = d
        let range = matchstr(item, '\[[^][]*\]')
      endif
      let nm = substitute(item, '\[[^][]*\]', ' ', 'g')
      let nm = substitute(nm, '=.*$', '', '')
      let ids = []
      call substitute(nm, '\<\h\w*\>', '\=add(ids, submatch(0))', 'g')
      if !empty(ids)
        let name = ids[-1]
        if name =~# '^\%(input\|output\|inout\|wire\|reg\|logic\|signed\|unsigned\)$'
          continue
        endif
        call add(info.ports, {'name': name, 'dir': dir, 'range': range})
      endif
    endfor
    " non-ANSI header: directions live in the body -> look them up
    if !empty(info.ports) && empty(info.ports[0].dir)
      let dirs = {}
      for l in lines[start :]
        if l =~# '^\s*endmodule\>' | break | endif
        if l =~# '^\s*\%(input\|output\|inout\)\>'
          let d = matchstr(l, '^\s*\zs\%(input\|output\|inout\)')
          let r = matchstr(l, '\[[^][]*\]')
          for n in s:DeclNames(l)
            let dirs[n] = {'dir': d, 'range': r}
          endfor
        endif
      endfor
      for p in info.ports
        if has_key(dirs, p.name)
          let p.dir = dirs[p.name].dir
          let p.range = dirs[p.name].range
        endif
      endfor
    endif
  endif
  return info
endfunction

" Given text starting at '(', return [inner, rest-after-matching-')']
function! s:ParenBody(txt) abort
  let depth = 0
  let i = 0
  let n = len(a:txt)
  while i < n
    let ch = a:txt[i]
    if ch ==# '('
      let depth += 1
    elseif ch ==# ')'
      let depth -= 1
      if depth == 0
        return [strpart(a:txt, 1, i - 1), strpart(a:txt, i + 1)]
      endif
    endif
    let i += 1
  endwhile
  return [strpart(a:txt, 1), '']
endfunction

" Split on commas that are not nested inside () or [] or {}
function! s:SplitTop(txt) abort
  let parts = []
  let cur = ''
  let depth = 0
  for ch in split(a:txt, '\zs')
    if ch =~# '[([{]'
      let depth += 1
    elseif ch =~# '[)\]}]'
      let depth -= 1
    elseif ch ==# ',' && depth == 0
      call add(parts, cur)
      let cur = ''
      continue
    endif
    let cur .= ch
  endfor
  call add(parts, cur)
  return parts
endfunction

" Names of all modules known via tags; fallback: scan project files.
function! rtl#symbols#ModuleNames() abort
  let names = {}
  for t in taglist('^\h\w*$')
    if get(t, 'kind', '') =~# '^[mi]'
      let names[t.name] = 1
    endif
  endfor
  if empty(names)
    for b in range(1, bufnr('$'))
      if bufloaded(b) && getbufvar(b, '&filetype') =~# '^\%(verilog\|systemverilog\)$'
        for s in rtl#symbols#Buffer(b)
          if s.kind ==# 'module' | let names[s.word] = 1 | endif
        endfor
      endif
    endfor
  endif
  return sort(keys(names))
endfunction

function! rtl#symbols#CompleteModule(lead, line, pos) abort
  return filter(rtl#symbols#ModuleNames(), 'v:val =~# "^" . a:lead')
endfunction

" ------------------------------------------- instantiation context ---
" Looks backward from the cursor for an enclosing module instantiation:
"     mod #( .P(1) ) u_mod ( .a(a), .b(b) );
" Returns {'module': name, 'section': 'params'|'ports'} or {}.
" Bounded to 300 lines upward and stops at ';' of a previous statement.
function! rtl#symbols#InstContext() abort
  let curlnum = line('.')
  let curtext = strpart(getline(curlnum), 0, col('.') - 1)
  let lnum = curlnum
  let text = curtext
  let n = 0
  let kw = '\%(module\|always\|initial\|if\|else\|for\|while\|case\|casez\|casex\|assign\|begin\|end\|function\|task\|generate\|wire\|reg\|logic\|input\|output\|inout\|parameter\|localparam\|integer\|genvar\|return\|repeat\|forever\|default\|endmodule\|endcase\|endgenerate\|endfunction\|endtask\|fork\|join\|typedef\|enum\|struct\|import\|package\|interface\|modport\|initial\|deassign\|force\|release\|disable\|wait\)'
  while lnum >= 1 && n < 300
    let stripped = substitute(text, '//.*$', '', '')
    " a finished statement above (or before the cursor) ends the search
    if stripped =~# ';\s*$'
      return {}
    endif
    " instantiation head on this line?   mod #(   |   mod inst (   |   mod inst
    let m = matchlist(stripped, '^\s*\(\h\w*\)\s*')
    if !empty(m) && m[1] !~# '^' . kw . '$'
      let tail = strpart(stripped, len(m[0]))
      if tail =~# '^#' || tail =~# '^\h\w*\s*\%(\[[^]]*\]\s*\)\?('
            \ || (tail =~# '^\h\w*\s*$' && n > 0)
        let section = 'ports'
        if tail =~# '^#'
          " inside #( ... ) until its matching ')' is seen before the cursor
          let after = strpart(stripped, matchend(stripped, '^\s*\h\w*\s*#\s*(\?'))
          if lnum == curlnum
            let body = after
          else
            let body = join([after] + getline(lnum + 1, curlnum - 1) + [curtext], "\n")
          endif
          let depth = 1
          let closed = 0
          for ch in split(body, '\zs')
            if ch ==# '('
              let depth += 1
            elseif ch ==# ')'
              let depth -= 1
              if depth == 0
                let closed = 1
                break
              endif
            endif
          endfor
          let section = closed ? 'ports' : 'params'
        endif
        return {'module': m[1], 'section': section}
      endif
    endif
    let lnum -= 1
    let n += 1
    let text = getline(lnum)
  endwhile
  return {}
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
