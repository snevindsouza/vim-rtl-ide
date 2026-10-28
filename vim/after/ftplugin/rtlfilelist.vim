" after/ftplugin/rtlfilelist.vim -- simulator file lists (.f / .flist / .vc)
if exists('b:did_rtl_filelist') | finish | endif
let b:did_rtl_filelist = 1
setlocal commentstring=//\ %s
setlocal comments=://
" gf opens the listed file relative to the list itself or the project root
let &l:path = escape(expand('%:p:h'), ' ,') . ',' . escape(rtl#project#Root(), ' ,')
setlocal includeexpr=substitute(v:fname,'^+incdir+','','')
let b:undo_ftplugin = get(b:, 'undo_ftplugin', '') . '|setlocal commentstring< comments< path< includeexpr<'
