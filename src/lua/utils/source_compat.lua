-- Never attach functions to G.GAME or centre objects: both can enter the run
-- save table, and LÖVE thread channels cannot serialize Lua functions.

local compat = {}
compat.version = 4

function compat.ensure()
  if not Blind then
    return
  end

  -- Blind:modify_hand returns Flint's correctly halved values, while the
  -- SMODS scoring parameters keep the
  -- pre-Flint values because the SMODS wrapper assigns the returned globals
  -- before mod_chips/mod_mult can observe their delta. The stale accumulator
  -- is then used during card scoring and adds the lost amount back.
  --
  -- Wrap only the global class method (which is never serialized) and align
  -- the accumulators with the values that Blind:modify_hand actually returns.
  if not Blind.bb_source_flint_accumulator_v3 then
    local original_modify_hand = Blind.modify_hand
    Blind.modify_hand = function(self, cards, poker_hands, text, mult, hand_chips, scoring_hand)
      local result_mult, result_chips, modded = original_modify_hand(
        self, cards, poker_hands, text, mult, hand_chips, scoring_hand
      )
      if self.name == "The Flint" and not self.disabled
          and SMODS and SMODS.Scoring_Parameters then
        if SMODS.Scoring_Parameters.mult then
          SMODS.Scoring_Parameters.mult.current = result_mult
        end
        if SMODS.Scoring_Parameters.chips then
          SMODS.Scoring_Parameters.chips.current = result_chips
        end
      end
      return result_mult, result_chips, modded
    end
    Blind.bb_source_flint_accumulator_v3 = true
  end

  -- SMODS resolves XMult through its additive scoring-parameter interface as
  --     mult + mult * (x_mult - 1)
  -- while the gameplay calculation evaluates
  --     mult * x_mult
  -- directly. They are algebraically equivalent but not floating-point
  -- equivalent, so an integer-boundary score can differ by one. Keep all of
  -- SMODS' effect dispatch and presentation, but make the one intercepted
  -- parameter update use direct multiplication. This applies to every XMult
  -- effect; it is independent of card identity, value, and Joker order.
  local mult_parameter = SMODS and SMODS.Scoring_Parameters
      and SMODS.Scoring_Parameters.mult
  if mult_parameter and not mult_parameter.bb_source_xmult_v4 then
    local original_calc_effect = mult_parameter.calc_effect
    local xmult_keys = {
      x_mult = true,
      xmult = true,
      Xmult = true,
      x_mult_mod = true,
      Xmult_mod = true,
    }

    mult_parameter.calc_effect = function(self, effect, scored_card, key, amount, from_edition)
      if xmult_keys[key] and amount ~= 1 then
        local original_modify = self.modify
        local starting_mult = mult

        -- original_calc_effect calls self:modify exactly once for this key.
        -- Override only that call, and restore the method even if downstream
        -- presentation code raises an error.
        self.modify = function(parameter)
          mult = starting_mult * amount
          parameter.current = mult
          update_hand_text({delay = 0}, {mult = parameter.current})
        end
        local ok, result = pcall(
          original_calc_effect,
          self, effect, scored_card, key, amount, from_edition
        )
        self.modify = original_modify
        if not ok then error(result, 0) end
        return result
      end
      return original_calc_effect(self, effect, scored_card, key, amount, from_edition)
    end
    mult_parameter.bb_source_xmult_v4 = true
  end
end

compat.ensure()
return compat
