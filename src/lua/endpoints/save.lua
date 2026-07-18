-- src/lua/endpoints/save.lua

-- ==========================================================================
-- Save Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Save.Params
---@field path string File path for the save file

-- ==========================================================================
-- Save Endpoint Utils
-- ==========================================================================

local nativefs = require("nativefs")

-- STR_PACK relies on Lua's implicit number-to-string conversion, which keeps
-- too few digits to round-trip every binary64 value. That is appropriate for
-- ordinary game saves, but a differential checkpoint must be a byte-exact
-- snapshot of numeric simulator state: otherwise loading the live checkpoint
-- can move a value by one ULP while the cloned native state is unchanged.
-- Keep the existing table format and only make number formatting lossless.
local function exact_number(value)
  if value ~= value then return "(0/0)" end
  if value == math.huge then return "(1/0)" end
  if value == -math.huge then return "(-1/0)" end
  return string.format("%.17g", value)
end

local function exact_pack(data, recursive)
  local result = (recursive and "" or "return ") .. "{"
  for key, value in pairs(data) do
    local key_type, value_type = type(key), type(value)
    assert(key_type ~= "table", "Data table cannot have a table as a key reference")
    if key_type == "string" then
      key = "[" .. string.format("%q", key) .. "]"
    elseif key_type == "number" then
      key = "[" .. exact_number(key) .. "]"
    else
      key = "[" .. tostring(key) .. "]"
    end

    if value_type == "table" then
      if value.is and value:is(Object) then
        value = [["MANUAL_REPLACE"]]
      else
        value = exact_pack(value, true)
      end
    elseif value_type == "number" then
      value = exact_number(value)
    elseif value_type == "string" then
      value = string.format("%q", value)
    elseif value_type == "boolean" then
      value = value and "true" or "false"
    end
    result = result .. key .. "=" .. value .. ","
  end
  return result .. "}"
end

-- ==========================================================================
-- Save Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "save",

  description = "Save the current run state to a file",

  schema = {
    path = {
      type = "string",
      required = true,
      description = "File path for the save file",
    },
  },

  requires_state = {
    G.STATES.SELECTING_HAND,
    G.STATES.HAND_PLAYED,
    G.STATES.DRAW_TO_HAND,
    G.STATES.GAME_OVER,
    G.STATES.SHOP,
    G.STATES.PLAY_TAROT,
    G.STATES.BLIND_SELECT,
    G.STATES.ROUND_EVAL,
    G.STATES.TAROT_PACK,
    G.STATES.PLANET_PACK,
    G.STATES.SPECTRAL_PACK,
    G.STATES.STANDARD_PACK,
    G.STATES.BUFFOON_PACK,
    G.STATES.NEW_ROUND,
    G.STATES.SMODS_BOOSTER_OPENED,
  },

  ---@param args Request.Endpoint.Save.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    sendDebugMessage("Init save()", "BB.ENDPOINTS")
    local path = args.path

    -- Validate we're in a run
    if not G.STAGE or G.STAGE ~= G.STAGES.RUN then
      send_response({
        message = "Can only save during an active run",
        name = BB_ERROR_NAMES.INVALID_STATE,
      })
      return
    end

    -- Call save_run() and use compress_and_save
    save_run() ---@diagnostic disable-line: undefined-global

    local save_string = exact_pack(G.ARGS.save_run)
    local compressed_data = love.data.compress("string", "deflate", save_string, 1)

    if not compressed_data then
      send_response({
        message = "Failed to save game state",
        name = BB_ERROR_NAMES.INTERNAL_ERROR,
      })
      return
    end

    local write_success = nativefs.write(path, compressed_data)
    if not write_success then
      send_response({
        message = "Failed to write save file to '" .. path .. "'",
        name = BB_ERROR_NAMES.INTERNAL_ERROR,
      })
      return
    end

    sendDebugMessage("Return save() - saved to " .. path, "BB.ENDPOINTS")
    send_response({
      success = true,
      path = path,
    })
  end,
}
