" ------ "Basics" ------ "

syntax on
set splitbelow splitright
set hidden                " Hide buffers when they are abandoned:
set nocompatible          " Disable Vi compatibility mode
set number                " Show line numbers
set relativenumber        " Relative line numbers
set cursorline            " Highlight the current line
set showcmd               " Show partial commands in the bottom right
set encoding=utf-8        " Set encoding to UTF-8
set clipboard=unnamedplus " Use system clipboard
set background=dark       " change background light/dark
set termguicolors         " Enable true colors

" highlight cursor
" highlight Cursorline cterm=bold ctermbg=darkgray
highlight CursorLine cterm=NONE ctermbg=darkgray guibg=#2e2e2e

" ------ "Indentation & Formatting" ------ "

set autoindent            " Auto-indent new lines
set smartindent           " Enable smart indentation
set expandtab             " Use spaces instead of tabs
set tabstop=2             " Number of spaces per tab
set shiftwidth=2          " Number of spaces per indentation level
set softtabstop=2         " Number of spaces per tab in insert mode
set showmatch             " Show matching brackets.
set cindent
set cinoptions=l1
" ------ "Search Enhancements" ------ "

set incsearch             " Incremental search
set hlsearch              " Highlight search results
set ignorecase            " Ignore case in searches
set smartcase             " Override ignorecase if search contains uppercase

" ------ "File Management" ------ "

set fileformat=unix
set autoread              " Auto-reload files when changed outside Vim
set autowrite             " Automatically save before commands like :next and :make
set undofile              " Enable persistent undo

" ------ "Status Line & Appearance" ------ "

set laststatus=2              " Always show status line
set showmode                  " Show mode (insert, normal, etc.)
set ruler                     " Show cursor position
set list                      " Show hidden characters (tabs, trailing spaces)
set listchars=tab:▸\ ,trail:· " Define list characters
set wildmenu                  " Enhanced command-line completion
set wildmode=longest:full,full
set scrolloff=8               " Keep 8 lines above/below the cursor

" ====== "Key Mappings" ====== "

let mapleader=" "                   " set leader to space

nnoremap <Leader>z :%s/^\s\+//<CR>  " remove leading spaces
nnoremap <Leader>s :w<CR>           " Save file with Ctrl+S
nnoremap <Leader>q :q!<CR>          " Quit without saving with Ctrl+Q
nnoremap <Leader>n :set number! relativenumber!<CR> " toggle numbers

xnoremap <Tab> >gv                  " Indent
xnoremap <S-Tab> <gv                " Unindent

nnoremap <C-a> ggVG                 " Select all with Ctrl+A

" Copy-psate with indentation from system to server
nnoremap <Leader>p :set paste!<CR>

" ========== "Extras" ========== "

autocmd FileType * set formatoptions-=cro
autocmd BufNewFile,BufRead *.sv set filetype=systemverilog
autocmd BufNewFile,BufRead *.v,*.sv,*.vs set syntax=verilog

" ========== "Verilog Comments" ========== "

" Toggle multi line comments
autocmd FileType verilog,systemverilog,vhdl xnoremap <buffer> <leader>/ :<C-U>call ToggleCommentRange()<CR>
" Toggle single line comments
autocmd FileType verilog,systemverilog,vhdl nnoremap <buffer> <leader>/ :call ToggleComment()<CR>

function! ToggleCommentRange()
  let start = line("'<")
  let end   = line("'>")
  " Detect if ALL lines are already commented
  let already_commented = 1
  for lnum in range(start, end)
    if getline(lnum) !~ '^\s*//'
      let already_commented = 0
      break
    endif
  endfor
  for lnum in range(start, end)
    let line = getline(lnum)
    if already_commented
      " Uncomment: remove only the first //
      let newline = substitute(line, '^\s*//\s\?', '', '')
    else
      " Comment: prepend // at column 0
      let newline = '// ' . line
    endif
    call setline(lnum, newline)
  endfor
endfunction

function! ToggleComment()
  let line = getline('.')
  if line =~ '^\s*//'
    call setline('.', substitute(line, '^\s*//\s\?', '', ''))
  else
    call setline('.', '// ' . line)
  endif
endfunction
" ========== "Verilog begin + end" ========== "

" insert matching 'end' after typing 'begin' + Enter
autocmd FileType verilog,systemverilog,vhdl inoremap <silent><expr> <CR> CRHandler()

function! InsertEnd() abort
  let lnum = line('.')
  let curline = getline(lnum)
  let indent = matchstr(curline, '^\s*')
  let sw = &shiftwidth
  if &expandtab
    let mid_indent = indent . repeat(' ', sw)
  else
    let mid_indent = indent . "\t"
  endif
  call append(lnum, [mid_indent, indent . 'end'])
  call cursor(lnum + 1, len(mid_indent) + 1)
endfunction

function! CRHandler() abort
  let col = col('.')
  let curline = getline('.')
  let before = strpart(curline, 0, col - 1)
  if before =~ '\<begin\>$'
    " Use <C-o> + newline (not \<CR>) so the :call executes cleanly
    return "\<C-o>:call InsertEnd()\n"
  endif
  return "\<CR>"
endfunction

