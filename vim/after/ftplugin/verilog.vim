" after/ftplugin/verilog.vim -- RTL IDE additions for verilog buffers.
" Runs after Vim's stock ftplugin/verilog.vim; all settings are buffer-local.
if exists('b:did_rtl_ftplugin') | finish | endif
let b:did_rtl_ftplugin = 1
try
  call rtl#ft#Setup('verilog')
catch
  let b:rtl_ftplugin_error = v:exception . ' @ ' . v:throwpoint
  echohl ErrorMsg | echomsg 'RTL ftplugin: ' . b:rtl_ftplugin_error | echohl None
endtry
