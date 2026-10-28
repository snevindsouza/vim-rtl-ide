" ============================================================================
" ~/.vimrc  --  Plugin-free Vim IDE for Verilog / SystemVerilog / VHDL
"
" Layout:
"   ~/.vimrc                  this file: core options + global mappings
"   ~/.vim/autoload/rtl/*.vim lazily-loaded feature modules (rtl#<mod>#Func)
"   ~/.vim/ftplugin/*.vim     buffer-local settings/mappings per filetype
"   ~/.vim/ftdetect/rtl.vim   extra extensions (*.vh *.vs *.svh ...)
"   ~/.vim/dict/*.dict        keyword dictionaries for i_CTRL-X_CTRL-K
"   ~/.vim/templates/         text templates used by :RtlModule etc.
"   ~/.vim/doc/rtl-ide.txt    :help rtl-ide
"
" Minimum: Vim 7.4 for the core.  Vim 8.0+ (+job +channel +eval) for the
" LSP client and asynchronous lint.  No plugins, no plugin manager.
" ============================================================================

" ---------------------------------------------------------------- Guards ---
" 'nocompatible' must come first; it resets other options when changed.
if &compatible
  set nocompatible
endif
if !has('eval')
  " Tiny/small Vim: nothing below works.  Keep a usable editor and stop.
  syntax on
  set number ruler
  finish
endif
scriptencoding utf-8

" Make the Vimscript modules in ~/.vim/autoload/rtl/ available.
" (This is the default 'runtimepath'; set explicitly so a custom $VIM or a
"  stripped-down environment still finds them.)
let s:vimdir = expand('<sfile>:p:h') . '/.vim'
if isdirectory(s:vimdir) && index(split(&runtimepath, ','), s:vimdir) < 0
  execute 'set runtimepath^=' . fnameescape(s:vimdir)
  execute 'set runtimepath+=' . fnameescape(s:vimdir . '/after')
endif

" ------------------------------------------------- Filetype & syntax ---
" Enables Vim's stock syntax/indent/ftplugin for verilog, systemverilog, vhdl.
filetype plugin indent on
if !exists('g:syntax_on')
  syntax enable
endif

" ----------------------------------------------------------- Basics ---
set encoding=utf-8
set hidden                  " keep abandoned buffers loaded
set splitbelow splitright
set number relativenumber
set cursorline
set showcmd
set showmode
set ruler
set laststatus=2
set scrolloff=8
set list
set listchars=tab:▸\ ,trail:·
set wildmenu
set wildmode=longest:full,full
set wildignore+=*.o,*.obj,*.so,*.a,*.vcd,*.fst,*.lxt*,*.vvp,*.pyc,*.log
set wildignore+=*/.git/*,*/obj_dir/*,*/build/*,*/work/*,*/sim_build/*
set backspace=indent,eol,start
set history=1000
set shortmess+=c            " no "match 1 of 2" noise during completion
set nrformats-=octal
set ttimeout ttimeoutlen=50 " fast <Esc> over SSH, keeps mapping timeouts
set lazyredraw
set display=lastline
set formatoptions-=cro      " never auto-continue comments (also set per ft)
set mouse=                  " terminal over PuTTY: keep mouse to the terminal
set background=dark

" True colour only when the terminal really advertises it.  PuTTY usually
" does not; falling back to 256-colour is the safe default.
if has('termguicolors') && ($COLORTERM ==# 'truecolor' || $COLORTERM ==# '24bit')
  set termguicolors
endif
highlight CursorLine cterm=NONE ctermbg=236 guibg=#2e2e2e
highlight CursorLineNr cterm=bold ctermfg=yellow guifg=#e0c060
highlight Pmenu ctermbg=237 ctermfg=white guibg=#3a3a3a guifg=#e0e0e0
highlight PmenuSel ctermbg=yellow ctermfg=black guibg=#e0c060 guifg=#000000

" ----------------------------------------------- Indentation / format ---
" Two spaces, soft tabs.  Per-language indentation comes from Vim's stock
" indent scripts ('indentexpr'), so 'cindent'/'smartindent' are NOT set
" globally any more: they fought with indent/verilog.vim.
set autoindent
set expandtab
set tabstop=2
set shiftwidth=2
set softtabstop=2
set shiftround
set showmatch
set matchtime=2
set nojoinspaces

" --------------------------------------------------------- Searching ---
set incsearch
set hlsearch
set ignorecase
set smartcase
set wrapscan

" ------------------------------------------------------ File handling ---
set fileformats=unix,dos    " read either; new files are written as unix
set autoread
set autowrite               " save before :make / :next etc.
set nobackup nowritebackup
set noswapfile
" Persistent undo with a safe fallback: only if the directory can be made.
if has('persistent_undo')
  let s:undodir = expand('~/.vim/undo')
  if !isdirectory(s:undodir)
    silent! call mkdir(s:undodir, 'p', 0700)
  endif
  if isdirectory(s:undodir) && filewritable(s:undodir) == 2
    let &undodir = s:undodir
    set undofile
  endif
endif

" --------------------------------------------------------- Clipboard ---
" Only meaningful if this Vim has +clipboard AND an X server is reachable
" (ssh -X / xauth).  Over plain SSH/PuTTY the register is silently ignored,
" which is harmless.  OSC52 yank (<Leader>y) works where the terminal
" supports it (not PuTTY by default).
if has('clipboard')
  if has('unnamedplus')
    set clipboard^=unnamedplus
  else
    set clipboard^=unnamed
  endif
endif

" --------------------------------------------------------- Status line ---
set statusline=%<%f\ %y%m%r%h%w
if !empty(globpath(&runtimepath, 'autoload/rtl/status.vim'))
  set statusline+=%{rtl#status#Line()}
endif
set statusline+=%=%-14.(%l,%c%V%)\ %P

" ------------------------------------------------------- Leader & maps ---
let mapleader = ' '
let maplocalleader = ' '

" --- existing behaviour, kept ---
nnoremap <silent> <Leader>s :w<CR>
nnoremap <silent> <Leader>n :set number! relativenumber!<CR>
nnoremap <silent> <Leader>p :set paste!<CR>
nnoremap <silent> <Leader>z :%s/^\s\+//e<CR>
xnoremap <Tab>   >gv
xnoremap <S-Tab> <gv
nnoremap <C-a>   ggVG
" :q! on a single key was dangerous; <Leader>q now asks when unsaved,
" <Leader>Q is the old discard-and-quit.
nnoremap <silent> <Leader>q :q!<CR>
nnoremap <silent> <Leader>Q :q!<CR>

" --- options / toggles  (<Leader>o...) ---
nnoremap <silent> <Leader>oi :call rtl#edit#ToggleAutoIndent()<CR>
nnoremap <silent> <Leader>ol :set list!<CR>
nnoremap <silent> <Leader>oh :nohlsearch<CR>
nnoremap <silent> <Leader>ow :set wrap!<CR>
nnoremap <silent> <Leader>os :setlocal spell!<CR>

" --- files / buffers / windows ---
nnoremap <silent> <Leader>fe :call rtl#project#Explore()<CR>
nnoremap <Leader>ff :RtlFind<Space>
nnoremap <Leader>fg :RtlGrep<Space>
nnoremap <silent> <Leader>fw :call rtl#nav#GrepWord()<CR>
nnoremap <Leader>fb :ls<CR>:b<Space>
nnoremap <silent> ]b :bnext<CR>
nnoremap <silent> [b :bprevious<CR>
nnoremap <silent> <Leader>bd :bdelete<CR>
nnoremap <silent> <Leader>ba :call rtl#nav#AltBuffer()<CR>
nnoremap <silent> <Leader>wv :vsplit<CR>
nnoremap <silent> <Leader>ws :split<CR>
nnoremap <silent> <Leader>wo :only<CR>
nnoremap <silent> <Leader>wc :close<CR>
nnoremap <silent> <Leader>w= <C-w>=
nnoremap <silent> <Leader>wh <C-w>h
nnoremap <silent> <Leader>wj <C-w>j
nnoremap <silent> <Leader>wk <C-w>k
nnoremap <silent> <Leader>wl <C-w>l

" --- search & replace: word under cursor, confirm each ---
nnoremap <Leader>r :%s/\<<C-r><C-w>\>//gc<Left><Left><Left>
xnoremap <Leader>r :s///gc<Left><Left><Left><Left>

" --- quickfix / location list ---
nnoremap <silent> <Leader>co :copen<CR>
nnoremap <silent> <Leader>cc :cclose<CR>
nnoremap <silent> <Leader>lo :lopen<CR>
nnoremap <silent> <Leader>lc :lclose<CR>
nnoremap <silent> ]q :cnext<CR>
nnoremap <silent> [q :cprevious<CR>
nnoremap <silent> ]l :lnext<CR>
nnoremap <silent> [l :lprevious<CR>

" --- project / tags / diagnostics (global; RTL-specific ones are in ftplugin) ---
nnoremap <silent> <Leader>tg :RtlTags<CR>
nnoremap <silent> <Leader>hd :RtlDoctor<CR>
nnoremap <silent> <Leader>hh :help rtl-ide<CR>
nnoremap <silent> <Leader>hk :help rtl-ide-keys<CR>

" --- OSC52 yank to local clipboard through the terminal ---
xnoremap <silent> <Leader>y :<C-u>call rtl#edit#Osc52Yank(visualmode())<CR>

" ------------------------------------------------------------ Commands ---
" Everything lives under the :Rtl* namespace so  :Rtl<Tab>  lists it all.
command! -nargs=? -complete=customlist,rtl#lint#CompleteTool RtlLint        call rtl#lint#Run(<q-args>, 0)
command! -nargs=? -complete=customlist,rtl#lint#CompleteTool RtlLintProject call rtl#lint#Run(<q-args>, 1)
command! -nargs=0 RtlTags        call rtl#tags#Generate()
command! -nargs=0 RtlRoot        echo rtl#project#Root()
command! -nargs=0 RtlRefresh     call rtl#project#Refresh()
command! -nargs=0 RtlDoctor      call rtl#doctor#Run()
command! -nargs=0 RtlFiles       call rtl#project#ListFiles()
command! -nargs=1 -complete=customlist,rtl#project#CompleteFile RtlFind call rtl#project#Find(<q-args>)
command! -nargs=+ RtlGrep        call rtl#nav#Grep(<q-args>)
command! -nargs=? -complete=customlist,rtl#symbols#CompleteModule RtlInstantiate call rtl#templates#Instantiate(<q-args>)
command! -nargs=? RtlModule      call rtl#templates#Module(<q-args>)
command! -nargs=? -complete=customlist,rtl#templates#CompleteName RtlTemplate call rtl#templates#Insert(<q-args>)
command! -nargs=? RtlInstances   call rtl#nav#Instances(<q-args>)
command! -nargs=0 RtlDefinition  call rtl#nav#Definition()
command! -nargs=0 RtlReferences  call rtl#nav#References()
command! -nargs=0 RtlHover       call rtl#lsp#Hover()
command! -nargs=0 RtlSymbols     call rtl#lsp#DocumentSymbols()
command! -nargs=? RtlRename      call rtl#lsp#Rename(<q-args>)
command! -nargs=0 RtlFormat      call rtl#lsp#Format()
command! -nargs=0 RtlLspStart    call rtl#lsp#Start(1)
command! -nargs=0 RtlLspStop     call rtl#lsp#Stop()
command! -nargs=0 RtlLspStatus   call rtl#lsp#Status()
command! -nargs=0 RtlLspLog      call rtl#lsp#ShowLog()
command! -nargs=0 RtlDiagnostics call rtl#lint#ShowDiagnostics()
command! -nargs=0 RtlClearDiagnostics call rtl#lint#Clear()
command! -nargs=0 RtlKeys        help rtl-ide-keys

" --------------------------------------------------------- Autocommands ---
augroup RtlIde
  autocmd!
  " never auto-insert comment leaders on o/O/<CR> (ftplugins re-add fo flags)
  autocmd FileType * setlocal formatoptions-=c formatoptions-=r formatoptions-=o
  " jump to last known position when reopening a file
  autocmd BufReadPost *
        \ if line("'\"") > 1 && line("'\"") <= line("$") && &filetype !~# 'commit' |
        \   execute 'normal! g`"' |
        \ endif
  " quickfix window: q closes, no line numbers
  autocmd FileType qf setlocal nonumber norelativenumber nocursorline |
        \ nnoremap <silent> <buffer> q :close<CR>
  " netrw buffers: q closes
  autocmd FileType netrw nnoremap <silent> <buffer> q :bdelete<CR>
  " leave paste mode automatically when leaving insert mode
  autocmd InsertLeave * if &paste | set nopaste | endif
  " shut language servers down cleanly (only if the LSP module was loaded)
  autocmd VimLeavePre * if exists('*rtl#lsp#OnExitVim') | call rtl#lsp#OnExitVim() | endif
augroup END

" ------------------------------------------------------- Built-in extras ---
" netrw (built-in explorer) tuned as a project tree
let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_winsize = 25
let g:netrw_altv = 1
" matchit: % jumps between module/endmodule, begin/end, case/endcase ...
if !exists('g:loaded_matchit')
  silent! packadd matchit
  if !exists('g:loaded_matchit') && !empty(globpath(&runtimepath, 'macros/matchit.vim'))
    runtime macros/matchit.vim
  endif
endif

" --------------------------------------------------- User-overridable ---
" Put overrides in ~/.vimrc.local (not shipped, never overwritten).
if filereadable(expand('~/.vimrc.local'))
  source ~/.vimrc.local
endif
