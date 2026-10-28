" autoload/rtl/lsp.vim -- a small, real LSP client in stock Vimscript
"
" Requirements: Vim 8.0+ built with +job +channel (json_encode/json_decode
" come with +eval in 8.0).  Timers (+timers) are optional (change
" debouncing); popups (+popupwin, 8.2) are optional (hover window).
" Without +job/+channel every entry point reports "LSP unavailable" and
" the rest of the IDE keeps working.
"
" Transport: job_start() with raw stdio.  Outgoing messages are framed as
"   Content-Length: <bytes>\r\n\r\n<json>
" Incoming bytes are buffered and split on the Content-Length header, so
" partial and coalesced chunks are handled.  Request ids are integers;
" every request is recorded in `pending` until its response arrives.
"
" Implemented:
"   initialize / initialized / shutdown / exit, server-to-client requests
"     (client/registerCapability, workspace/configuration,
"      window/workDoneProgress/create, workspace/workspaceFolders)
"   textDocument/didOpen, didChange (full text, debounced), didSave, didClose
"   textDocument/publishDiagnostics  -> location list + signs + statusline
"   textDocument/hover               -> popup (or echo)        :RtlHover / K
"   textDocument/definition          -> jump / quickfix        :RtlDefinition
"   textDocument/references          -> quickfix               :RtlReferences
"   textDocument/documentSymbol      -> location list          :RtlSymbols
"   textDocument/rename              -> WorkspaceEdit applied  :RtlRename
"   textDocument/formatting          -> TextEdits applied      :RtlFormat
"   textDocument/completion          -> merged into omnifunc (only when the
"                                       server advertises completionProvider)
" Every request first checks the server's advertised capability; a
" missing capability gives a clear message instead of a protocol error.
"
" Servers (optional, auto-detected if in $PATH, override with
" g:rtl_lsp_command / g:rtl_lsp_command_vhdl or lsp_command in .rtlproject):
"   verilog/systemverilog:  verible-verilog-ls   (Verible)
"                           veridian, svls       (if you have them)
"   vhdl:                   vhdl_ls (rust_hdl), ghdl-ls
" Which capabilities you get depends on the server, see :RtlLspStatus.

let s:save_cpo = &cpo | set cpo&vim

let g:rtl_lsp_autostart   = get(g:, 'rtl_lsp_autostart', 1)
let g:rtl_lsp_timeout_ms  = get(g:, 'rtl_lsp_timeout_ms', 3000)
let g:rtl_lsp_debounce_ms = get(g:, 'rtl_lsp_debounce_ms', 300)
let g:rtl_lsp_log_lines   = get(g:, 'rtl_lsp_log_lines', 300)
let g:rtl_lsp_diagnostics = get(g:, 'rtl_lsp_diagnostics', 1)

let s:servers = {}      " group -> state dict
let s:warned = {}

" ----------------------------------------------------------- basics ---
function! rtl#lsp#Supported() abort
  return has('job') && has('channel') && exists('*json_encode') && exists('*json_decode')
endfunction

function! s:Group(...) abort
  let ft = a:0 ? a:1 : &filetype
  if ft =~# '^\%(verilog\|systemverilog\)$' | return 'verilog' | endif
  if ft ==# 'vhdl' | return 'vhdl' | endif
  return ''
endfunction

function! rtl#lsp#Command(group) abort
  let cfg = rtl#project#ConfigGet(a:group ==# 'vhdl' ? 'lsp_command_vhdl' : 'lsp_command', '')
  let user = get(g:, a:group ==# 'vhdl' ? 'rtl_lsp_command_vhdl' : 'rtl_lsp_command', '')
  for cand in [cfg, user]
    if type(cand) == type([]) && !empty(cand)
      return executable(cand[0]) ? cand : []
    elseif type(cand) == type('') && !empty(cand)
      let parts = split(cand, '\s\+')
      return executable(parts[0]) ? parts : []
    endif
  endfor
  let defaults = a:group ==# 'vhdl' ? ['vhdl_ls', 'ghdl-ls'] : ['verible-verilog-ls', 'veridian', 'svls']
  for exe in defaults
    if executable(exe) | return [exe] | endif
  endfor
  return []
endfunction

function! s:Srv(...) abort
  let g = s:Group(a:0 ? a:1 : &filetype)
  return get(s:servers, g, {})
endfunction

function! s:Ready(srv) abort
  return !empty(a:srv) && get(a:srv, 'state', '') ==# 'ready'
endfunction

function! rtl#lsp#Has(cap) abort
  let srv = s:Srv()
  if !s:Ready(srv) | return 0 | endif
  let v = get(srv.caps, a:cap, 0)
  if type(v) == type({}) | return 1 | endif
  if type(v) == type(v:true) | return v == v:true | endif
  return !empty(v)
endfunction

function! s:Log(srv, msg) abort
  call add(a:srv.log, strftime('%H:%M:%S') . ' ' . a:msg)
  if len(a:srv.log) > g:rtl_lsp_log_lines
    call remove(a:srv.log, 0, len(a:srv.log) - g:rtl_lsp_log_lines - 1)
  endif
endfunction

function! s:Warn(msg) abort
  echohl WarningMsg | echomsg 'RTL LSP: ' . a:msg | echohl None
endfunction

" ------------------------------------------------------------- URIs ---
function! s:UriEncode(path) abort
  return substitute(a:path, '[^A-Za-z0-9_.~/-]',
        \ '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
endfunction

function! rtl#lsp#Uri(path) abort
  let p = fnamemodify(a:path, ':p')
  return 'file://' . s:UriEncode(p)
endfunction

function! rtl#lsp#UriToPath(uri) abort
  let p = substitute(a:uri, '^file://', '', '')
  let p = substitute(p, '%\(\x\x\)', '\=nr2char(str2nr(submatch(1), 16))', 'g')
  return p
endfunction

" LSP position <-> Vim.  LSP counts UTF-16 units; for the ASCII/BMP text
" found in RTL that equals the character count, which is what we use.
function! s:Pos(lnum, col) abort
  let line = getline(a:lnum)
  return {'line': a:lnum - 1, 'character': strchars(strpart(line, 0, a:col - 1))}
endfunction

function! s:ColFromChar(line, character) abort
  let b = byteidx(a:line, a:character)
  return (b < 0 ? len(a:line) : b) + 1
endfunction

" ---------------------------------------------------------- transport ---
function! s:Send(srv, obj) abort
  if get(a:srv, 'state', '') ==# 'stopped' | return | endif
  let body = json_encode(a:obj)
  call s:Log(a:srv, '-> ' . strpart(body, 0, 160))
  try
    call ch_sendraw(a:srv.ch, 'Content-Length: ' . strlen(body) . "\r\n\r\n" . body)
  catch
    call s:Log(a:srv, 'send failed: ' . v:exception)
  endtry
endfunction

function! s:Request(srv, method, params, cb) abort
  let id = a:srv.nextid
  let a:srv.nextid += 1
  let a:srv.pending[id] = {'method': a:method, 'cb': a:cb}
  call s:Send(a:srv, {'jsonrpc': '2.0', 'id': id, 'method': a:method, 'params': a:params})
  return id
endfunction

function! s:Notify(srv, method, params) abort
  call s:Send(a:srv, {'jsonrpc': '2.0', 'method': a:method, 'params': a:params})
endfunction

function! s:Respond(srv, id, result) abort
  call s:Send(a:srv, {'jsonrpc': '2.0', 'id': a:id, 'result': a:result})
endfunction

function! s:RespondError(srv, id, code, msg) abort
  call s:Send(a:srv, {'jsonrpc': '2.0', 'id': a:id, 'error': {'code': a:code, 'message': a:msg}})
endfunction

" Synchronous request: waits (while still processing channel messages)
" up to timeout ms.  Returns {'result': ...} or {'error': ...} or
" {'timeout': 1}.
function! s:RequestSync(srv, method, params, timeout) abort
  let id = s:Request(a:srv, a:method, a:params, '')
  let waited = 0
  while waited < a:timeout
    if has_key(a:srv.results, id)
      return remove(a:srv.results, id)
    endif
    if a:srv.state ==# 'stopped'
      return {'error': {'message': 'server stopped'}}
    endif
    sleep 20m
    let waited += 20
  endwhile
  if has_key(a:srv.pending, id) | unlet a:srv.pending[id] | endif
  call s:Log(a:srv, 'timeout waiting for ' . a:method . ' #' . id)
  return {'timeout': 1}
endfunction

function! s:OnOut(group, ch, msg) abort
  let srv = get(s:servers, a:group, {})
  if empty(srv) | return | endif
  let srv.buf .= a:msg
  while 1
    let hend = stridx(srv.buf, "\r\n\r\n")
    if hend < 0 | break | endif
    let header = strpart(srv.buf, 0, hend)
    let clen = str2nr(matchstr(header, '\cContent-Length:\s*\zs\d\+'))
    let bstart = hend + 4
    if clen <= 0
      let srv.buf = strpart(srv.buf, bstart)
      continue
    endif
    if strlen(srv.buf) < bstart + clen
      break
    endif
    let body = strpart(srv.buf, bstart, clen)
    let srv.buf = strpart(srv.buf, bstart + clen)
    try
      let obj = json_decode(body)
    catch
      call s:Log(srv, 'bad json: ' . strpart(body, 0, 120))
      continue
    endtry
    call s:Log(srv, '<- ' . strpart(body, 0, 160))
    try
      call s:Dispatch(srv, obj)
    catch
      call s:Log(srv, 'dispatch error: ' . v:exception . ' @ ' . v:throwpoint)
    endtry
  endwhile
endfunction

function! s:OnErr(group, ch, msg) abort
  let srv = get(s:servers, a:group, {})
  if !empty(srv) | call s:Log(srv, 'stderr: ' . a:msg) | endif
endfunction

function! s:OnExit(group, job, status) abort
  let srv = get(s:servers, a:group, {})
  if empty(srv) | return | endif
  let was = srv.state
  let srv.state = 'stopped'
  call s:Log(srv, 'server exited with status ' . a:status)
  for id in keys(srv.pending)
    let srv.results[id] = {'error': {'message': 'server exited'}}
  endfor
  let srv.pending = {}
  if was !=# 'stopping'
    call s:Warn(srv.cmd[0] . ' exited (status ' . a:status . '); :RtlLspLog for details, :RtlLspStart to restart')
  endif
endfunction

" ------------------------------------------------------------ dispatch ---
function! s:Dispatch(srv, msg) abort
  if type(a:msg) != type({}) | return | endif
  if has_key(a:msg, 'method')
    if has_key(a:msg, 'id')
      call s:ServerRequest(a:srv, a:msg)
    else
      call s:Notification(a:srv, a:msg)
    endif
  elseif has_key(a:msg, 'id')
    let id = a:msg.id
    let key = type(id) == type('') ? id : string(id)
    let req = get(a:srv.pending, key, {})
    if has_key(a:srv.pending, key) | unlet a:srv.pending[key] | endif
    let res = has_key(a:msg, 'error') ? {'error': a:msg.error} : {'result': get(a:msg, 'result', v:null)}
    if !empty(req) && !empty(req.cb)
      call call(req.cb, [res])
    else
      let a:srv.results[key] = res
    endif
  endif
endfunction

function! s:ServerRequest(srv, msg) abort
  let m = a:msg.method
  let p = get(a:msg, 'params', {})
  if m ==# 'client/registerCapability' || m ==# 'client/unregisterCapability'
    call s:Respond(a:srv, a:msg.id, v:null)
  elseif m ==# 'workspace/configuration'
    let items = type(p) == type({}) ? get(p, 'items', []) : []
    call s:Respond(a:srv, a:msg.id, map(copy(items), 'v:null'))
  elseif m ==# 'window/workDoneProgress/create'
    call s:Respond(a:srv, a:msg.id, v:null)
  elseif m ==# 'workspace/workspaceFolders'
    call s:Respond(a:srv, a:msg.id, [{'uri': rtl#lsp#Uri(a:srv.root), 'name': fnamemodify(a:srv.root, ':t')}])
  elseif m ==# 'window/showMessageRequest'
    echohl WarningMsg | echomsg 'RTL LSP: ' . get(p, 'message', '') | echohl None
    call s:Respond(a:srv, a:msg.id, v:null)
  elseif m ==# 'workspace/applyEdit'
    let ok = s:ApplyWorkspaceEdit(get(p, 'edit', {}))
    call s:Respond(a:srv, a:msg.id, {'applied': ok ? v:true : v:false})
  else
    call s:RespondError(a:srv, a:msg.id, -32601, 'method not supported by client: ' . m)
  endif
endfunction

function! s:Notification(srv, msg) abort
  let m = a:msg.method
  let p = get(a:msg, 'params', {})
  if m ==# 'textDocument/publishDiagnostics'
    call s:OnDiagnostics(a:srv, p)
  elseif m ==# 'window/showMessage'
    let t = get(p, 'type', 3)
    if t <= 2
      echohl WarningMsg | echomsg 'RTL LSP: ' . get(p, 'message', '') | echohl None
    else
      call s:Log(a:srv, 'message: ' . get(p, 'message', ''))
    endif
  elseif m ==# 'window/logMessage'
    call s:Log(a:srv, 'log: ' . get(p, 'message', ''))
  endif
  " $/progress, telemetry etc. are ignored
endfunction

" ------------------------------------------------------------ lifecycle ---
function! rtl#lsp#Start(verbose) abort
  let group = s:Group()
  if empty(group)
    if a:verbose | call s:Warn('only for verilog/systemverilog/vhdl buffers') | endif
    return 0
  endif
  if !rtl#lsp#Supported()
    if a:verbose | call s:Warn('this Vim lacks +job/+channel; LSP features are unavailable') | endif
    return 0
  endif
  let srv = get(s:servers, group, {})
  if !empty(srv) && srv.state =~# '^\%(starting\|ready\)$'
    if a:verbose | echo 'RTL LSP: ' . srv.cmd[0] . ' already ' . srv.state | endif
    return 1
  endif
  let cmd = rtl#lsp#Command(group)
  if empty(cmd)
    if a:verbose || !has_key(s:warned, group)
      let s:warned[group] = 1
      call s:Warn('no language server found for ' . group
            \ . ' (verible-verilog-ls / vhdl_ls not in $PATH; set g:rtl_lsp_command). Tags, lint and completion still work.')
    endif
    return 0
  endif
  let root = rtl#project#Root()
  let srv = {
        \ 'group': group, 'cmd': cmd, 'root': root, 'state': 'starting',
        \ 'buf': '', 'nextid': 1, 'pending': {}, 'results': {}, 'caps': {},
        \ 'docs': {}, 'dirty': {}, 'diags': {}, 'log': [], 'timer': -1,
        \ }
  let s:servers[group] = srv
  let opts = {
        \ 'in_mode': 'raw', 'out_mode': 'raw', 'err_mode': 'nl',
        \ 'out_cb': function('s:OnOut', [group]),
        \ 'err_cb': function('s:OnErr', [group]),
        \ 'exit_cb': function('s:OnExit', [group]),
        \ }
  if has('patch-8.0.0902') | let opts.cwd = root | endif
  let srv.job = job_start(cmd, opts)
  if job_status(srv.job) !=# 'run'
    let srv.state = 'stopped'
    call s:Warn('could not start ' . join(cmd, ' '))
    return 0
  endif
  let srv.ch = job_getchannel(srv.job)
  let params = {
        \ 'processId': getpid(),
        \ 'rootUri': rtl#lsp#Uri(root),
        \ 'rootPath': root,
        \ 'workspaceFolders': [{'uri': rtl#lsp#Uri(root), 'name': fnamemodify(root, ':t')}],
        \ 'clientInfo': {'name': 'vim-rtl-ide', 'version': '1.0'},
        \ 'capabilities': {
        \   'workspace': {'applyEdit': v:true, 'workspaceFolders': v:true,
        \                 'configuration': v:false, 'workspaceEdit': {'documentChanges': v:true}},
        \   'textDocument': {
        \     'synchronization': {'didSave': v:true, 'dynamicRegistration': v:false},
        \     'publishDiagnostics': {'relatedInformation': v:false},
        \     'hover': {'contentFormat': ['plaintext', 'markdown']},
        \     'completion': {'completionItem': {'snippetSupport': v:false}},
        \     'definition': {}, 'references': {}, 'documentSymbol': {
        \        'hierarchicalDocumentSymbolSupport': v:true},
        \     'rename': {'prepareSupport': v:false}, 'formatting': {},
        \   },
        \ },
        \ 'initializationOptions': {},
        \ }
  call s:Request(srv, 'initialize', params, function('s:OnInitialized', [group]))
  if a:verbose | echo 'RTL LSP: starting ' . join(cmd, ' ') . ' in ' . root | endif
  return 1
endfunction

function! s:OnInitialized(group, res) abort
  let srv = get(s:servers, a:group, {})
  if empty(srv) | return | endif
  if has_key(a:res, 'error')
    let srv.state = 'stopped'
    call s:Warn('initialize failed: ' . string(get(a:res.error, 'message', a:res.error)))
    call rtl#lsp#Stop()
    return
  endif
  let result = get(a:res, 'result', {})
  let srv.caps = type(result) == type({}) ? get(result, 'capabilities', {}) : {}
  let srv.state = 'ready'
  call s:Notify(srv, 'initialized', {})
  " open every loaded buffer of this group
  for b in range(1, bufnr('$'))
    if bufloaded(b) && s:Group(getbufvar(b, '&filetype')) ==# a:group
      call s:DidOpen(srv, b)
    endif
  endfor
  redrawstatus
  echo 'RTL LSP: ' . srv.cmd[0] . ' ready (' . join(rtl#lsp#CapList(srv), ', ') . ')'
endfunction

function! rtl#lsp#CapList(srv) abort
  let names = {'hoverProvider': 'hover', 'definitionProvider': 'definition',
        \ 'referencesProvider': 'references', 'documentSymbolProvider': 'symbols',
        \ 'renameProvider': 'rename', 'documentFormattingProvider': 'format',
        \ 'completionProvider': 'completion'}
  let out = []
  for [k, v] in items(names)
    let c = get(a:srv.caps, k, 0)
    if (type(c) == type({})) || (type(c) == type(v:true) && c == v:true) || (type(c) == type(0) && c)
      call add(out, v)
    endif
  endfor
  call add(out, 'diagnostics(push)')
  return sort(out)
endfunction

function! rtl#lsp#Stop() abort
  for group in keys(s:servers)
    let srv = s:servers[group]
    if srv.state ==# 'stopped' | continue | endif
    let srv.state = 'stopping'
    if srv.timer >= 0 && exists('*timer_stop') | silent! call timer_stop(srv.timer) | endif
    try
      let id = srv.nextid
      let srv.nextid += 1
      let srv.pending[id] = {'method': 'shutdown', 'cb': ''}
      call s:Send(srv, {'jsonrpc': '2.0', 'id': id, 'method': 'shutdown', 'params': v:null})
      let waited = 0
      while waited < 1000 && !has_key(srv.results, string(id)) && job_status(srv.job) ==# 'run'
        sleep 20m
        let waited += 20
      endwhile
      call s:Notify(srv, 'exit', v:null)
      let waited = 0
      while waited < 500 && job_status(srv.job) ==# 'run'
        sleep 20m
        let waited += 20
      endwhile
      if job_status(srv.job) ==# 'run'
        call job_stop(srv.job, 'term')
      endif
    catch
      silent! call job_stop(srv.job, 'kill')
    endtry
    let srv.state = 'stopped'
  endfor
  call s:ClearAllDiagnostics()
  redrawstatus
endfunction

function! rtl#lsp#Status() abort
  if !rtl#lsp#Supported()
    echo 'RTL LSP: unavailable (Vim built without +job/+channel)'
    return
  endif
  if empty(s:servers)
    echo 'RTL LSP: not started. verilog: ' . (empty(rtl#lsp#Command('verilog')) ? 'no server in $PATH' : join(rtl#lsp#Command('verilog'), ' '))
          \ . ' | vhdl: ' . (empty(rtl#lsp#Command('vhdl')) ? 'no server in $PATH' : join(rtl#lsp#Command('vhdl'), ' '))
    return
  endif
  for [g, srv] in items(s:servers)
    echo printf('RTL LSP [%s]: %s  state=%s  root=%s', g, join(srv.cmd, ' '), srv.state, srv.root)
    if srv.state ==# 'ready'
      echo '   capabilities: ' . join(rtl#lsp#CapList(srv), ', ')
      echo '   open documents: ' . len(srv.docs) . '  pending requests: ' . len(srv.pending)
    endif
  endfor
endfunction

function! rtl#lsp#ShowLog() abort
  let lines = []
  for [g, srv] in items(s:servers)
    let lines += ['== ' . g . ' (' . join(srv.cmd, ' ') . ') state=' . srv.state] + srv.log + ['']
  endfor
  if empty(lines) | echo 'RTL LSP: no log (server not started)' | return | endif
  silent botright new
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  call setline(1, lines)
  setlocal nomodifiable
  file RTL-LSP-log
  nnoremap <silent> <buffer> q :close<CR>
endfunction

" For the statusline
function! rtl#lsp#StatusShort() abort
  let srv = s:Srv()
  if empty(srv) | return '' | endif
  return srv.state ==# 'ready' ? 'LSP' : (srv.state ==# 'starting' ? 'LSP..' : 'LSP!')
endfunction

" ---------------------------------------------------- document sync ---
function! s:LangId(bufnr) abort
  let ft = getbufvar(a:bufnr, '&filetype')
  return ft ==# 'vhdl' ? 'vhdl' : (ft ==# 'systemverilog' ? 'systemverilog' : 'verilog')
endfunction

function! s:Text(bufnr) abort
  return join(getbufline(a:bufnr, 1, '$'), "\n") . "\n"
endfunction

function! s:DidOpen(srv, bufnr) abort
  if has_key(a:srv.docs, a:bufnr) | return | endif
  let path = fnamemodify(bufname(a:bufnr), ':p')
  if empty(bufname(a:bufnr)) | return | endif
  let a:srv.docs[a:bufnr] = 1
  call s:Notify(a:srv, 'textDocument/didOpen', {'textDocument': {
        \ 'uri': rtl#lsp#Uri(path), 'languageId': s:LangId(a:bufnr),
        \ 'version': 1, 'text': s:Text(a:bufnr)}})
endfunction

function! s:DidChange(srv, bufnr) abort
  if !has_key(a:srv.docs, a:bufnr) | return | endif
  let a:srv.docs[a:bufnr] += 1
  let path = fnamemodify(bufname(a:bufnr), ':p')
  call s:Notify(a:srv, 'textDocument/didChange', {
        \ 'textDocument': {'uri': rtl#lsp#Uri(path), 'version': a:srv.docs[a:bufnr]},
        \ 'contentChanges': [{'text': s:Text(a:bufnr)}]})
  if has_key(a:srv.dirty, a:bufnr) | unlet a:srv.dirty[a:bufnr] | endif
endfunction

" send pending changes of this buffer now (before any request)
function! s:Flush(srv, bufnr) abort
  if has_key(a:srv.dirty, a:bufnr)
    call s:DidChange(a:srv, a:bufnr)
  endif
endfunction

function! s:FlushTimer(group, timer) abort
  let srv = get(s:servers, a:group, {})
  if empty(srv) || srv.state !=# 'ready' | return | endif
  let srv.timer = -1
  for b in keys(srv.dirty)
    if bufloaded(str2nr(b)) | call s:DidChange(srv, str2nr(b)) | endif
  endfor
  let srv.dirty = {}
endfunction

" autocommand entry points (registered in ftplugin via rtl#lsp#Attach)
function! rtl#lsp#OnEnter() abort
  let group = s:Group()
  if empty(group) | return | endif
  let srv = get(s:servers, group, {})
  if empty(srv) && g:rtl_lsp_autostart && !empty(rtl#lsp#Command(group))
    call rtl#lsp#Start(0)
    return
  endif
  if s:Ready(srv)
    call s:DidOpen(srv, bufnr('%'))
    call s:ApplyDiagnostics(srv, bufnr('%'))
  endif
endfunction

function! rtl#lsp#OnChange() abort
  let srv = s:Srv()
  if !s:Ready(srv) || !has_key(srv.docs, bufnr('%')) | return | endif
  let srv.dirty[bufnr('%')] = 1
  if has('timers')
    if srv.timer >= 0 | silent! call timer_stop(srv.timer) | endif
    let srv.timer = timer_start(g:rtl_lsp_debounce_ms, function('s:FlushTimer', [srv.group]))
  else
    " no timers: send immediately for normal-mode changes; insert-mode
    " changes are sent on InsertLeave (see ftplugin)
    if mode() !~# '^[iR]'
      call s:DidChange(srv, bufnr('%'))
    endif
  endif
endfunction

function! rtl#lsp#OnInsertLeave() abort
  let srv = s:Srv()
  if s:Ready(srv) | call s:Flush(srv, bufnr('%')) | endif
endfunction

function! rtl#lsp#OnSave() abort
  let srv = s:Srv()
  if !s:Ready(srv) || !has_key(srv.docs, bufnr('%')) | return | endif
  call s:Flush(srv, bufnr('%'))
  call s:Notify(srv, 'textDocument/didSave', {'textDocument': {'uri': rtl#lsp#Uri(expand('%:p'))}})
endfunction

function! rtl#lsp#OnClose(bufnr) abort
  for srv in values(s:servers)
    if s:Ready(srv) && has_key(srv.docs, a:bufnr)
      let name = bufname(a:bufnr)
      if !empty(name)
        call s:Notify(srv, 'textDocument/didClose', {'textDocument': {'uri': rtl#lsp#Uri(fnamemodify(name, ':p'))}})
      endif
      unlet srv.docs[a:bufnr]
      if has_key(srv.dirty, a:bufnr) | unlet srv.dirty[a:bufnr] | endif
    endif
  endfor
endfunction

function! rtl#lsp#OnExitVim() abort
  if !empty(s:servers) | call rtl#lsp#Stop() | endif
endfunction

" ------------------------------------------------------- diagnostics ---
function! s:OnDiagnostics(srv, params) abort
  let uri = get(a:params, 'uri', '')
  let a:srv.diags[uri] = get(a:params, 'diagnostics', [])
  let path = rtl#lsp#UriToPath(uri)
  let bnr = bufnr(path)
  if bnr > 0 && bufloaded(bnr)
    call s:ApplyDiagnostics(a:srv, bnr)
  endif
endfunction

function! s:ApplyDiagnostics(srv, bufnr) abort
  if !g:rtl_lsp_diagnostics | return | endif
  let name = bufname(a:bufnr)
  if empty(name) | return | endif
  let uri = rtl#lsp#Uri(fnamemodify(name, ':p'))
  if !has_key(a:srv.diags, uri) | return | endif
  let items = []
  let nerr = 0
  let nwarn = 0
  for d in a:srv.diags[uri]
    let sev = get(d, 'severity', 1)
    let type = sev == 1 ? 'E' : (sev == 2 ? 'W' : 'I')
    if type ==# 'E' | let nerr += 1 | elseif type ==# 'W' | let nwarn += 1 | endif
    let r = get(d, 'range', {'start': {'line': 0, 'character': 0}})
    let lnum = r.start.line + 1
    let line = get(getbufline(a:bufnr, lnum), 0, '')
    call add(items, {'bufnr': a:bufnr, 'lnum': lnum,
          \ 'col': s:ColFromChar(line, r.start.character),
          \ 'type': type, 'text': substitute(get(d, 'message', ''), '\n', ' ', 'g')
          \ . (has_key(d, 'code') ? ' [' . d.code . ']' : '')})
  endfor
  call sort(items, {a, b -> a.lnum - b.lnum})
  for w in range(1, winnr('$'))
    if winbufnr(w) == a:bufnr
      call setloclist(w, items, 'r')
      if has('patch-7.4.2200')
        call setloclist(w, [], 'a', {'title': 'RTL LSP diagnostics'})
      endif
    endif
  endfor
  call rtl#lint#PlaceDiagSigns(a:bufnr, items)
  call setbufvar(a:bufnr, 'rtl_diag', empty(items) ? 'ok' : ('E' . nerr . ' W' . nwarn))
  redrawstatus
endfunction

function! s:ClearAllDiagnostics() abort
  for b in range(1, bufnr('$'))
    if bufexists(b) && !empty(s:Group(getbufvar(b, '&filetype')))
      call rtl#lint#ClearSigns(b)
      call setbufvar(b, 'rtl_diag', '')
    endif
  endfor
endfunction

" ------------------------------------------------------------ helpers ---
function! s:DocPos() abort
  return {'textDocument': {'uri': rtl#lsp#Uri(expand('%:p'))},
        \ 'position': s:Pos(line('.'), col('.'))}
endfunction

function! s:Check(cap, what) abort
  let srv = s:Srv()
  if !rtl#lsp#Supported()
    call s:Warn('unavailable: this Vim lacks +job/+channel')
    return {}
  endif
  if empty(srv) || srv.state ==# 'stopped'
    call s:Warn('no server running (:RtlLspStart)')
    return {}
  endif
  if srv.state !=# 'ready'
    call s:Warn('server still starting')
    return {}
  endif
  if !rtl#lsp#Has(a:cap)
    call s:Warn(srv.cmd[0] . ' does not provide ' . a:what)
    return {}
  endif
  call s:Flush(srv, bufnr('%'))
  return srv
endfunction

function! s:Locations(res) abort
  " normalise Location | Location[] | LocationLink[] -> [{file, lnum, col}]
  let r = get(a:res, 'result', v:null)
  if type(r) != type([]) && type(r) != type({}) | return [] | endif
  let list = type(r) == type([]) ? r : [r]
  let out = []
  for loc in list
    if type(loc) != type({}) | continue | endif
    if has_key(loc, 'targetUri')
      let uri = loc.targetUri
      let range = get(loc, 'targetSelectionRange', get(loc, 'targetRange', {}))
    else
      let uri = get(loc, 'uri', '')
      let range = get(loc, 'range', {})
    endif
    if empty(uri) || empty(range) | continue | endif
    let file = rtl#lsp#UriToPath(uri)
    let lnum = range.start.line + 1
    let line = s:FileLine(file, lnum)
    call add(out, {'filename': file, 'lnum': lnum,
          \ 'col': s:ColFromChar(line, range.start.character),
          \ 'text': substitute(line, '^\s*', '', '')})
  endfor
  return out
endfunction

function! s:FileLine(file, lnum) abort
  let bnr = bufnr(a:file)
  if bnr > 0 && bufloaded(bnr)
    return get(getbufline(bnr, a:lnum), 0, '')
  endif
  if filereadable(a:file)
    return get(readfile(a:file, '', a:lnum), a:lnum - 1, '')
  endif
  return ''
endfunction

function! s:Jump(loc) abort
  normal! m'
  if fnamemodify(a:loc.filename, ':p') !=# expand('%:p')
    execute 'edit ' . fnameescape(a:loc.filename)
  endif
  call cursor(a:loc.lnum, a:loc.col)
  normal! zv
endfunction

function! s:ToQuickfix(items, title) abort
  call setqflist(a:items, 'r')
  if has('patch-7.4.2200')
    call setqflist([], 'a', {'title': a:title})
  endif
  copen
endfunction

" ------------------------------------------------------------- hover ---
function! rtl#lsp#Hover() abort
  let srv = s:Check('hoverProvider', 'hover')
  if empty(srv) | return | endif
  let res = s:RequestSync(srv, 'textDocument/hover', s:DocPos(), g:rtl_lsp_timeout_ms)
  if get(res, 'timeout', 0) | call s:Warn('hover timed out') | return | endif
  if has_key(res, 'error') | call s:Warn('hover: ' . string(get(res.error, 'message', ''))) | return | endif
  let lines = s:HoverLines(get(res, 'result', v:null))
  if empty(lines)
    echo 'RTL LSP: no hover information'
    return
  endif
  if has('popupwin') && exists('*popup_atcursor')
    call popup_atcursor(lines, {'padding': [0, 1, 0, 1], 'border': [],
          \ 'moved': 'any', 'maxwidth': max([40, &columns - 10]), 'maxheight': 20})
  else
    echo join(lines[:15], "\n")
  endif
endfunction

function! s:HoverLines(result) abort
  if type(a:result) != type({}) | return [] | endif
  let c = get(a:result, 'contents', '')
  let parts = []
  if type(c) == type('')
    call add(parts, c)
  elseif type(c) == type({})
    call add(parts, get(c, 'value', ''))
  elseif type(c) == type([])
    for e in c
      call add(parts, type(e) == type({}) ? get(e, 'value', '') : e)
    endfor
  endif
  let text = join(parts, "\n")
  " light markdown cleanup: fences and emphasis
  let text = substitute(text, '```\w*', '', 'g')
  let text = substitute(text, '\*\*\([^*]\+\)\*\*', '\1', 'g')
  return split(text, "\n")
endfunction

" -------------------------------------------------------- definition ---
" returns 1 if it jumped (or listed), 0 if nothing found
function! rtl#lsp#Definition() abort
  let srv = s:Check('definitionProvider', 'go-to-definition')
  if empty(srv) | return 0 | endif
  let res = s:RequestSync(srv, 'textDocument/definition', s:DocPos(), g:rtl_lsp_timeout_ms)
  if get(res, 'timeout', 0) | call s:Warn('definition timed out') | return 0 | endif
  let locs = s:Locations(res)
  if empty(locs) | return 0 | endif
  if len(locs) == 1
    call s:Jump(locs[0])
  else
    call s:ToQuickfix(locs, 'RTL LSP definitions')
  endif
  return 1
endfunction

" -------------------------------------------------------- references ---
function! rtl#lsp#References() abort
  let srv = s:Check('referencesProvider', 'find-references')
  if empty(srv) | return 0 | endif
  let params = s:DocPos()
  let params.context = {'includeDeclaration': v:true}
  let res = s:RequestSync(srv, 'textDocument/references', params, g:rtl_lsp_timeout_ms)
  if get(res, 'timeout', 0) | call s:Warn('references timed out') | return 0 | endif
  let locs = s:Locations(res)
  if empty(locs)
    echo 'RTL LSP: no references reported'
    return 1
  endif
  call s:ToQuickfix(locs, 'RTL LSP references: ' . expand('<cword>'))
  return 1
endfunction

" ----------------------------------------------------------- symbols ---
let s:symkind = {1: 'file', 2: 'module', 3: 'namespace', 4: 'package', 5: 'class',
      \ 6: 'method', 7: 'property', 8: 'field', 9: 'constructor', 10: 'enum',
      \ 11: 'interface', 12: 'function', 13: 'variable', 14: 'constant',
      \ 15: 'string', 16: 'number', 17: 'boolean', 18: 'array', 19: 'object',
      \ 20: 'key', 21: 'null', 22: 'enumMember', 23: 'struct', 24: 'event',
      \ 25: 'operator', 26: 'typeParameter'}

function! rtl#lsp#DocumentSymbols() abort
  let srv = s:Check('documentSymbolProvider', 'document symbols')
  if empty(srv) | return | endif
  let res = s:RequestSync(srv, 'textDocument/documentSymbol',
        \ {'textDocument': {'uri': rtl#lsp#Uri(expand('%:p'))}}, g:rtl_lsp_timeout_ms)
  if get(res, 'timeout', 0) | call s:Warn('documentSymbol timed out') | return | endif
  let r = get(res, 'result', [])
  if type(r) != type([]) || empty(r)
    echo 'RTL LSP: no symbols reported'
    return
  endif
  let items = []
  call s:FlattenSymbols(r, 0, items, bufnr('%'))
  call setloclist(0, items, 'r')
  if has('patch-7.4.2200')
    call setloclist(0, [], 'a', {'title': 'RTL LSP symbols: ' . expand('%:t')})
  endif
  lopen
endfunction

function! s:FlattenSymbols(list, depth, items, bufnr) abort
  for sym in a:list
    if type(sym) != type({}) | continue | endif
    let kind = get(s:symkind, get(sym, 'kind', 0), '?')
    if has_key(sym, 'location')
      let range = get(sym.location, 'range', {})
      let file = rtl#lsp#UriToPath(get(sym.location, 'uri', ''))
    else
      let range = get(sym, 'selectionRange', get(sym, 'range', {}))
      let file = ''
    endif
    if empty(range) | continue | endif
    let item = {'lnum': range.start.line + 1, 'col': range.start.character + 1,
          \ 'text': repeat('  ', a:depth) . kind . ' ' . get(sym, 'name', '')
          \ . (empty(get(sym, 'detail', '')) ? '' : '  ' . sym.detail)}
    if empty(file) | let item.bufnr = a:bufnr | else | let item.filename = file | endif
    call add(a:items, item)
    if has_key(sym, 'children') && type(sym.children) == type([])
      call s:FlattenSymbols(sym.children, a:depth + 1, a:items, a:bufnr)
    endif
  endfor
endfunction

" ------------------------------------------------------------ rename ---
function! rtl#lsp#Rename(newname) abort
  let srv = s:Check('renameProvider', 'rename')
  if empty(srv) | return | endif
  let old = expand('<cword>')
  let new = a:newname
  if empty(new)
    let new = input('Rename ' . old . ' to: ', old)
    if empty(new) || new ==# old | return | endif
  endif
  let params = s:DocPos()
  let params.newName = new
  let res = s:RequestSync(srv, 'textDocument/rename', params, g:rtl_lsp_timeout_ms)
  if get(res, 'timeout', 0) | call s:Warn('rename timed out') | return | endif
  if has_key(res, 'error')
    call s:Warn('rename refused: ' . string(get(res.error, 'message', '')))
    return
  endif
  let n = s:ApplyWorkspaceEdit(get(res, 'result', {}))
  echo 'RTL LSP: rename applied to ' . n . ' file(s); buffers are modified, not saved (:wa to save)'
endfunction

" -------------------------------------------------------- formatting ---
function! rtl#lsp#Format() abort
  let srv = s:Check('documentFormattingProvider', 'formatting')
  if empty(srv) | return | endif
  let params = {'textDocument': {'uri': rtl#lsp#Uri(expand('%:p'))},
        \ 'options': {'tabSize': &shiftwidth > 0 ? &shiftwidth : &tabstop,
        \             'insertSpaces': &expandtab ? v:true : v:false}}
  let res = s:RequestSync(srv, 'textDocument/formatting', params, g:rtl_lsp_timeout_ms * 2)
  if get(res, 'timeout', 0) | call s:Warn('formatting timed out') | return | endif
  if has_key(res, 'error')
    call s:Warn('formatting failed: ' . string(get(res.error, 'message', '')))
    return
  endif
  let edits = get(res, 'result', [])
  if type(edits) != type([]) || empty(edits)
    echo 'RTL LSP: nothing to format'
    return
  endif
  let view = winsaveview()
  call s:ApplyEditsToCurrent(edits)
  call winrestview(view)
  echo 'RTL LSP: formatted (' . len(edits) . ' edit(s)); review with :undo if needed'
endfunction

" ------------------------------------------------------- text edits ---
" Apply TextEdits to the current buffer.  Edits are applied bottom-up so
" earlier positions stay valid.
function! s:ApplyEditsToCurrent(edits) abort
  let edits = filter(copy(a:edits), 'type(v:val) == type({}) && has_key(v:val, "range")')
  call sort(edits, function('s:EditCompareDesc'))
  for e in edits
    let sl = e.range.start.line + 1
    let el = e.range.end.line + 1
    if sl > line('$') | let sl = line('$') | endif
    if el > line('$') | let el = line('$') | endif
    let first = getline(sl)
    let last = getline(el)
    let sb = byteidx(first, e.range.start.character)
    let eb = byteidx(last, e.range.end.character)
    if sb < 0 | let sb = len(first) | endif
    if eb < 0 | let eb = len(last) | endif
    let text = strpart(first, 0, sb) . get(e, 'newText', '') . strpart(last, eb)
    let newlines = split(text, "\n", 1)
    " a trailing newline in newText produces a final '' element: keep it
    " only if the original replaced region ended at a line end that way
    if len(newlines) > 1 && newlines[-1] ==# '' && e.range.end.character == 0
          \ && e.range.end.line > e.range.start.line
      call remove(newlines, -1)
    endif
    silent execute sl . ',' . el . 'delete _'
    call append(sl - 1, newlines)
  endfor
endfunction

function! s:EditCompareDesc(a, b) abort
  if a:a.range.start.line != a:b.range.start.line
    return a:b.range.start.line - a:a.range.start.line
  endif
  return a:b.range.start.character - a:a.range.start.character
endfunction

" WorkspaceEdit -> per-file edits; returns number of files changed
function! s:ApplyWorkspaceEdit(edit) abort
  if type(a:edit) != type({}) | return 0 | endif
  let per_file = []
  if has_key(a:edit, 'documentChanges') && type(a:edit.documentChanges) == type([])
    for dc in a:edit.documentChanges
      if type(dc) == type({}) && has_key(dc, 'textDocument')
        call add(per_file, [rtl#lsp#UriToPath(dc.textDocument.uri), get(dc, 'edits', [])])
      endif
    endfor
  elseif has_key(a:edit, 'changes') && type(a:edit.changes) == type({})
    for [uri, edits] in items(a:edit.changes)
      call add(per_file, [rtl#lsp#UriToPath(uri), edits])
    endfor
  endif
  let cur = bufnr('%')
  let n = 0
  for [file, edits] in per_file
    if empty(edits) | continue | endif
    let bnr = bufnr(file)
    if bnr != bufnr('%')
      execute 'silent keepalt keepjumps edit ' . fnameescape(file)
    endif
    call s:ApplyEditsToCurrent(edits)
    let n += 1
  endfor
  if bufnr('%') != cur
    execute 'silent keepalt keepjumps buffer ' . cur
  endif
  return n
endfunction

" ------------------------------------------------------- completion ---
let s:cikind = {1: 't', 2: 'f', 3: 'f', 4: 'f', 5: 'm', 6: 'v', 7: 'C', 8: 'i',
      \ 9: 'K', 10: 'p', 11: 'u', 12: 'v', 13: 'e', 14: 'k', 15: 's', 16: 'c',
      \ 17: 'F', 18: 'r', 19: 'd', 20: 'E', 21: 'c', 22: 'S', 23: 'e', 24: 'o',
      \ 25: 'T'}

" Called from the omnifunc.  Returns [] quickly when there is no server or
" the server does not advertise completion (Verible does not).
function! rtl#lsp#Completion(base) abort
  let srv = s:Srv()
  if !s:Ready(srv) || !rtl#lsp#Has('completionProvider') | return [] | endif
  call s:Flush(srv, bufnr('%'))
  let params = s:DocPos()
  let params.context = {'triggerKind': 1}
  let res = s:RequestSync(srv, 'textDocument/completion', params, min([g:rtl_lsp_timeout_ms, 1500]))
  if get(res, 'timeout', 0) || has_key(res, 'error') | return [] | endif
  let r = get(res, 'result', [])
  let list = type(r) == type({}) ? get(r, 'items', []) : (type(r) == type([]) ? r : [])
  let out = []
  for it in list
    if type(it) != type({}) | continue | endif
    let word = get(it, 'insertText', '')
    if has_key(it, 'textEdit') && type(it.textEdit) == type({})
      let word = get(it.textEdit, 'newText', word)
    endif
    if empty(word) || get(it, 'insertTextFormat', 1) == 2
      let word = get(it, 'label', '')
    endif
    if empty(word) | continue | endif
    call add(out, {'word': word, 'abbr': get(it, 'label', word),
          \ 'kind': get(s:cikind, get(it, 'kind', 0), ''),
          \ 'menu': '[LSP] ' . get(it, 'detail', ''), 'dup': 0})
  endfor
  return out
endfunction

let &cpo = s:save_cpo | unlet s:save_cpo
