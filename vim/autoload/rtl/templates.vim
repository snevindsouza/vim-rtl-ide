" autoload/rtl/templates.vim -- snippets without a snippet plugin
"
" Templates are plain text files:  ~/.vim/templates/<filetype>/<name>.tmpl
" (verilog templates are also used for systemverilog unless a
" templates/systemverilog/<name>.tmpl exists).  Placeholders:
"   {{name}}   module/entity name (argument, else prompted, else file stem)
"   {{clk}}    clock signal name       (g:rtl_clk_name,  default clk)
"   {{rst}}    reset signal name       (g:rtl_rst_name,  default rst_n)
"   {{rst_active}}  reset condition ("!rst_n" or "rst"); {{rst_edge}} negedge/posedge
"   {{rst_assert}} {{rst_deassert}} 1'b0/1'b1 for testbenches; {{rst_vhdl}} '0'/'1'
"   {{file}}   current file name       {{date}}  YYYY-MM-DD   {{user}}  $USER
"   {{cursor}} where the cursor lands after insertion (optional, once)
" Lines are inserted below the cursor with the current line's indentation
" and are NOT re-indented through 'indentexpr' (templates are already laid
" out), so what is in the template file is what you get.
"
" :RtlInstantiate <module> builds an instantiation from the module header
" found via tags / project files (see rtl#symbols#ModuleInfo).

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_clk_name = get(g:, 'rtl_clk_name', 'clk')
let g:rtl_rst_name = get(g:, 'rtl_rst_name', 'rst_n')
let g:rtl_inst_prefix = get(g:, 'rtl_inst_prefix', 'u_')

function! s:TemplateDirs() abort
  let ft = &filetype
  let dirs = []
  if ft ==# 'systemverilog'
    let dirs += split(globpath(&runtimepath, 'templates/systemverilog'), '\n')
    let dirs += split(globpath(&runtimepath, 'templates/verilog'), '\n')
  else
    let dirs += split(globpath(&runtimepath, 'templates/' . ft), '\n')
  endif
  return dirs
endfunction

function! rtl#templates#List() abort
  let names = {}
  for d in s:TemplateDirs()
    for f in split(glob(escape(d, '[]*?{}') . '/*.tmpl', 1), '\n')
      let names[fnamemodify(f, ':t:r')] = 1
    endfor
  endfor
  return sort(keys(names))
endfunction

function! s:Find(name) abort
  for d in s:TemplateDirs()
    let f = d . '/' . a:name . '.tmpl'
    if filereadable(f) | return f | endif
  endfor
  return ''
endfunction

function! s:Vars(name) abort
  let rst = g:rtl_rst_name
  let low = rst =~# '_n$\|_b$\|n$'       " active-low reset naming convention
  return {
        \ 'name': a:name,
        \ 'clk': g:rtl_clk_name,
        \ 'rst': rst,
        \ 'rst_active': (low ? '!' . rst : rst),
        \ 'rst_edge': (low ? 'negedge' : 'posedge'),
        \ 'rst_assert': (low ? "1'b0" : "1'b1"),
        \ 'rst_deassert': (low ? "1'b1" : "1'b0"),
        \ 'rst_vhdl': (low ? '0' : '1'),
        \ 'file': expand('%:t'),
        \ 'date': strftime('%Y-%m-%d'),
        \ 'user': empty($USER) ? 'user' : $USER,
        \ }
endfunction

function! s:Expand(lines, vars) abort
  let out = []
  for l in a:lines
    let l = substitute(l, '{{\(\w\+\)}}', '\=get(a:vars, submatch(1), submatch(0))', 'g')
    call add(out, l)
  endfor
  return out
endfunction

" Insert lines below the cursor, prefixed with the current indentation.
" Places the cursor at {{cursor}} if present.  Single undo block.
function! s:Put(lines) abort
  let indent = matchstr(getline('.'), '^\s*')
  if getline('.') =~# '^\s*$'
    let indent = repeat(' ', indent(line('.')))
  endif
  let lines = map(copy(a:lines), 'empty(v:val) ? "" : indent . v:val')
  let cur = -1
  let curcol = 0
  let i = 0
  for l in lines
    let p = stridx(l, '{{cursor}}')
    if p >= 0
      let lines[i] = substitute(l, '{{cursor}}', '', '')
      let cur = i
      let curcol = p + 1
    endif
    let i += 1
  endfor
  let lnum = line('.')
  if getline(lnum) =~# '^\s*$'
    " replace the empty line instead of leaving it above the template
    call setline(lnum, lines[0])
    call append(lnum, lines[1:])
    let lnum -= 1
  else
    call append(lnum, lines)
  endif
  if cur >= 0
    call cursor(lnum + 1 + cur, max([curcol, 1]))
  else
    call cursor(lnum + 1, 1)
  endif
endfunction

function! rtl#templates#Insert(name) abort
  let avail = rtl#templates#List()
  if empty(avail)
    echohl WarningMsg | echomsg 'RTL: no templates for filetype ' . &filetype | echohl None
    return
  endif
  let name = a:name
  if empty(name)
    let choice = inputlist(['RTL template:'] + map(copy(avail), '(v:key + 1) . ". " . v:val'))
    if choice < 1 || choice > len(avail) | return | endif
    let name = avail[choice - 1]
  endif
  let f = s:Find(name)
  if empty(f)
    echohl WarningMsg | echomsg 'RTL: no template "' . name . '" (' . join(avail, ', ') . ')' | echohl None
    return
  endif
  let mod = empty(expand('%:t:r')) ? 'top' : expand('%:t:r')
  call s:Put(s:Expand(readfile(f), s:Vars(mod)))
endfunction

function! rtl#templates#CompleteName(lead, line, pos) abort
  return filter(rtl#templates#List(), 'v:val =~# "^" . a:lead')
endfunction

" Module / entity skeleton.
function! rtl#templates#Module(name) abort
  let name = a:name
  if empty(name)
    let name = input('Module name: ', expand('%:t:r'))
    if empty(name) | return | endif
  endif
  let tname = &filetype ==# 'vhdl' ? 'entity' : 'module'
  let f = s:Find(tname)
  if empty(f)
    echohl WarningMsg | echomsg 'RTL: template "' . tname . '" not installed' | echohl None
    return
  endif
  let lines = s:Expand(readfile(f), s:Vars(name))
  if line('$') == 1 && getline(1) =~# '^\s*$'
    call setline(1, lines[0])
    call append(1, lines[1:])
    let lnum = 1
    for l in lines
      let p = stridx(l, '{{cursor}}')
      if p >= 0
        call setline(lnum, substitute(l, '{{cursor}}', '', ''))
        call cursor(lnum, max([p + 1, 1]))
        return
      endif
      let lnum += 1
    endfor
    call cursor(1, 1)
  else
    call s:Put(lines)
  endif
endfunction

" ------------------------------------------------- instantiation ---
function! rtl#templates#Instantiate(name) abort
  let name = a:name
  if empty(name)
    let name = expand('<cword>')
    if name !~# '^\h\w*$'
      let name = input('Module to instantiate: ', '', 'customlist,rtl#symbols#CompleteModule')
    endif
  endif
  if empty(name) | return | endif
  let info = rtl#symbols#ModuleInfo(name)
  if empty(info)
    echohl WarningMsg
    echomsg 'RTL: module "' . name . '" not found (open its file, or run :RtlTags)'
    echohl None
    return
  endif
  let lines = rtl#templates#InstanceLines(info)
  " if the cursor line is exactly the module name (just typed), replace it
  if getline('.') =~# '^\s*' . name . '\s*$'
    let indent = matchstr(getline('.'), '^\s*')
    call setline('.', indent . lines[0])
    call append(line('.'), map(lines[1:], 'empty(v:val) ? "" : indent . v:val'))
  else
    call s:Put(lines)
  endif
  echo 'RTL: instantiated ' . name . ' from ' . fnamemodify(info.file, ':~:.')
        \ . ' (' . len(info.params) . ' params, ' . len(info.ports) . ' ports)'
endfunction

function! rtl#templates#InstanceLines(info) abort
  let sw = repeat(' ', &shiftwidth > 0 ? &shiftwidth : 2)
  let lines = []
  let inst = g:rtl_inst_prefix . a:info.name
  let w = 0
  for p in a:info.params + a:info.ports
    let w = max([w, len(p.name)])
  endfor
  if !empty(a:info.params)
    call add(lines, a:info.name . ' #(')
    let i = 0
    for p in a:info.params
      let i += 1
      let dflt = get(p, 'default', '')
      let val = empty(dflt) ? p.name : dflt
      call add(lines, sw . '.' . p.name . repeat(' ', w - len(p.name)) . ' (' . val . ')'
            \ . (i < len(a:info.params) ? ',' : ''))
    endfor
    call add(lines, ') ' . inst . ' (')
  else
    call add(lines, a:info.name . ' ' . inst . ' (')
  endif
  let i = 0
  for p in a:info.ports
    let i += 1
    let comment = empty(p.dir) ? '' : '  // ' . p.dir . (empty(p.range) ? '' : ' ' . p.range)
    call add(lines, sw . '.' . p.name . repeat(' ', w - len(p.name)) . ' (' . p.name . ')'
          \ . (i < len(a:info.ports) ? ',' : ' ') . comment)
  endfor
  call add(lines, ');')
  return lines
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
