" autoload/rtl/tags.vim -- project tag index
"
" :RtlTags writes <root>/tags.  Two back ends:
"   1. ctags (Universal Ctags preferred, Exuberant Ctags accepted) fed an
"      explicit file list (-L), so excluded directories are never visited
"      and paths with spaces are safe.  Universal Ctags supports Verilog,
"      SystemVerilog and VHDL; Exuberant Ctags supports Verilog and VHDL.
"   2. Pure Vimscript fallback (rtl#symbols#FromLines): modules, tasks,
"      functions, parameters, ports, nets, regs, typedefs and `defines for
"      Verilog/SV; entities, architectures, components, signals, procedures,
"      functions, constants and types for VHDL.  Writes the same tags file
"      format, so <C-]>, :tag, :tselect, i_CTRL-X_CTRL-] all work.
"
" Both back ends produce ordinary text-level tags: a tag is a declaration
" found by pattern, not an elaborated design object.

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_ctags_cmd = get(g:, 'rtl_ctags_cmd', '')   " '' = autodetect

" kind letters we emit in the fallback indexer (match universal-ctags
" verilog kinds where they exist so :tselect output is consistent)
let s:kind_letter = {
      \ 'module': 'm', 'interface': 'i', 'package': 'K', 'primitive': 'm',
      \ 'program': 'm', 'class': 'C', 'task': 't', 'function': 'f',
      \ 'typedef': 'T', 'define': 'd', 'param': 'c', 'port': 'p',
      \ 'net': 'n', 'reg': 'r', 'var': 'r',
      \ 'entity': 'e', 'architecture': 'a', 'component': 'c',
      \ 'signal': 's', 'constant': 'C', 'type': 't', 'procedure': 'p',
      \ 'process': 'P',
      \ }

function! rtl#tags#CtagsExe() abort
  if !empty(g:rtl_ctags_cmd)
    return executable(g:rtl_ctags_cmd) ? g:rtl_ctags_cmd : ''
  endif
  for exe in ['ctags-universal', 'universal-ctags', 'uctags', 'ctags-exuberant', 'exuberant-ctags', 'ctags']
    if executable(exe)
      " GNU/Emacs 'etags'-style ctags on some distros is useless here
      let ver = system(exe . ' --version')
      if ver =~? 'universal\|exuberant'
        return exe
      endif
    endif
  endfor
  return ''
endfunction

function! rtl#tags#CtagsFlavour(exe) abort
  let ver = system(a:exe . ' --version')
  return ver =~? 'universal' ? 'universal' : (ver =~? 'exuberant' ? 'exuberant' : 'unknown')
endfunction

" Make <root>/tags findable from any buffer in the project.
function! rtl#tags#SetTagsOption() abort
  let root = rtl#project#Root()
  let tf = escape(root . '/tags', ' ,')
  if stridx(&l:tags, tf) < 0
    let &l:tags = tf . ',' . &tags
  endif
endfunction

function! rtl#tags#Generate() abort
  let root = rtl#project#Root()
  let files = rtl#project#Files(1)
  if empty(files)
    echohl WarningMsg | echomsg 'RTL: no source files found under ' . root | echohl None
    return
  endif
  let out = root . '/tags'
  if filewritable(root) != 2
    echohl ErrorMsg | echomsg 'RTL: project root not writable: ' . root | echohl None
    return
  endif
  let exe = rtl#tags#CtagsExe()
  if !empty(exe)
    let ok = s:RunCtags(exe, files, out)
    if ok
      call rtl#tags#SetTagsOption()
      echo 'RTL: tags written by ' . exe . ' -> ' . out . ' (' . len(files) . ' files)'
      return
    endif
    echohl WarningMsg | echomsg 'RTL: ctags failed, using built-in indexer' | echohl None
  endif
  let n = s:WriteVimTags(files, out)
  call rtl#tags#SetTagsOption()
  echo 'RTL: built-in indexer wrote ' . n . ' tags -> ' . out . ' (' . len(files) . ' files, no ctags)'
endfunction

function! s:RunCtags(exe, files, out) abort
  let listfile = tempname()
  call writefile(a:files, listfile)
  let flavour = rtl#tags#CtagsFlavour(a:exe)
  let cmd = shellescape(a:exe) . ' -f ' . shellescape(a:out) . ' --sort=yes'
  if flavour ==# 'universal'
    let cmd .= ' --languages=Verilog,SystemVerilog,VHDL --kinds-Verilog=* --kinds-SystemVerilog=* --kinds-VHDL=* --extras=+q --fields=+nK'
    " .vh / .svh are not always mapped; be explicit
    let cmd .= ' --langmap=Verilog:+.vh --langmap=SystemVerilog:+.svh'
  elseif flavour ==# 'exuberant'
    let cmd .= ' --languages=Verilog,VHDL --langmap=Verilog:+.vh.sv.svh --fields=+nK'
  endif
  let cmd .= ' -L ' . shellescape(listfile)
  let res = system(cmd)
  call delete(listfile)
  if v:shell_error
    echohl ErrorMsg | echomsg 'RTL: ' . substitute(res, '\n', ' ', 'g') | echohl None
    return 0
  endif
  return filereadable(a:out)
endfunction

" -------------------------------------------------- built-in indexer ---
function! s:TagPattern(line) abort
  " tags file ex-pattern: escape \ / ^ $ as ctags does
  let p = substitute(a:line, '\\', '\\\\', 'g')
  let p = substitute(p, '/', '\\/', 'g')
  let p = substitute(p, '\^', '\\^', 'g')
  let p = substitute(p, '\$', '\\$', 'g')
  return '/^' . p . '$/'
endfunction

function! s:WriteVimTags(files, out) abort
  let entries = []
  for f in a:files
    if !filereadable(f) | continue | endif
    let lines = readfile(f)
    if f =~? '\.vhdl\?$'
      let syms = rtl#tags#VhdlSymbols(lines)
    else
      let syms = rtl#symbols#FromLines(lines, '')
    endif
    let rel = f
    for s in syms
      let k = get(s:kind_letter, s.kind, 'v')
      " name<TAB>file<TAB>/^line$/;"<TAB>kind<TAB>line:N
      call add(entries, s.word . "\t" . rel . "\t" . s:TagPattern(s.line) . ';"' . "\t" . k . "\tline:" . s.lnum)
    endfor
  endfor
  " Vim requires byte-order sorting when !_TAG_FILE_SORTED is 1
  call sort(entries)
  let header = [
        \ "!_TAG_FILE_FORMAT\t2\t/extended format/",
        \ "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/",
        \ "!_TAG_PROGRAM_NAME\trtl-ide builtin indexer\t//",
        \ ]
  call writefile(header + entries, a:out)
  return len(entries)
endfunction

" Minimal VHDL declaration scanner (case-insensitive language).
function! rtl#tags#VhdlSymbols(lines) abort
  let syms = []
  let lnum = 0
  for raw in a:lines
    let lnum += 1
    let line = substitute(raw, '--.*$', '', '')
    let m = matchlist(line, '\c^\s*\%(entity\|package\|component\|configuration\)\s\+\(\h\w*\)')
    if !empty(m)
      let kw = tolower(matchstr(line, '^\s*\zs\h\w*'))
      call add(syms, {'word': m[1], 'kind': kw ==# 'package' ? 'package' : (kw ==# 'component' ? 'component' : 'entity'), 'lnum': lnum, 'line': raw})
      continue
    endif
    let m = matchlist(line, '\c^\s*architecture\s\+\(\h\w*\)')
    if !empty(m)
      call add(syms, {'word': m[1], 'kind': 'architecture', 'lnum': lnum, 'line': raw})
      continue
    endif
    let m = matchlist(line, '\c^\s*\%(\%(pure\|impure\)\s\+\)\?\%(function\|procedure\)\s\+\("\?\w\+"\?\)')
    if !empty(m)
      let kw = tolower(matchstr(line, '\c\<\%(function\|procedure\)\>'))
      call add(syms, {'word': m[1], 'kind': kw, 'lnum': lnum, 'line': raw})
      continue
    endif
    let m = matchlist(line, '\c^\s*\(\h\w*\)\s*:\s*process\>')
    if !empty(m)
      call add(syms, {'word': m[1], 'kind': 'process', 'lnum': lnum, 'line': raw})
      continue
    endif
    let m = matchlist(line, '\c^\s*\%(signal\|constant\|variable\|type\|subtype\|alias\|generic\|port\)\s\+\([^:]\+\):')
    if !empty(m)
      let kw = tolower(matchstr(line, '^\s*\zs\h\w*'))
      let kind = kw =~# 'type' ? 'type' : (kw ==# 'constant' ? 'constant' : 'signal')
      for n in split(m[1], '\s*,\s*')
        let n = substitute(n, '^\s\+\|\s\+$', '', 'g')
        if n =~# '^\h\w*$'
          call add(syms, {'word': n, 'kind': kind, 'lnum': lnum, 'line': raw})
        endif
      endfor
    endif
  endfor
  return syms
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
