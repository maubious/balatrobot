-- src/lua/endpoints/cash_out.lua

-- ==========================================================================
-- CashOut Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.CashOut.Params

-- ==========================================================================
-- CashOut Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "cash_out",

  description = "Cash out and collect round rewards",

  schema = {},

  requires_state = { G.STATES.ROUND_EVAL },

  ---@param _ Request.Endpoint.CashOut.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    sendDebugMessage("Init cash_out()", "BB.ENDPOINTS")
    G.FUNCS.cash_out({ config = {} })

    local area_ready = function(area)
      local count = 0
      if area and area.cards then
        for _, v in ipairs(area.cards) do
          if v.temp_edition or not v.children.buy_button or not v.children.buy_button.definition then
            return false, count
          end
          count = count + 1
        end
      end
      return true, count
    end

    -- Wait for SHOP state after state transition completes
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      func = function()
        local done = false
        if G.STATE == G.STATES.SHOP and G.STATE_COMPLETE then
          local boosters_ready, boosters = area_ready(G.shop_booster)
          local cards_ready, cards = area_ready(G.shop_jokers)
          local vouchers_ready, vouchers = area_ready(G.shop_vouchers)
          local tags_ready = true
          for _, tag in ipairs(G.GAME.tags or {}) do
            if tag.config and tag.config.type == "store_joker_modify" then
              tags_ready = false
              break
            end
          end
          done = boosters_ready
            and cards_ready
            and vouchers_ready
            and tags_ready
            and boosters + cards + vouchers > 0
          if done then
            sendDebugMessage("Return cash_out() - reached SHOP state", "BB.ENDPOINTS")
            send_response(BB_GAMESTATE.get_gamestate())
            return done
          end
        end
        return done
      end,
    }))
  end,
}
