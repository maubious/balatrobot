-- src/lua/endpoints/select.lua

-- ==========================================================================
-- Select Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Select.Params

-- ==========================================================================
-- Select Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "select",

  description = "Select the current blind",

  schema = {},

  requires_state = { G.STATES.BLIND_SELECT },

  ---@param _ Request.Endpoint.Select.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    sendDebugMessage("Init select()", "BB.ENDPOINTS")
    -- Get current blind and its UI element
    local current_blind = G.GAME.blind_on_deck
    assert(current_blind ~= nil, "select() called with no blind on deck")
    local blind_pane = G.blind_select_opts[string.lower(current_blind)]
    assert(blind_pane ~= nil, "select() blind pane not found: " .. current_blind)
    local select_button = blind_pane:get_UIE_by_ID("select_blind_button")
    assert(select_button ~= nil, "select() select button not found: " .. current_blind)

    -- Log which blind we're selecting
    local blind_info = BB_GAMESTATE.get_blinds_info()[string.lower(current_blind)]
    local blind_name = blind_info and blind_info.name or current_blind
    local chips = blind_info and blind_info.chips or "?"
    sendDebugMessage(
      string.format("Selecting %s (%s), chips required: %s", current_blind, blind_name, tostring(chips)),
      "BB.ENDPOINTS"
    )

    -- Execute blind selection
    G.FUNCS.select_blind(select_button)

    -- Wait for completion: transition to SELECTING_HAND with facing_blind flag set
    local settle_started = nil
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      blockable = false,
      func = function()
        local ready = (
          G.STATE == G.STATES.SELECTING_HAND
          and G.STATE_COMPLETE
          and G.hand ~= nil
        )
        if not ready then
          settle_started = nil
        elseif not settle_started then
          -- first_hand_drawn queues effects such as Certificate's sealed
          -- playing card after the initial hand reaches SELECTING_HAND.
          settle_started = G.TIMERS.TOTAL
        end
        local done = ready
          and settle_started ~= nil
          and G.TIMERS.TOTAL - settle_started >= 0.25
        if done then
          sendDebugMessage("Return select()", "BB.ENDPOINTS")
          local state_data = BB_GAMESTATE.get_gamestate()
          send_response(state_data)
        end
        return done
      end,
    }))
  end,
}
