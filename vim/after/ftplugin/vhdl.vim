" after/ftplugin/vhdl.vim -- RTL IDE additions for vhdl buffers.
" Runs after Vim's stock ftplugin/vhdl.vim; all settings are buffer-local.
if exists('b:did_rtl_ftplugin') | finish | endif
let b:did_rtl_ftplugin = 1
try
  call rtl#ft#Setup('vhdl')
catch
  let b:rtl_ftplugin_error = v:exception . ' @ ' . v:throwpoint
  echohl ErrorMsg | echomsg 'RTL ftplugin: ' . b:rtl_ftplugin_error | echohl None
endtry
