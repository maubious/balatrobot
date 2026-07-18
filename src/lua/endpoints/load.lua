-- src/lua/endpoints/load.lua

-- ==========================================================================
-- Load Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Load.Params
---@field path string File path to the save file

-- ==========================================================================
-- Load Endpoint Utils
-- ==========================================================================

local nativefs = require("nativefs")

-- ==========================================================================
-- Load Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "load",

  description = "Load a saved run state from a file",

  schema = {
    path = {
      type = "string",
      required = true,
      description = "File path to the save file",
    },
  },

  requires_state = nil,

  ---@param args Request.Endpoint.Load.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    sendDebugMessage("Init load()", "BB.ENDPOINTS")
    local path = args.path

    -- Read file using nativefs
    -- NOTE: We intentionally skip nativefs.getInfo() and go straight to
    -- nativefs.read().  On Proton/Wine, getInfo() uses PHYSFS_mount which
    -- cannot resolve Linux absolute paths, but read() goes through fopen()
    -- which Wine intercepts and handles correctly.
    local compressed_data = nativefs.read(path)
    ---@cast compressed_data string
    if not compressed_data then
      send_response({
        message = "Failed to read save file: '" .. path .. "'",
        name = BB_ERROR_NAMES.INTERNAL_ERROR,
      })
      return
    end

    -- Write to temp location for get_compressed to read
    local temp_filename = "balatrobot_temp_load_" .. BB_SETTINGS.port .. ".jkr"
    local save_dir = love.filesystem.getSaveDirectory()
    local temp_path = save_dir .. "/" .. temp_filename

    local write_success = nativefs.write(temp_path, compressed_data)
    if not write_success then
      send_response({
        message = "Failed to prepare save file for loading",
        name = BB_ERROR_NAMES.INTERNAL_ERROR,
      })
      return
    end

    -- A checkpoint restore replaces the branch completely. The normal queue
    -- clear preserves no_delete events for UI transitions, but those events
    -- belong to the discarded branch and may mutate the restored run later.
    if G.E_MANAGER and G.E_MANAGER.queues then
      for _, queue in pairs(G.E_MANAGER.queues) do
        for index = #queue, 1, -1 do
          table.remove(queue, index)
        end
      end
    end

    -- Load using the game's built-in functions.
    G:delete_run()
    G.SAVED_GAME = get_compressed(temp_filename) ---@diagnostic disable-line: undefined-global

    if G.SAVED_GAME == nil then
      send_response({
        message = "Invalid save file format",
        name = BB_ERROR_NAMES.INTERNAL_ERROR,
      })
      love.filesystem.remove(temp_filename)
      return
    end

    G.SAVED_GAME = STR_UNPACK(G.SAVED_GAME)

    -- Game:start_run normalizes zero-valued pseudorandom entries and Card
    -- reconstruction may touch additional streams. That is appropriate for a
    -- normal continue, but validation checkpoints must restore the hidden RNG
    -- state exactly so a loaded branch matches uninterrupted gameplay.
    local saved_pseudorandom = G.SAVED_GAME
      and G.SAVED_GAME.GAME
      and G.SAVED_GAME.GAME.pseudorandom
      and copy_table(G.SAVED_GAME.GAME.pseudorandom)

    -- Match Game:start_run's save-load normalization. Zero is a serialized
    -- sentinel, not a usable stream value (and is truthy in Lua), so restoring
    -- it verbatim would make the next pseudoseed advance from zero rather than
    -- from pseudohash(key .. seed).
    if saved_pseudorandom then
      for key, value in pairs(saved_pseudorandom) do
        if value == 0 then
          saved_pseudorandom[key] = pseudohash(key .. saved_pseudorandom.seed)
        end
      end
      saved_pseudorandom.hashed_seed = pseudohash(saved_pseudorandom.seed)
    end

    -- STR_PACK serializes hash keys in pairs() order. Recreating GAME.hands
    -- from that text can therefore change the table's iteration order, while
    -- source effects such as To Do List intentionally build their candidate
    -- list with pairs(G.GAME.hands). Keep the source-created outer table (and
    -- its uninterrupted-run order), but copy every saved hand value into it.
    if G.SAVED_GAME.GAME and G.SAVED_GAME.GAME.hands then
      local saved_hands = G.SAVED_GAME.GAME.hands
      local source_hands = G:init_game_object().hands
      for hand_key, saved_hand in pairs(saved_hands) do
        if source_hands[hand_key] then
          for field, value in pairs(saved_hand) do
            source_hands[hand_key][field] = value
          end
        else
          source_hands[hand_key] = saved_hand
        end
      end
      G.SAVED_GAME.GAME.hands = source_hands
    end

    BB_PENDING_PSEUDORANDOM_RESTORE = nil

    -- Temporarily suppress "Card area not instantiated" warnings during load
    -- These are expected when loading a save from shop state (shop CardAreas
    -- are created later when the shop UI renders, and the game handles this)
    local original_print = print
    print = function(msg)
      if type(msg) == "string" and msg:find("ERROR LOADING GAME: Card area") then
        return -- suppress expected warning
      end
      original_print(msg)
    end

    G:start_run({ savetext = G.SAVED_GAME })

    -- Restore original print
    print = original_print

    -- Clean up
    love.filesystem.remove(temp_filename)

    local num_items = function(area)
      local count = 0
      if area and area.cards then
        for _, v in ipairs(area.cards) do
          if v.children.buy_button and v.children.buy_button.definition then
            count = count + 1
          end
        end
      end
      return count
    end

    G.E_MANAGER:add_event(Event({
      no_delete = true,
      trigger = "condition",
      blocking = false,
      func = function()
        local done = false

        if not G.STATE_COMPLETE or G.CONTROLLER.locked then
          return false
        end

        if G.STATE == G.STATES.BLIND_SELECT then
          done = G.GAME.blind_on_deck ~= nil
            and G.blind_select_opts ~= nil
            and G.blind_select_opts["small"]:get_UIE_by_ID("tag_Small") ~= nil
        end

        if G.STATE == G.STATES.SELECTING_HAND then
          done = G.hand ~= nil
        end

        if G.STATE == G.STATES.ROUND_EVAL and G.round_eval then
          for _, b in ipairs(G.I.UIBOX) do
            if b:get_UIE_by_ID("cash_out_button") then
              done = true
            end
          end
        end

        if G.STATE == G.STATES.SHOP then
          done = num_items(G.shop_booster) > 0 or num_items(G.shop_jokers) > 0 or num_items(G.shop_vouchers) > 0
        end

        if G.STATE == G.STATES.SMODS_BOOSTER_OPENED then
          done = G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0
        end

        if done then
          -- start_run schedules part of card/shop reconstruction on the event
          -- manager. Restoring immediately after start_run is therefore too
          -- early: those deferred Card:set_ability calls can advance hidden
          -- streams (notably `to_do`) before the loaded state settles. Apply
          -- the saved table at the same boundary exposed to API callers.
          BB_PENDING_PSEUDORANDOM_RESTORE = saved_pseudorandom
          saved_pseudorandom = nil
          sendDebugMessage("Return load() - loaded from " .. path, "BB.ENDPOINTS")
          send_response({
            success = true,
            path = path,
          })
        end
        return done
      end,
    }))
  end,
}
