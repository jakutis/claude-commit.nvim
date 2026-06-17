---@class ClaudeCommitConfig
---@field auto_suggest boolean Auto-suggest when opening empty commit files
---@field keybinding string|nil Key mapping to trigger suggestion
---@field timeout number Command timeout in milliseconds

---@class ClaudeCommitState
---@field current_suggestion string|nil Current suggestion text
---@field ignore_text_change boolean Flag to ignore text change events
---@field namespace number|nil Neovim namespace for virtual text

local M = {}

---@type ClaudeCommitState
local state = {
  current_suggestion = nil,
  ignore_text_change = false,
  namespace = nil,
}

---@type ClaudeCommitConfig
M.config = {
  auto_suggest = true,
  keybinding = nil,
  timeout = 10000,
}

---Setup the plugin with user configuration
---@param opts ClaudeCommitConfig|nil User configuration options
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend('force', M.config, opts)
  
  if not state.namespace then
    state.namespace = vim.api.nvim_create_namespace('claude_commit_suggestion')
  end
end

---Get the staged git changes for the current commit
---@return string|nil patch The git diff patch
---@return string|nil error Error message if failed
local function get_staged_patch()
  local handle = io.popen('git diff --cached 2>/dev/null')
  if not handle then
    return nil, "Failed to execute git diff --cached command"
  end

  local patch = handle:read('*a')
  handle:close()

  if patch == "" then
    return nil, "No staged changes found. Use 'git add' to stage changes first."
  end

  return patch, nil
end

---Build the prompt for Claude to generate a commit message
---@param patch string The git diff patch
---@return string prompt The formatted prompt
local function build_commit_prompt(patch)
  return "Analyze the provided git diff and generate a concise, descriptive commit message following conventional commit format. Return ONLY the commit message with no additional explanation, commentary, or formatting.\n\n" ..
    "The commit message should:\n" ..
    "- Start with a type (feat, fix, docs, style, refactor, test, chore, etc.)\n" ..
    "- Include a brief description of what changed\n" ..
    "- Be under 50 characters for the subject line\n" ..
    "- Use imperative mood (e.g., 'add', 'fix', 'update')\n\n" ..
    "Example format: 'feat: add user authentication middleware'\n\n" .. patch
end

---Parse Claude's JSON response and extract the commit message
---@param raw_output string Raw JSON response from Claude
---@return string|nil suggestion The cleaned commit message
---@return string|nil error Error message if parsing failed
local function parse_claude_response(raw_output)
  if not raw_output or raw_output == "" then
    return nil, "Claude returned no output"
  end

  local ok, json_result = pcall(vim.fn.json_decode, raw_output)
  if not ok then
    return nil, "Failed to parse Claude JSON response: " .. (raw_output:sub(1, 200) or "")
  end

  local suggestion = json_result.result
  if not suggestion or suggestion == "" then
    return nil, "Claude returned empty result"
  end

  suggestion = suggestion:gsub('^%s+', ''):gsub('%s+$', ''):gsub('\n+$', '')
  return suggestion, nil
end

---Check if current directory is a git repository
---@return boolean is_git True if in a git repository
local function is_git_repository()
  local git_check = io.popen('git rev-parse --git-dir 2>/dev/null')
  if not git_check then
    return false
  end
  git_check:close()
  return true
end

---Get commit suggestion asynchronously using vim.system
---@param callback fun(suggestion: string|nil, error: string|nil)
local function get_suggestion_async(callback)
  if not is_git_repository() then
    callback(nil, "Not in a git repository")
    return
  end

  local patch, err = get_staged_patch()
  if not patch then
    callback(nil, err or "Unknown error getting staged changes")
    return
  end

  local prompt = build_commit_prompt(patch)
  
  local args = {
    'claude',
    '--output-format', 'json',
    '--model', 'sonnet',
    '--max-turns', '1'
  }
  
  vim.system(args, { timeout = M.config.timeout, stdin = prompt }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, "Claude command failed: " .. (result.stderr or "unknown error"))
        return
      end
      
      local suggestion, parse_err = parse_claude_response(result.stdout)
      callback(suggestion, parse_err)
    end)
  end)
end

local function find_target_line(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  
  if #lines == 0 then
    state.ignore_text_change = true
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
    state.ignore_text_change = false
    return 0
  end
  
  local first_non_comment_line = nil
  for i, line in ipairs(lines) do
    if not line:match('^#') then
      first_non_comment_line = i
      break
    end
  end
  
  if not first_non_comment_line then
    state.ignore_text_change = true
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
    state.ignore_text_change = false
    return 0
  elseif lines[first_non_comment_line]:match('%S') then
    state.ignore_text_change = true
    vim.api.nvim_buf_set_lines(buf, first_non_comment_line - 1, first_non_comment_line - 1, false, { "" })
    state.ignore_text_change = false
    return first_non_comment_line - 1
  else
    return first_non_comment_line - 1
  end
end

local function show_suggestion_as_virtual_text(buf, suggestion, target_line)
  vim.api.nvim_buf_clear_namespace(buf, state.namespace, 0, -1)
  
  vim.api.nvim_buf_set_extmark(buf, state.namespace, target_line, 0, {
    virt_text = { { suggestion, 'Comment' } },
    virt_text_pos = 'eol'
  })
  
  vim.defer_fn(function()
    state.current_suggestion = suggestion
  end, 50)
end

---Main function to suggest a commit message
function M.suggest_commit_message()
  vim.notify('Getting commit suggestion...', vim.log.levels.INFO)

  get_suggestion_async(function(suggestion, err)
    if not suggestion then
      vim.notify('Error: ' .. err, vim.log.levels.ERROR)
      return
    end

    local buf = vim.api.nvim_get_current_buf()
    local target_line = find_target_line(buf)
    
    vim.api.nvim_win_set_cursor(0, { target_line + 1, 0 })
    
    vim.schedule(function()
      show_suggestion_as_virtual_text(buf, suggestion, target_line)
      vim.notify('Press Tab to accept suggestion', vim.log.levels.INFO)
    end)
  end)
end

local function accept_suggestion()
  if not state.current_suggestion then
    return false
  end

  local buf = vim.api.nvim_get_current_buf()
  
  vim.api.nvim_buf_clear_namespace(buf, state.namespace, 0, -1)
  
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor_pos[1] - 1
  
  state.ignore_text_change = true
  vim.api.nvim_buf_set_lines(buf, current_line, current_line + 1, false, { state.current_suggestion })
  state.ignore_text_change = false
  
  vim.api.nvim_win_set_cursor(0, { current_line + 1, #state.current_suggestion })
  
  state.current_suggestion = nil
  return true
end

local function setup_keybindings(buf)
  if M.config.keybinding then
    vim.api.nvim_buf_set_keymap(
      buf, 'n', M.config.keybinding, ':ClaudeCommitSuggest<CR>',
      { noremap = true, silent = true, desc = 'Suggest commit message with Claude' }
    )
  end
  local function handle_tab_completion()
    if accept_suggestion() then
      return
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Tab>', true, false, true), 'n', false)
    end
  end

  vim.keymap.set('i', '<Tab>', handle_tab_completion, {
    buffer = buf, noremap = true, silent = true, desc = 'Accept Claude commit suggestion'
  })
  
  vim.keymap.set('n', '<Tab>', function()
    if not accept_suggestion() then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Tab>', true, false, true), 'n', false)
    end
  end, {
    buffer = buf, noremap = true, silent = true, desc = 'Accept Claude commit suggestion'
  })
end

local function setup_text_change_autocmd(buf)
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      if not state.ignore_text_change and state.current_suggestion then
        vim.api.nvim_buf_clear_namespace(buf, state.namespace, 0, -1)
        state.current_suggestion = nil
      end
    end
  })
end

local function buffer_has_content(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, line in ipairs(lines) do
    if not line:match('^#') and line:match('%S') then
      return true
    end
  end
  return false
end

local function setup_auto_suggest(buf)
  if not M.config.auto_suggest or buffer_has_content(buf) then
    return
  end

  vim.defer_fn(function()
    if vim.api.nvim_get_current_buf() == buf and not buffer_has_content(buf) then
      M.suggest_commit_message()
    end
  end, 500)
end

---Setup the commit buffer with keybindings and auto-completion
function M.setup_commit_buffer()
  local buf = vim.api.nvim_get_current_buf()
  
  setup_keybindings(buf)
  setup_text_change_autocmd(buf)
  setup_auto_suggest(buf)
end

return M
