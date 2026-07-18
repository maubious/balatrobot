-- src/lua/endpoints/sell.lua

-- ==========================================================================
-- Sell Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Sell.Params
---@field joker integer? 0-based index of joker to sell
---@field consumable integer? 0-based index of consumable to sell

-- ==========================================================================
-- Sell Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "sell",

  description = "Sell a joker or consumable from player inventory",

  schema = {
    joker = {
      type = "integer",
      required = false,
      description = "0-based index of joker to sell",
    },
    consumable = {
      type = "integer",
      required = false,
      description = "0-based index of consumable to sell",
    },
  },

  requires_state = {
    G.STATES.BLIND_SELECT,
    G.STATES.SELECTING_HAND,
    G.STATES.SHOP,
    G.STATES.SMODS_BOOSTER_OPENED,
  },

  ---@param args Request.Endpoint.Sell.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(args, send_response)
    sendDebugMessage("Init sell()", "BB.ENDPOINTS")

    -- Validate exactly one parameter is provided
    local param_count = (args.joker and 1 or 0) + (args.consumable and 1 or 0)
    if param_count == 0 then
      send_response({
        message = "Must provide exactly one of: joker or consumable",
        name = BB_ERROR_NAMES.BAD_REQUEST,
      })
      return
    elseif param_count > 1 then
      send_response({
        message = "Can only sell one item at a time",
        name = BB_ERROR_NAMES.BAD_REQUEST,
      })
      return
    end

    -- Determine which type to sell and validate existence
    local source_array, pos, sell_type

    if args.joker then
      -- Validate G.jokers exists and has cards
      if not G.jokers or not G.jokers.config or G.jokers.config.card_count == 0 then
        send_response({
          message = "No jokers available to sell",
          name = BB_ERROR_NAMES.NOT_ALLOWED,
        })
        return
      end
      source_array = G.jokers.cards
      pos = args.joker + 1 -- Convert to 1-based
      sell_type = "joker"
    else -- args.consumable
      -- Validate G.consumeables exists and has cards
      if not G.consumeables or not G.consumeables.config or G.consumeables.config.card_count == 0 then
        send_response({
          message = "No consumables available to sell",
          name = BB_ERROR_NAMES.NOT_ALLOWED,
        })
        return
      end
      source_array = G.consumeables.cards
      pos = args.consumable + 1 -- Convert to 1-based
      sell_type = "consumable"
    end

    -- Validate card exists at index
    if not source_array[pos] then
      send_response({
        message = "Index out of range for " .. sell_type .. ": " .. (pos - 1),
        name = BB_ERROR_NAMES.BAD_REQUEST,
      })
      return
    end

    local card = source_array[pos]

    -- Track initial state for completion verification
    local area = sell_type == "joker" and G.jokers or G.consumeables
    local initial_count = area.config.card_count
    local initial_money = G.GAME.dollars
    local expected_money = initial_money + card.sell_cost
    local card_id = card.sort_id

    -- Log what we're selling
    local item_name = card.ability and card.ability.name or "Unknown"
    local expects_invisible_replacement = (
      item_name == "Invisible Joker"
      and card.ability.invis_rounds >= card.ability.extra
    )
    local expects_boss_disable = (
      item_name == "Luchador"
      and G.GAME.blind
      and not G.GAME.blind.disabled
      and G.GAME.blind:get_type() == "Boss"
    )
    sendDebugMessage(string.format("Selling %s '%s' for $%d", sell_type, item_name, card.sell_cost), "BB.ENDPOINTS")

    -- Create mock UI element for G.FUNCS.sell_card
    local mock_element = {
      config = {
        ref_table = card,
      },
    }

    -- Call the game function to trigger sell
    G.FUNCS.sell_card(mock_element)

    -- Wait for sell completion with comprehensive verification
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      func = function()
        -- Check all 5 completion criteria
        local current_area = sell_type == "joker" and G.jokers or G.consumeables
        local current_array = current_area.cards

        -- 1. The area did not grow. Mature Invisible Joker replaces itself
        -- with a duplicate, so its successful sale keeps the count equal
        -- instead of decreasing it by one.
        local count_valid
        if expects_invisible_replacement then
          count_valid = current_area.config.card_count == initial_count
        else
          count_valid = current_area.config.card_count <= initial_count
        end

        -- 2. Money increased by sell_cost
        local money_increased = (G.GAME.dollars == expected_money)

        -- 3. Card no longer exists (verify by unique_val)
        local card_gone = true
        for _, c in ipairs(current_array) do
          if c.sort_id == card_id then
            card_gone = false
            break
          end
        end

        -- 4. State stability
        local state_stable = G.STATE_COMPLETE == true

        -- 5. Still in valid state
        local valid_state = (
          G.STATE == G.STATES.BLIND_SELECT
          or G.STATE == G.STATES.SHOP
          or G.STATE == G.STATES.SELECTING_HAND
          or G.STATE == G.STATES.SMODS_BOOSTER_OPENED
        )

        -- Card:can_use_consumeable rejects the next synchronous action while
        -- a sale animation still owns the controller or STOP_USE window.
        -- Removal and money settle earlier, so wait for those source gates as
        -- well before acknowledging the sale.
        local controller_ready = not G.CONTROLLER.locked
          and not G.CONTROLLER.locks.use
          and not (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)

        -- Selling these Jokers queues or performs gameplay effects in
        -- addition to removing the card. Do not acknowledge the sale before
        -- those effects are observable by the next synchronous request.
        local effect_settled = true
        if item_name == "Diet Cola" then
          effect_settled = false
          for _, tag in ipairs(G.GAME.tags or {}) do
            if tag.key == "tag_double" then
              effect_settled = true
              break
            end
          end
        elseif expects_boss_disable then
          effect_settled = G.GAME.blind.disabled
        end

        -- All conditions must be met
        if count_valid and money_increased and card_gone and state_stable
          and valid_state and controller_ready and effect_settled
        then
          sendDebugMessage("Return sell()", "BB.ENDPOINTS")
          send_response(BB_GAMESTATE.get_gamestate())
          return true
        end

        return false
      end,
    }))
  end,
}
