" autoload/rtl/edit.vim -- editing automation
"
" Enter after "begin":
"   The handler inserts a matching "end" only when ALL of these hold:
"     - the popup menu is not open (Enter then accepts the completion),
"     - the text before the cursor ends with  begin  or  begin : label,
"     - the cursor is not inside a comment or string (syntax check),
"     - nothing but whitespace follows the cursor on the line,
"     - the block is not already closed: counting begin/end from the current
"       line to the end of the buffer (bounded to 2000 lines) shows more
"       begins than ends.
"   Otherwise it is a plain <CR>.  The inserted text is typed as part of the
"   same insert session, so a single undo removes it with the Enter.
"
" Comments:  rtl#edit#ToggleComment is a range function (works on one line,
"   a count, or a visual selection) that keeps indentation and uses the
"   buffer's comment leader (// for Verilog/SV, -- for VHDL).

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_auto_end = get(g:, 'rtl_auto_end', 1)

function! s:InCommentOrString() abort
  if !has('syntax') || empty(&syntax) | return 0 | endif
  let col = max([col('.') - 1, 1])
  for id in synstack(line('.'), col)
    let name = synIDattr(synIDtrans(id), 'name')
    if name =~? 'comment\|string'
      return 1
    endif
  endfor
  return 0
endfunction

" Does the begin on the current line still lack its end?
function! s:NeedsEnd() abort
  let depth = 0
  let last = min([line('$'), line('.') + 2000])
  for l in getline(line('.'), last)
    let l = substitute(l, '//.*$', '', '')
    let l = substitute(l, '"[^"]*"', '', 'g')
    let depth += len(split(l, '\C\<begin\>', 1)) - 1
    let depth -= len(split(l, '\C\<end\>', 1)) - 1
    " a module/task/function boundary ends the search
    if depth <= 0
      return 0
    endif
    if l =~# '\C^\s*end\%(module\|task\|function\|generate\)\>'
      break
    endif
  endfor
  return depth > 0
endfunction

function! rtl#edit#CR() abort
  if pumvisible()
    return "\<C-y>"
  endif
  if !g:rtl_auto_end || &paste
    return "\<CR>"
  endif
  let line = getline('.')
  let before = strpart(line, 0, col('.') - 1)
  let after = strpart(line, col('.') - 1)
  if before !~# '\C\<begin\>\%(\s*:\s*\h\w*\)\?\s*$' || after !~# '^\s*$'
    return "\<CR>"
  endif
  if s:InCommentOrString() || !s:NeedsEnd()
    return "\<CR>"
  endif
  " <CR> new line, type "end" (the stock Verilog 'indentkeys' contain =end,
  " so it is re-indented as it is typed), then <C-o>O opens the line above
  " while staying in insert mode: one insert session, one undo block.
  return "\<CR>end\<C-o>O"
endfunction

" -------------------------------------------------------- comments ---
function! rtl#edit#ToggleComment() range abort
  let leader = get(b:, 'rtl_comment_leader', matchstr(&commentstring, '^\S*\ze\s*%s'))
  if empty(leader) | let leader = '//' | endif
  let esc = escape(leader, '/\*.^$~[]')
  " all non-blank lines in the range commented?  then uncomment
  let all = 1
  let minind = -1
  for lnum in range(a:firstline, a:lastline)
    let l = getline(lnum)
    if l =~# '^\s*$' | continue | endif
    if l !~# '^\s*' . esc
      let all = 0
    endif
    let ind = len(matchstr(l, '^\s*'))
    if minind < 0 || ind < minind | let minind = ind | endif
  endfor
  if minind < 0 | return | endif
  for lnum in range(a:firstline, a:lastline)
    let l = getline(lnum)
    if l =~# '^\s*$' | continue | endif
    if all
      let new = substitute(l, '^\(\s*\)' . esc . ' \?', '\1', '')
    else
      let new = strpart(l, 0, minind) . leader . ' ' . strpart(l, minind)
    endif
    call setline(lnum, new)
  endfor
endfunction

" ----------------------------------------------------- indent toggle ---
" Switch between full automatic indentation and "dumb" editing
" (no indentexpr/autoindent) for pasting or fighting the indenter.
function! rtl#edit#ToggleAutoIndent() abort
  if exists('b:rtl_indent_saved')
    let &l:indentexpr = b:rtl_indent_saved.indentexpr
    let &l:autoindent = b:rtl_indent_saved.autoindent
    let &l:indentkeys = b:rtl_indent_saved.indentkeys
    unlet b:rtl_indent_saved
    echo 'RTL: automatic indentation ON'
  else
    let b:rtl_indent_saved = {'indentexpr': &l:indentexpr,
          \ 'autoindent': &l:autoindent, 'indentkeys': &l:indentkeys}
    setlocal indentexpr= noautoindent indentkeys=
    echo 'RTL: automatic indentation OFF'
  endif
endfunction

" ------------------------------------------------------------ OSC52 ---
" Copy the last visual selection to the LOCAL clipboard through the
" terminal (works in xterm, kitty, alacritty, wezterm, tmux with
" set-clipboard; PuTTY ignores it).  Needs base64 or a pure-Vim encoder.
function! rtl#edit#Osc52Yank(vmode) abort
  let save = @"
  silent normal! gvy
  let text = @"
  let @" = save
  let b64 = s:Base64(text)
  if empty(b64)
    echohl WarningMsg | echomsg 'RTL: no base64 encoder available for OSC52' | echohl None
    return
  endif
  let seq = "\e]52;c;" . b64 . "\x07"
  if exists('$TMUX')
    let seq = "\ePtmux;\e" . seq . "\e\\"
  endif
  if filewritable('/dev/tty') == 1
    call writefile([seq], '/dev/tty', 'b')
  else
    silent! call echoraw(seq)
  endif
  echo 'RTL: ' . len(text) . ' bytes sent to terminal clipboard (OSC52)'
endfunction

function! s:Base64(text) abort
  if executable('base64')
    return substitute(system('base64', a:text), '\n', '', 'g')
  endif
  " pure Vimscript fallback
  let tbl = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  let out = ''
  let bytes = []
  for i in range(len(a:text))
    call add(bytes, char2nr(a:text[i]))
  endfor
  let i = 0
  while i < len(bytes)
    let b0 = bytes[i]
    let b1 = i + 1 < len(bytes) ? bytes[i + 1] : 0
    let b2 = i + 2 < len(bytes) ? bytes[i + 2] : 0
    let n = b0 * 65536 + b1 * 256 + b2
    let out .= tbl[n / 262144 % 64] . tbl[n / 4096 % 64]
    let out .= (i + 1 < len(bytes)) ? tbl[n / 64 % 64] : '='
    let out .= (i + 2 < len(bytes)) ? tbl[n % 64] : '='
    let i += 3
  endwhile
  return out
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
