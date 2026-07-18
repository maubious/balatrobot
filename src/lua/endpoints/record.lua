-- Start, stop, or inspect manual UI action recording.

---@type Endpoint
return {
  name = "record",
  description = "Capture manual UI actions and gamestate checkpoints",
  schema = {
    enabled = {type = "boolean", required = false},
    path = {type = "string", required = false},
  },
  requires_state = nil,

  execute = function(args, send_response)
    if args.enabled == nil then
      send_response(BB_RECORDER.status())
      return
    end
    if args.enabled then
      local success, result = BB_RECORDER.start(args.path)
      if not success then
        send_response({message = result, name = BB_ERROR_NAMES.INTERNAL_ERROR})
        return
      end
      send_response({success = true, active = true, path = result})
      return
    end

    local success, result, count = BB_RECORDER.stop()
    if not success then
      send_response({message = result, name = BB_ERROR_NAMES.INTERNAL_ERROR})
      return
    end
    send_response({success = true, active = false, path = result, action_count = count})
  end,
}
