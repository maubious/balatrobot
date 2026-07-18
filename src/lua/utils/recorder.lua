-- Capture manual UI actions as a replayable semantic trace.

local nativefs = require("nativefs")
local json = require("json")

local Recorder = {
  active = false,
  actions = {},
  path = nil,
  setup_done = false,
  drag = nil,
}

local function card_index(area, wanted)
  if not area or not area.cards then return nil end
  for index, card in ipairs(area.cards) do
    if card == wanted then return index - 1 end
  end
  return nil
end

local function selected_hand()
  local indices, ids = {}, {}
  if not G.hand or not G.hand.cards then return indices, ids end
  for index, card in ipairs(G.hand.cards) do
    for _, highlighted in ipairs(G.hand.highlighted or {}) do
      if highlighted == card then
        indices[#indices + 1] = index - 1
        ids[#ids + 1] = card.sort_id
        break
      end
    end
  end
  return indices, ids
end

local function card_params(card)
  if not card then return {} end
  return {
    card_id = card.sort_id,
    key = card.config and card.config.center and card.config.center.key,
  }
end

local function drag_area_name(area)
  if area == G.hand then return "hand" end
  if area == G.jokers then return "jokers" end
  return nil
end

local function area_card_ids(area)
  local ids = {}
  for _, card in ipairs((area and area.cards) or {}) do
    ids[#ids + 1] = card.sort_id
  end
  return ids
end

local function same_order(left, right)
  if #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function buy_params(e)
  local card = e and e.config and e.config.ref_table
  local params = card_params(card)
  if not card then return params end
  if e.config.id == "buy_and_use" then params.buy_and_use = true end
  if card.area == G.shop_jokers then
    params.card = card_index(G.shop_jokers, card)
  elseif card.area == G.shop_vouchers then
    params.voucher = card_index(G.shop_vouchers, card)
  elseif card.area == G.shop_booster then
    params.pack = card_index(G.shop_booster, card)
  end
  return params
end

local function sell_params(e)
  local card = e and e.config and e.config.ref_table
  local params = card_params(card)
  if not card then return params end
  if card.area == G.jokers then
    params.joker = card_index(G.jokers, card)
  elseif card.area == G.consumeables then
    params.consumable = card_index(G.consumeables, card)
  end
  return params
end

local function use_params(e)
  local card = e and e.config and e.config.ref_table
  local params = card_params(card)
  if not card then return params end
  local targets, target_ids = selected_hand()
  if card.area == G.consumeables then
    params.consumable = card_index(G.consumeables, card)
    params.cards = targets
    params.card_ids = target_ids
  elseif card.area == G.pack_cards then
    params.card = card_index(G.pack_cards, card)
    params.cards = targets
    params.card_ids = target_ids
  elseif card.area == G.shop_vouchers then
    params.voucher = card_index(G.shop_vouchers, card)
  elseif card.area == G.shop_booster then
    params.pack = card_index(G.shop_booster, card)
  end
  return params
end

local function use_method(e)
  local card = e and e.config and e.config.ref_table
  if card and (card.area == G.shop_vouchers or card.area == G.shop_booster) then
    return "buy"
  end
  return "use"
end

local function record(method, params, pre)
  if not Recorder.active then return end
  Recorder.actions[#Recorder.actions + 1] = {
    method = method,
    params = params or {},
    pre = pre or BB_GAMESTATE.get_gamestate(),
  }
end

local function wrap(name, method, params_fn, predicate)
  local original = G.FUNCS[name]
  if type(original) ~= "function" then return end
  G.FUNCS[name] = function(...)
    local args = {...}
    if Recorder.active and (not predicate or predicate(args[1], args)) then
      local recorded_method = type(method) == "function" and method(args[1]) or method
      record(recorded_method, params_fn and params_fn(args[1]) or {})
    end
    return original(...)
  end
end

local function wrap_sort(name)
  local original = G.FUNCS[name]
  if type(original) ~= "function" then return end
  G.FUNCS[name] = function(...)
    local pre = Recorder.active and BB_GAMESTATE.get_gamestate() or nil
    local result = original(...)
    if Recorder.active then
      record("rearrange", {
        area = "hand",
        card_ids = area_card_ids(G.hand),
      }, pre)
    end
    return result
  end
end

function Recorder.setup()
  if Recorder.setup_done then return true end
  if not G or not G.FUNCS or not CardArea or not CardArea.align_cards then return false end

  wrap("play_cards_from_highlighted", "play", function()
    local cards, card_ids = selected_hand()
    return {cards = cards, card_ids = card_ids}
  end)
  wrap("discard_cards_from_highlighted", "discard", function()
    local cards, card_ids = selected_hand()
    return {cards = cards, card_ids = card_ids}
  end, function(_, args) return not args[2] end)
  wrap("select_blind", "select")
  wrap("skip_blind", "skip")
  wrap("cash_out", "cash_out")
  wrap("toggle_shop", "next_round")
  wrap("reroll_shop", "reroll")
  -- Boss Tag calls the same callback automatically; the skip action already
  -- reproduces that roll, so record only a direct voucher-button use.
  wrap("reroll_boss", "reroll_boss", nil, function()
    return not G.from_boss_tag
  end)
  wrap("buy_from_shop", "buy", buy_params)
  wrap("sell_card", "sell", sell_params)
  wrap("skip_booster", "pack", function() return {skip = true} end)
  wrap("use_card", use_method, use_params, function(e)
    local card = e and e.config and e.config.ref_table
    return card and (card.area == G.consumeables or card.area == G.pack_cards
      or card.area == G.shop_vouchers or card.area == G.shop_booster)
  end)
  wrap_sort("sort_hand_value")
  wrap_sort("sort_hand_suit")

  -- CardArea:align_cards is where manual mouse dragging changes the actual
  -- gameplay order. Capture one semantic rearrange on release, with the
  -- snapshot from before the drag and stable card IDs for the final order.
  local original_align_cards = CardArea.align_cards
  CardArea.align_cards = function(area, ...)
    if Recorder.active then
      local target = G.CONTROLLER and G.CONTROLLER.dragging
        and G.CONTROLLER.dragging.target
      local area_name = drag_area_name(area)
      if area_name and target and target.area == area and not Recorder.drag then
        Recorder.drag = {
          area = area,
          area_name = area_name,
          before = area_card_ids(area),
          pre = BB_GAMESTATE.get_gamestate(),
        }
      end
    end

    local result = original_align_cards(area, ...)

    if Recorder.active and Recorder.drag and Recorder.drag.area == area then
      local target = G.CONTROLLER and G.CONTROLLER.dragging
        and G.CONTROLLER.dragging.target
      if not target then
        local final = area_card_ids(area)
        if not same_order(Recorder.drag.before, final) then
          record("rearrange", {
            area = Recorder.drag.area_name,
            card_ids = final,
          }, Recorder.drag.pre)
        end
        Recorder.drag = nil
      end
    end
    return result
  end

  Recorder.setup_done = true
  return true
end

function Recorder.start(path)
  if not Recorder.setup() then return false, "game callbacks are not ready" end
  Recorder.path = path or (love.filesystem.getSaveDirectory() .. "/balatrobot_recording.json")
  Recorder.actions = {}
  Recorder.drag = nil
  Recorder.active = true
  return true, Recorder.path
end

function Recorder.stop()
  if not Recorder.path then return false, "no recording has been started" end
  Recorder.active = false
  Recorder.drag = nil
  local trace = {
    version = 1,
    actions = Recorder.actions,
    final = BB_GAMESTATE.get_gamestate(),
  }
  local encoded_ok, encoded = pcall(json.encode, trace)
  if not encoded_ok then return false, tostring(encoded) end
  if not nativefs.write(Recorder.path, encoded) then
    return false, "failed to write recording to " .. Recorder.path
  end
  return true, Recorder.path, #Recorder.actions
end

function Recorder.status()
  return {active = Recorder.active, path = Recorder.path, action_count = #Recorder.actions}
end

return Recorder
