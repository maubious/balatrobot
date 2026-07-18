-- Reroll the upcoming Boss Blind through Director's Cut or Retcon.

---@class Request.Endpoint.RerollBoss.Params

---@type Endpoint
return {

  name = "reroll_boss",

  description = "Reroll the upcoming Boss Blind for $10",

  schema = {},

  requires_state = { G.STATES.BLIND_SELECT },

  ---@param _ Request.Endpoint.RerollBoss.Params
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    local used = G.GAME.used_vouchers or {}
    local resets = G.GAME.round_resets or {}
    local allowed = used.v_retcon
      or (used.v_directors_cut and not resets.boss_rerolled)

    if not allowed then
      send_response({
        message = "Boss reroll requires Retcon or an unused Director's Cut",
        name = BB_ERROR_NAMES.NOT_ALLOWED,
      })
      return
    end

    local available_money = G.GAME.dollars - G.GAME.bankrupt_at
    if available_money < 10 then
      send_response({
        message = "Not enough dollars to reroll Boss Blind. Available: "
          .. available_money .. ", Required: 10",
        name = BB_ERROR_NAMES.NOT_ALLOWED,
      })
      return
    end

    G.FUNCS.reroll_boss(nil)

    -- The callback rebuilds the Boss panel asynchronously and holds
    -- this lock until the new panel is usable. Return the settled gamestate.
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      blockable = false,
      func = function()
        local done = G.STATE == G.STATES.BLIND_SELECT
          and not G.CONTROLLER.locks.boss_reroll
        if done then
          send_response(BB_GAMESTATE.get_gamestate())
        end
        return done
      end,
    }))
  end,
}
