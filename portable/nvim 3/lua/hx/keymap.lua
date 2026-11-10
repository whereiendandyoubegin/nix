local K = require('hx.keys')
local U = require('hx.util')

local M = {}

local function node(name, sticky)
  return { is_node = true, name = name or '', keys = {}, map = {}, sticky = sticky or false }
end

local function insert(n, key, value)
  key = K.normalize(key)
  if n.map[key] == nil then n.keys[#n.keys + 1] = key end
  n.map[key] = value
end

local function build(spec)
  local n = node(spec[1], spec.sticky)
  for i = 2, #spec do
    local entry = spec[i]
    local keys, value = entry[1], entry[2]
    if type(value) == 'table' and value[1] and type(value[1]) == 'string' and not value.seq then
      value = build(value)
    elseif type(value) == 'table' and value.seq then
      value = { seq = value.seq }
    end
    for k in (keys .. '|'):gmatch('(.-)|') do
      if k == '' then k = '|' end
      insert(n, k, value)
    end
  end
  return n
end

local function fix_bar(spec)
  for i = 2, #spec do
    local e = spec[i]
    if e[1] == '<bar>' then e[1] = '|' end
    if type(e[2]) == 'table' and type(e[2][1]) == 'string' and not e[2].seq then fix_bar(e[2]) end
  end
  return spec
end

local function B(keys, value)
  return { keys, value }
end

local window_node = {
  'Window',
  B('C-w|w', 'rotate_view'),
  B('C-s|s', 'hsplit'),
  B('C-v|v', 'vsplit'),
  B('C-t|t', 'transpose_view'),
  B('f', 'goto_file_hsplit'),
  B('F', 'goto_file_vsplit'),
  B('C-q|q', 'wclose'),
  B('C-o|o', 'wonly'),
  B('C-h|h|left', 'jump_view_left'),
  B('C-j|j|down', 'jump_view_down'),
  B('C-k|k|up', 'jump_view_up'),
  B('C-l|l|right', 'jump_view_right'),
  B('L', 'swap_view_right'),
  B('K', 'swap_view_up'),
  B('H', 'swap_view_left'),
  B('J', 'swap_view_down'),
  B('n', { 'New split scratch buffer', B('C-s|s', 'hsplit_new'), B('C-v|v', 'vsplit_new') }),
}

local space_window_node = {
  'Window',
  B('C-w|w', 'rotate_view'),
  B('C-s|s', 'hsplit'),
  B('C-v|v', 'vsplit'),
  B('C-t|t', 'transpose_view'),
  B('f', 'goto_file_hsplit'),
  B('F', 'goto_file_vsplit'),
  B('C-q|q', 'wclose'),
  B('C-o|o', 'wonly'),
  B('C-h|h|left', 'jump_view_left'),
  B('C-j|j|down', 'jump_view_down'),
  B('C-k|k|up', 'jump_view_up'),
  B('C-l|l|right', 'jump_view_right'),
  B('H', 'swap_view_left'),
  B('J', 'swap_view_down'),
  B('K', 'swap_view_up'),
  B('L', 'swap_view_right'),
  B('n', { 'New split scratch buffer', B('C-s|s', 'hsplit_new'), B('C-v|v', 'vsplit_new') }),
}

local function view_node(sticky)
  return {
    'View',
    sticky = sticky,
    B('z|c', 'align_view_center'),
    B('t', 'align_view_top'),
    B('b', 'align_view_bottom'),
    B('m', 'align_view_middle'),
    B('k|up', 'scroll_up'),
    B('j|down', 'scroll_down'),
    B('C-b|pageup', 'page_up'),
    B('C-f|pagedown', 'page_down'),
    B('C-u|backspace', 'page_cursor_half_up'),
    B('C-d|space', 'page_cursor_half_down'),
    B('/', 'search'),
    B('?', 'rsearch'),
    B('n', 'search_next'),
    B('N', 'search_prev'),
  }
end

local function normal_spec()
  return {
    'Normal mode',
    B('h|left', 'move_char_left'),
    B('j|down', 'move_visual_line_down'),
    B('k|up', 'move_visual_line_up'),
    B('l|right', 'move_char_right'),
    B('t', 'find_till_char'),
    B('f', 'find_next_char'),
    B('T', 'till_prev_char'),
    B('F', 'find_prev_char'),
    B('r', 'replace'),
    B('R', 'replace_with_yanked'),
    B('A-.', 'repeat_last_motion'),
    B('~', 'switch_case'),
    B('`', 'switch_to_lowercase'),
    B('A-`', 'switch_to_uppercase'),
    B('home', 'goto_line_start'),
    B('end', 'goto_line_end'),
    B('w', 'move_next_word_start'),
    B('b', 'move_prev_word_start'),
    B('e', 'move_next_word_end'),
    B('W', 'move_next_long_word_start'),
    B('B', 'move_prev_long_word_start'),
    B('E', 'move_next_long_word_end'),
    B('v', 'select_mode'),
    B('G', 'goto_line'),
    B('g', {
      'Goto',
      B('g', 'goto_file_start'),
      B('<bar>', 'goto_column'),
      B('e', 'goto_last_line'),
      B('f', 'goto_file'),
      B('h', 'goto_line_start'),
      B('l', 'goto_line_end'),
      B('s', 'goto_first_nonwhitespace'),
      B('d', 'goto_definition'),
      B('D', 'goto_declaration'),
      B('y', 'goto_type_definition'),
      B('r', 'goto_reference'),
      B('i', 'goto_implementation'),
      B('t', 'goto_window_top'),
      B('c', 'goto_window_center'),
      B('b', 'goto_window_bottom'),
      B('a', 'goto_last_accessed_file'),
      B('m', 'goto_last_modified_file'),
      B('n', 'goto_next_buffer'),
      B('p', 'goto_previous_buffer'),
      B('k', 'move_line_up'),
      B('j', 'move_line_down'),
      B('.', 'goto_last_modification'),
      B('w', 'goto_word'),
    }),
    B(':', 'command_mode'),
    B('i', 'insert_mode'),
    B('I', 'insert_at_line_start'),
    B('a', 'append_mode'),
    B('A', 'insert_at_line_end'),
    B('o', 'open_below'),
    B('O', 'open_above'),
    B('d', 'delete_selection'),
    B('A-d', 'delete_selection_noyank'),
    B('c', 'change_selection'),
    B('A-c', 'change_selection_noyank'),
    B('C', 'copy_selection_on_next_line'),
    B('A-C', 'copy_selection_on_prev_line'),
    B('s', 'select_regex'),
    B('A-s', 'split_selection_on_newline'),
    B('A-minus', 'merge_selections'),
    B('A-_', 'merge_consecutive_selections'),
    B('S', 'split_selection'),
    B(';', 'collapse_selection'),
    B('A-;', 'flip_selections'),
    B('A-o|A-up', 'expand_selection'),
    B('A-i|A-down', 'shrink_selection'),
    B('A-I|A-S-down', 'select_all_children'),
    B('A-p|A-left', 'select_prev_sibling'),
    B('A-n|A-right', 'select_next_sibling'),
    B('A-e', 'move_parent_node_end'),
    B('A-b', 'move_parent_node_start'),
    B('A-a', 'select_all_siblings'),
    B('%', 'select_all'),
    B('x', 'extend_line_below'),
    B('X', 'extend_to_line_bounds'),
    B('A-x', 'shrink_to_line_bounds'),
    B('m', {
      'Match',
      B('m', 'match_brackets'),
      B('s', 'surround_add'),
      B('r', 'surround_replace'),
      B('d', 'surround_delete'),
      B('a', 'select_textobject_around'),
      B('i', 'select_textobject_inner'),
    }),
    B('[', {
      'Left bracket',
      B('d', 'goto_prev_diag'),
      B('D', 'goto_first_diag'),
      B('g', 'goto_prev_change'),
      B('G', 'goto_first_change'),
      B('f', 'goto_prev_function'),
      B('t', 'goto_prev_class'),
      B('a', 'goto_prev_parameter'),
      B('c', 'goto_prev_comment'),
      B('e', 'goto_prev_entry'),
      B('T', 'goto_prev_test'),
      B('p', 'goto_prev_paragraph'),
      B('x', 'goto_prev_xml_element'),
      B('space', 'add_newline_above'),
    }),
    B(']', {
      'Right bracket',
      B('d', 'goto_next_diag'),
      B('D', 'goto_last_diag'),
      B('g', 'goto_next_change'),
      B('G', 'goto_last_change'),
      B('f', 'goto_next_function'),
      B('t', 'goto_next_class'),
      B('a', 'goto_next_parameter'),
      B('c', 'goto_next_comment'),
      B('e', 'goto_next_entry'),
      B('T', 'goto_next_test'),
      B('p', 'goto_next_paragraph'),
      B('x', 'goto_next_xml_element'),
      B('space', 'add_newline_below'),
    }),
    B('/', 'search'),
    B('?', 'rsearch'),
    B('n', 'search_next'),
    B('N', 'search_prev'),
    B('*', 'search_selection_detect_word_boundaries'),
    B('A-*', 'search_selection'),
    B('u', 'undo'),
    B('U', 'redo'),
    B('A-u', 'earlier'),
    B('A-U', 'later'),
    B('y', 'yank'),
    B('p', 'paste_after'),
    B('P', 'paste_before'),
    B('Q', 'record_macro'),
    B('q', 'replay_macro'),
    B('>', 'indent'),
    B('<', 'unindent'),
    B('=', 'format_selections'),
    B('J', 'join_selections'),
    B('A-J', 'join_selections_space'),
    B('K', 'keep_selections'),
    B('A-K', 'remove_selections'),
    B(',', 'keep_primary_selection'),
    B('A-,', 'remove_primary_selection'),
    B('&', 'align_selections'),
    B('_', 'trim_selections'),
    B('(', 'rotate_selections_backward'),
    B(')', 'rotate_selections_forward'),
    B('A-(', 'rotate_selection_contents_backward'),
    B('A-)', 'rotate_selection_contents_forward'),
    B('A-:', 'ensure_selections_forward'),
    B('esc', 'normal_mode'),
    B('C-b|pageup', 'page_up'),
    B('C-f|pagedown', 'page_down'),
    B('C-u', 'page_cursor_half_up'),
    B('C-d', 'page_cursor_half_down'),
    B('C-w', window_node),
    B('C-c', 'toggle_comments'),
    B('C-i|tab', 'jump_forward'),
    B('C-o', 'jump_backward'),
    B('C-s', 'save_selection'),
    B('space', {
      'Space',
      B('f', 'file_picker'),
      B('F', 'file_picker_in_current_directory'),
      B('e', 'file_explorer'),
      B('.', 'file_explorer_in_current_buffer_directory'),
      B('b', 'buffer_picker'),
      B('j', 'jumplist_picker'),
      B('s', 'lsp_or_syntax_symbol_picker'),
      B('S', 'lsp_or_syntax_workspace_symbol_picker'),
      B('d', 'diagnostics_picker'),
      B('D', 'workspace_diagnostics_picker'),
      B('g', 'changed_file_picker'),
      B('a', 'code_action'),
      B("'", 'last_picker'),
      B('G', {
        'Debug (experimental)',
        sticky = true,
        B('l', 'dap_launch'),
        B('r', 'dap_restart'),
        B('b', 'dap_toggle_breakpoint'),
        B('c', 'dap_continue'),
        B('h', 'dap_pause'),
        B('i', 'dap_step_in'),
        B('o', 'dap_step_out'),
        B('n', 'dap_next'),
        B('v', 'dap_variables'),
        B('t', 'dap_terminate'),
        B('C-c', 'dap_edit_condition'),
        B('C-l', 'dap_edit_log'),
        B('s', { 'Switch', B('t', 'dap_switch_thread'), B('f', 'dap_switch_stack_frame') }),
        B('e', 'dap_enable_exceptions'),
        B('E', 'dap_disable_exceptions'),
      }),
      B('w', space_window_node),
      B('y', 'yank_to_clipboard'),
      B('Y', 'yank_main_selection_to_clipboard'),
      B('p', 'paste_clipboard_after'),
      B('P', 'paste_clipboard_before'),
      B('R', 'replace_selections_with_clipboard'),
      B('/', 'global_search'),
      B('k', 'hover'),
      B('r', 'rename_symbol'),
      B('h', 'select_references_to_symbol_under_cursor'),
      B('c', 'toggle_comments'),
      B('C', 'toggle_block_comments'),
      B('A-c', 'toggle_line_comments'),
      B('?', 'command_palette'),
    }),
    B('z', view_node(false)),
    B('Z', view_node(true)),
    B('"', 'select_register'),
    B('<bar>', 'shell_pipe'),
    B('A-<bar>', 'shell_pipe_to'),
    B('!', 'shell_insert_output'),
    B('A-!', 'shell_append_output'),
    B('$', 'shell_keep_pipe'),
    B('C-z', 'suspend'),
    B('C-a', 'increment'),
    B('C-x', 'decrement'),
  }
end

local function select_overrides()
  return {
    'Select mode',
    B('h|left', 'extend_char_left'),
    B('j|down', 'extend_visual_line_down'),
    B('k|up', 'extend_visual_line_up'),
    B('l|right', 'extend_char_right'),
    B('w', 'extend_next_word_start'),
    B('b', 'extend_prev_word_start'),
    B('e', 'extend_next_word_end'),
    B('W', 'extend_next_long_word_start'),
    B('B', 'extend_prev_long_word_start'),
    B('E', 'extend_next_long_word_end'),
    B('A-e', 'extend_parent_node_end'),
    B('A-b', 'extend_parent_node_start'),
    B('n', 'extend_search_next'),
    B('N', 'extend_search_prev'),
    B('t', 'extend_till_char'),
    B('f', 'extend_next_char'),
    B('T', 'extend_till_prev_char'),
    B('F', 'extend_prev_char'),
    B('home', 'extend_to_line_start'),
    B('end', 'extend_to_line_end'),
    B('esc', 'exit_select_mode'),
    B('v', 'normal_mode'),
    B('g', {
      'Goto',
      B('g', 'extend_to_file_start'),
      B('<bar>', 'extend_to_column'),
      B('e', 'extend_to_last_line'),
      B('k', 'extend_line_up'),
      B('j', 'extend_line_down'),
      B('w', 'extend_to_word'),
    }),
  }
end

local function insert_spec()
  return {
    'Insert mode',
    B('esc', 'normal_mode'),
    B('C-s', 'commit_undo_checkpoint'),
    B('C-x', 'completion'),
    B('C-r', 'insert_register'),
    B('C-w|A-backspace', 'delete_word_backward'),
    B('A-d|A-del', 'delete_word_forward'),
    B('C-u', 'kill_to_line_start'),
    B('C-k', 'kill_to_line_end'),
    B('C-h|backspace|S-backspace', 'delete_char_backward'),
    B('C-d|del', 'delete_char_forward'),
    B('C-j|ret', 'insert_newline'),
    B('tab', 'smart_tab'),
    B('S-tab', 'insert_tab'),
    B('up', 'move_visual_line_up'),
    B('down', 'move_visual_line_down'),
    B('left', 'move_char_left'),
    B('right', 'move_char_right'),
    B('pageup', 'page_up'),
    B('pagedown', 'page_down'),
    B('home', 'goto_line_start'),
    B('end', 'goto_line_end_newline'),
  }
end

local function build_spec(spec)
  local function conv(s)
    local n = node(s[1], s.sticky)
    for i = 2, #s do
      local e = s[i]
      local value = e[2]
      if type(value) == 'table' and type(value[1]) == 'string' then value = conv(value) end
      for k in (e[1] .. '|'):gmatch('(.-)|') do
        if k == '<bar>' then k = '|' end
        if k == 'A-<bar>' then k = 'A-|' end
        insert(n, k, value)
      end
    end
    return n
  end
  return conv(spec)
end

local function deep_copy(n)
  if type(n) ~= 'table' or not n.is_node then return n end
  local c = node(n.name, n.sticky)
  for _, k in ipairs(n.keys) do
    c.keys[#c.keys + 1] = k
    c.map[k] = deep_copy(n.map[k])
  end
  return c
end

local function merge(dst, other)
  for _, k in ipairs(other.keys) do
    local v = other.map[k]
    local cur = dst.map[k]
    if type(cur) == 'table' and cur.is_node and type(v) == 'table' and v.is_node then
      merge(cur, v)
    else
      insert(dst, k, v)
    end
  end
end

local function from_config(t)
  local n = node('', false)
  local order = t._order
  if not order then
    order = {}
    for k in pairs(t) do
      if k ~= '_order' then order[#order + 1] = k end
    end
    table.sort(order)
  end
  for _, k in ipairs(order) do
    local v = t[k]
    if type(v) == 'table' then
      if v[1] ~= nil then
        v = { seq = v }
      else
        v = from_config(v)
      end
    end
    insert(n, k, v)
  end
  return n
end

M.maps = nil

function M.build(user_keys)
  local normal = build_spec(normal_spec())
  local select = deep_copy(normal)
  merge(select, build_spec(select_overrides()))
  select.name = normal.name
  local ins = build_spec(insert_spec())
  local maps = { normal = normal, select = select, insert = ins }
  if user_keys then
    for mode, keys in pairs(user_keys) do
      if maps[mode] then merge(maps[mode], from_config(keys)) end
    end
  end
  M.maps = maps
  return maps
end

local static_docs
local function doc_of_static(name)
  if not static_docs then
    static_docs = {}
    for _, e in ipairs(require('hx.command_docs')) do
      static_docs[e[1]] = e[2]
    end
  end
  return static_docs[name]
end
M.static_doc = doc_of_static

function M.doc(value)
  if type(value) == 'table' then
    if value.seq then return '[Multiple commands]' end
    if value.is_node then return value.name end
  end
  if type(value) ~= 'string' then return '' end
  if value:sub(1, 1) == ':' then
    local line = value:sub(2)
    local name, args = line:match('^(%S+)%s*(.*)$')
    name = name or line
    args = args or ''
    local typed = require('hx.typed')
    local cmd = typed.lookup(name)
    if cmd and not cmd.plugin then
      return ':' .. cmd.name .. ' ' .. U.rust_debug_str(args)
    end
    if cmd and cmd.plugin and cmd.doc then return cmd.doc end
    return 'Undocumented plugin command'
  end
  if value:sub(1, 1) == '@' then return value end
  return doc_of_static(value) or value
end

function M.infobox(n)
  local body = {}
  for _, key in ipairs(n.keys) do
    local v = n.map[key]
    local skip = (v == 'no_op')
    if not skip then
      local desc = M.doc(v)
      local found
      for _, e in ipairs(body) do
        if e.desc == desc then
          found = e
          break
        end
      end
      if found then
        found.keys[#found.keys + 1] = key
      else
        body[#body + 1] = { keys = { key }, desc = desc }
      end
    end
  end
  local out = {}
  for _, e in ipairs(body) do
    table.sort(e.keys, K.less)
    out[#out + 1] = { table.concat(e.keys, ', '), e.desc }
  end
  return { title = n.name, body = out }
end

function M.search(n, keys)
  local cur = n
  for _, k in ipairs(keys) do
    if type(cur) ~= 'table' or not cur.is_node then return nil end
    cur = cur.map[k]
    if cur == nil then return nil end
  end
  return cur
end

function M.reverse(mode)
  local rev = {}
  local function walk(n, prefix)
    for _, k in ipairs(n.keys) do
      local v = n.map[k]
      local seq = { unpack(prefix) }
      seq[#seq + 1] = k
      if type(v) == 'table' and v.is_node then
        walk(v, seq)
      elseif type(v) == 'string' then
        rev[v] = rev[v] or {}
        table.insert(rev[v], seq)
      end
    end
  end
  walk(M.maps[mode], {})
  return rev
end

return M
