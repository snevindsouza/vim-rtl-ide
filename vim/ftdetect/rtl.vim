" Extra RTL file extensions.  Vim already detects *.v (verilog),
" *.sv *.svh (systemverilog) and *.vhd *.vhdl *.vho (vhdl); these add the
" ones commonly seen in RTL trees.  setfiletype never overrides a filetype
" already set by Vim's own filetype.vim.
autocmd BufNewFile,BufRead *.vh,*.vs,*.vlg,*.verilog setfiletype verilog
autocmd BufNewFile,BufRead *.svi,*.svp,*.sva        setfiletype systemverilog
autocmd BufNewFile,BufRead *.vhdp                   setfiletype vhdl
autocmd BufNewFile,BufRead *.vc,*.flist             setfiletype rtlfilelist
" *.f is Fortran to Vim's filetype.vim; override only when the content
" looks like a simulator file list (source paths, +incdir+, -f).
autocmd BufNewFile,BufRead *.f call s:RtlFilelistCheck()
function! s:RtlFilelistCheck() abort
  for l in getline(1, 30)
    if l =~? '^\s*\(+incdir+\|+define+\|-f\s\|-y\s\)' || l =~? '\.\(v\|sv\|vh\|svh\|vhdl\?\)\s*$'
      set filetype=rtlfilelist
      return
    endif
  endfor
endfunction
