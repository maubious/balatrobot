-- src/lua/endpoints/skip.lua

-- ==========================================================================
-- Skip Endpoint Params
-- ==========================================================================

---@class Request.Endpoint.Skip.Params

-- ==========================================================================
-- Skip Endpoint
-- ==========================================================================

---@type Endpoint
return {

  name = "skip",

  description = "Skip the current blind (Small or Big only, not Boss)",

  schema = {},

  requires_state = { G.STATES.BLIND_SELECT },

  ---@param _ Request.Endpoint.Skip.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    sendDebugMessage("Init skip()", "BB.ENDPOINTS")

    -- Get the current blind on deck (similar to select endpoint)
    local current_blind = G.GAME.blind_on_deck
    assert(current_blind ~= nil, "skip() called with no blind on deck")
    local current_blind_key = string.lower(current_blind)
    local blind = BB_GAMESTATE.get_blinds_info()[current_blind_key]
    assert(blind ~= nil, "skip() blind not found: " .. current_blind)

    if blind.type == "BOSS" then
      sendDebugMessage("skip() cannot skip Boss blind: " .. current_blind, "BB.ENDPOINTS")
      send_response({
        message = "Cannot skip Boss blind",
        name = BB_ERROR_NAMES.NOT_ALLOWED,
      })
      return
    end

    -- Get the skip button from the tag element
    local blind_pane = G.blind_select_opts[current_blind_key]
    assert(blind_pane ~= nil, "skip() blind pane not found: " .. current_blind)
    local tag_element = blind_pane:get_UIE_by_ID("tag_" .. current_blind)
    assert(tag_element ~= nil, "skip() tag element not found: " .. current_blind)
    local skip_button = tag_element.children[2]
    assert(skip_button ~= nil, "skip() skip button not found: " .. current_blind)

    -- Execute blind skip
    G.FUNCS.skip_blind(skip_button)

    -- Wait for the skip to complete
    -- Completion is indicated by the blind state changing to "Skipped"
    local settle_started = nil
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      blockable = false,
      func = function()
        local blinds = BB_GAMESTATE.get_blinds_info()
        local blind_select_done = (
          G.STATE == G.STATES.BLIND_SELECT
          and G.GAME.blind_on_deck ~= nil
          and G.blind_select_opts ~= nil
          -- skip_blind marks the pane skipped before its immediate tag
          -- application event runs. Waiting for the controller lock avoids
          -- returning a stale balance/tag state to synchronous clients.
          and not G.CONTROLLER.locks.skip_blind
          and blinds[current_blind_key].status == "SKIPPED"
        )
        -- Some skip tags open a booster before the next blind can be
        -- selected. That is also a completed skip: return the open pack so
        -- the caller can choose or skip it, then continue blind selection.
        local pack_open = (
          G.STATE == G.STATES.SMODS_BOOSTER_OPENED
          and G.STATE_COMPLETE
          and G.pack_cards ~= nil
          and not G.pack_cards.REMOVED
          and G.pack_cards.cards[1] ~= nil
        )
        if pack_open then
          local pack_card = G.pack_cards.cards[1]
          local pack_key = pack_card.ability and pack_card.ability.set
          local needs_hand = pack_key == "Tarot" or pack_key == "Spectral"
          if needs_hand then
            local hand_count = G.hand and G.hand.cards and #G.hand.cards or 0
            local deck_count = G.deck and G.deck.cards and #G.deck.cards or 0
            local hand_limit = G.hand and G.hand.config and G.hand.config.card_limit or 8
            local expected_hand_size = math.min(hand_limit, hand_count + deck_count)
            local hand_ready = G.hand
              and not G.hand.REMOVED
              and G.hand.cards
              and hand_count >= expected_hand_size
              and G.hand.T
              and G.hand.T.x
            local cards_positioned = hand_ready
              and (hand_count == 0
                or (G.hand.cards[1].T and G.hand.cards[1].T.x))
            pack_open = hand_ready and cards_positioned
          end
        end
        -- Double Tag and the tag it copies each use controller locks while
        -- their queued effects resolve. Waiting only for skip_blind returns
        -- between those effects with stale money/state.
        local tags_settled = true
        for key, locked in pairs(G.CONTROLLER.locks) do
          -- Tag:yep uses its numeric Tag.ID as the lock key. Other string
          -- keyed controller locks can legitimately remain set in blind
          -- selection and must not hold this endpoint open forever.
          if type(key) == "number" and locked then
            tags_settled = false
            break
          end
        end
        local immediate_tags_settled = true
        for _, tag in ipairs(G.GAME.tags or {}) do
          -- Double Tag can add a copy after skip_blind's immediate-tag loop.
          -- The next blind-selection event applies that copy. Do not return
          -- in the gap while the copied immediate tag is still untriggered.
          if tag.config and tag.config.type == "immediate" and not tag.triggered then
            immediate_tags_settled = false
            break
          end
        end
        local transition_done = (blind_select_done or pack_open)
          and tags_settled
          and immediate_tags_settled
        if not transition_done then
          settle_started = nil
        elseif not settle_started then
          -- Immediate tags can queue one final state change (for example,
          -- Economy Tag's dollar easing). Let that event become observable
          -- before returning a synchronous snapshot.
          settle_started = G.TIMERS.TOTAL
        end
        local done = transition_done
          and settle_started ~= nil
          -- Tag:yep queues its final effect behind a 0.7-second removal
          -- event, after the numeric tag lock has already cleared.
          and G.TIMERS.TOTAL - settle_started >= 0.8
        if done then
          sendDebugMessage("Return skip()", "BB.ENDPOINTS")
          local state_data = BB_GAMESTATE.get_gamestate()
          send_response(state_data)
        end

        return done
      end,
    }))
  end,
}
