" autoload/rtl/status.vim -- statusline segment (cheap: no I/O, no scans)
"
"  [root-name]  LSP  E2 W1  PASTE
let s:save_cpo = &cpo | set cpo&vim

function! rtl#status#Line() abort
  let parts = []
  if &filetype =~# '^\%(verilog\|systemverilog\|vhdl\)$'
    if exists('b:rtl_root')
      call add(parts, '[' . fnamemodify(b:rtl_root, ':t') . ']')
    endif
    if exists('*rtl#lsp#StatusShort')
      let l = rtl#lsp#StatusShort()
      if !empty(l) | call add(parts, l) | endif
    endif
    let d = get(b:, 'rtl_diag', '')
    if !empty(d) | call add(parts, d) | endif
  endif
  if &paste | call add(parts, 'PASTE') | endif
  return empty(parts) ? '' : ' ' . join(parts, ' ')
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
