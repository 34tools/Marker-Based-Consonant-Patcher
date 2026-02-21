-- 34tools.edit — Marker-Based Consonant Patcher (ReaImGui)
-- @version 0.3.9
-- UI: Header text is "Marker-Based Consonant Patcher" (removed "34tools.edit — ")
-- UI: Footer buttons right-aligned: Add slot... / Insert all / ?
-- UI: Slot rows keep left alignment; X button is pinned to the right edge of the list
-- UI: Footer status is fixed-width: starts at content left edge, ends before buttons block
-- UI: Small buttons aligned: X and ? share the same width
-- UI: Status is inline in footer row (left), no border (fill only)
-- STATUS: All status messages are <= 20 characters
-- FIX: Help overlay closes on any click (including inside panel) and consumes next frame to prevent click-through
-- CHANGE: Added +50px extra bottom height to the window

local r = reaper
local proj = 0

local CONFIG = {
  WINDOW_TITLE = "Marker-Based Consonant Patcher (34tools.edit)",
  HEADER_TITLE = "Marker-Based Consonant Patcher",
  MSGBOX_TITLE = "34tools.edit — Marker-Based Consonant Patcher",

  WIN_W = 345,

  PATCH_TRACK_NAME = "PATCH",
  PATCH_COLOR_RGB  = { 80, 170, 255 },
  FADE             = 0.005,
  EMPTY_NAME       = "<empty>",

  HELP_PANEL_W = 320,
  HELP_PANEL_H = 235,

  COLOR_ERR  = 0xFF4040FF,
  COLOR_INFO = 0xB0B0B0FF,

  SLOTS_VISIBLE_ROWS = 6,
  ROW_SPACING_Y = 6,

  GAP_AFTER_HEADER = 8,
  GAP_BEFORE_FOOTER = 8,
  GAP_AFTER_FOOTER = 0, -- footer includes status; keep it tight

  STATUS_H = 16,
  STATUS_PAD_X = 8,
  STATUS_PAD_Y = 2,
  STATUS_MIN_W = 110,
  STATUS_RIGHT_MARGIN = 6,

  EXTRA_BOTTOM_PX = 50,

  -- Unified spacing / alignment
  ROW_GAP_X = 6,        -- same gap for slot rows and footer
  FOOTER_GAP = 6,
  SMALL_BTN_W = 22,     -- X and ? share width (align)
}

local function msg(s)
  r.ShowMessageBox(tostring(s or ""), CONFIG.MSGBOX_TITLE, 0)
end

if not r.ImGui_CreateContext then
  msg("ReaImGui is not installed.\n\nInstall via ReaPack:\nReaPack → Browse packages → 'ReaImGui' → Install/Apply.")
  return
end

-- ============================================================================
-- CORE (MP)
-- ============================================================================
local MP = {}

local function now() return r.time_precise() end
local function lower(s) return string.lower(tostring(s or "")) end

local function endswith_ci(s, suffix)
  s = lower(s)
  suffix = lower(suffix)
  return suffix ~= "" and s:sub(-#suffix) == suffix
end

local function begin_undo()
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
end

local function end_undo(name)
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock(name or "34tools.edit: Marker-Based Consonant Patcher", -1)
  r.UpdateArrange()
end

-- Status (auto-hide)
MP._status_msg   = ""
MP._status_iserr = false
MP._status_until = 0.0

function MP.set_status(msg_, is_error, seconds)
  MP._status_msg   = tostring(msg_ or "")
  MP._status_iserr = is_error and true or false
  MP._status_until = now() + (seconds or (MP._status_iserr and 4.0 or 2.0))
end

local function status_expired()
  return MP._status_msg ~= "" and MP._status_until > 0 and now() > MP._status_until
end

function MP.get_status()
  if status_expired() then
    MP._status_msg, MP._status_iserr, MP._status_until = "", false, 0.0
  end
  return MP._status_msg, MP._status_iserr
end

-- Slots
local function make_slot()
  return { name = CONFIG.EMPTY_NAME, cap = nil }
end

MP.slots = { make_slot(), make_slot(), make_slot() }

local function sanitize_slot_name(s)
  s = tostring(s or "")
  s = s:gsub("%s+", "")
  s = s:gsub("@", "")
  if s == "" then return CONFIG.EMPTY_NAME end
  return s
end

local function is_slot_named(slot)
  return slot.name and slot.name ~= "" and slot.name ~= CONFIG.EMPTY_NAME
end

function MP.set_slot_name(i, name)
  local slot = MP.slots[i]
  if not slot then return end
  slot.name = sanitize_slot_name(name)
end

function MP.add_slot()
  MP.slots[#MP.slots+1] = make_slot()
  MP.set_status("Slot added.", false, 2.0)
  return #MP.slots
end

function MP.delete_slot(i)
  if #MP.slots <= 1 then return false end
  table.remove(MP.slots, i)
  MP.set_status("Slot deleted.", false, 2.0)
  return true
end

function MP.reset(i)
  local slot = MP.slots[i]
  if not slot then return end
  slot.cap = nil
  slot.name = CONFIG.EMPTY_NAME
  MP.set_status("Slot reset.", false, 2.0)
end

-- Track helpers
local function get_track_name(tr)
  local _, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
  return name or ""
end

local function set_track_name(tr, name)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
end

local function set_track_selected(tr, sel)
  r.SetTrackSelected(tr, sel and true or false)
end

local function save_selected_tracks()
  local t = {}
  local n = r.CountSelectedTracks(proj)
  for i = 0, n - 1 do t[#t+1] = r.GetSelectedTrack(proj, i) end
  return t
end

local function restore_selected_tracks(saved)
  r.Main_OnCommand(40297, 0)
  for _, tr in ipairs(saved or {}) do
    if tr then set_track_selected(tr, true) end
  end
end

local function get_track_index(tr)
  local tn = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
  if not tn or tn <= 0 then return -1 end
  return math.floor(tn - 1 + 0.5)
end

-- Visibility snapshot/restore (TCP/MCP)
local function save_track_visibility()
  local vis = {}
  local tr_count = r.CountTracks(proj)
  for i = 0, tr_count - 1 do
    local tr = r.GetTrack(proj, i)
    if tr then
      local guid = r.GetTrackGUID(tr)
      vis[guid] = {
        tcp = r.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP"),
        mcp = r.GetMediaTrackInfo_Value(tr, "B_SHOWINMIXER"),
      }
    end
  end
  return vis
end

local function restore_track_visibility(vis)
  if not vis then return end
  local tr_count = r.CountTracks(proj)
  for i = 0, tr_count - 1 do
    local tr = r.GetTrack(proj, i)
    if tr then
      local guid = r.GetTrackGUID(tr)
      local v = vis[guid]
      if v then
        r.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", v.tcp)
        r.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", v.mcp)
      end
    end
  end
end

local function ensure_patch_track_at_top()
  local vis = save_track_visibility()

  local tr_count = r.CountTracks(proj)
  local patch = nil
  for i = 0, tr_count - 1 do
    local tr = r.GetTrack(proj, i)
    if tr and get_track_name(tr) == CONFIG.PATCH_TRACK_NAME then
      patch = tr
      break
    end
  end

  begin_undo()

  if not patch then
    r.InsertTrackAtIndex(0, true)
    patch = r.GetTrack(proj, 0)
    if not patch then
      end_undo("34tools.edit: Ensure PATCH")
      restore_track_visibility(vis)
      MP.set_status("Can't create PATCH", true, 4.0)
      return nil
    end
    set_track_name(patch, CONFIG.PATCH_TRACK_NAME)
  end

  local idx = get_track_index(patch)
  if idx ~= 0 then
    local saved = save_selected_tracks()
    r.Main_OnCommand(40297, 0)
    set_track_selected(patch, true)
    r.ReorderSelectedTracks(0, 0)
    restore_selected_tracks(saved)
    patch = r.GetTrack(proj, 0)
  end

  local c = r.ColorToNative(CONFIG.PATCH_COLOR_RGB[1], CONFIG.PATCH_COLOR_RGB[2], CONFIG.PATCH_COLOR_RGB[3]) | 0x1000000
  r.SetTrackColor(patch, c)

  end_undo("34tools.edit: Ensure PATCH")

  restore_track_visibility(vis)

  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  if r.UpdateTimeline then r.UpdateTimeline() end

  return patch
end

-- Chunk utilities
local function chunk_set_position_to_zero(chunk)
  return chunk:gsub("POSITION%s+[%-%d%.]+", "POSITION 0.0", 1)
end

local function chunk_replace_guid(chunk)
  local new_guid = r.genGuid and r.genGuid() or "{00000000-0000-0000-0000-000000000000}"
  return chunk:gsub("GUID%s+%b{}", "GUID " .. new_guid, 1)
end

function MP.capture(i)
  local slot = MP.slots[i]
  if not slot then return false end

  if r.CountSelectedMediaItems(proj) ~= 1 then
    MP.set_status("Select item to cap", true, 4.0)
    return false
  end

  local item = r.GetSelectedMediaItem(proj, 0)
  if not item then
    MP.set_status("No item selected", true, 4.0)
    return false
  end

  local take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then
    MP.set_status("Item has no audio", true, 4.0)
    return false
  end

  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok or not chunk or chunk == "" then
    MP.set_status("Can't read chunk", true, 4.0)
    return false
  end

  chunk = chunk_set_position_to_zero(chunk)
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH") or 0.0
  slot.cap = { chunk = chunk, len = item_len }

  MP.set_status("Captured", false, 2.0)
  return true
end

local function insert_captured_at_time(slot, t, dest_tr)
  if not slot.cap or not slot.cap.chunk then return false end
  if not dest_tr then return false end

  local item = r.AddMediaItemToTrack(dest_tr)
  if not item then return false end

  local chunk = chunk_replace_guid(slot.cap.chunk)
  local ok = r.SetItemStateChunk(item, chunk, false)
  if not ok then return false end

  r.SetMediaItemInfo_Value(item, "D_POSITION", t)
  r.SetMediaItemInfo_Value(item, "D_FADEINLEN", CONFIG.FADE)
  r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", CONFIG.FADE)
  if slot.cap.len and slot.cap.len > 0 then
    r.SetMediaItemInfo_Value(item, "D_LENGTH", slot.cap.len)
  end
  return true
end

function MP.insert_to_point(i)
  local slot = MP.slots[i]
  if not slot then return end

  if not slot.cap then
    MP.set_status("Slot is empty", true, 4.0)
    return
  end

  local dest_tr = r.GetSelectedTrack(proj, 0)
  if not dest_tr then
    MP.set_status("Select dest track", true, 4.0)
    return
  end

  begin_undo()
  local ok = insert_captured_at_time(slot, r.GetCursorPosition(), dest_tr)
  end_undo("34tools.edit: Insert to point")

  if ok then MP.set_status("Inserted @ cursor", false, 2.0)
  else MP.set_status("Insert failed", true, 4.0) end
end

function MP.insert_all()
  local ts_start, ts_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not ts_start or not ts_end or ts_end <= ts_start then
    MP.set_status("No time selection", true, 4.0)
    return
  end

  local patch_tr = ensure_patch_track_at_top()
  if not patch_tr then return end

  local map = {}
  for _, s in ipairs(MP.slots) do
    if is_slot_named(s) then
      map[lower(s.name)] = s
    end
  end

  begin_undo()
  local inserted = 0
  local _, num_markers, num_regions = r.CountProjectMarkers(proj)
  local total = (num_markers or 0) + (num_regions or 0)

  for i = 0, total - 1 do
    local rv, isrgn, pos, _, name, markidx, color = r.EnumProjectMarkers3(proj, i)
    if rv and (not isrgn) and pos >= ts_start and pos <= ts_end then
      local n = tostring(name or "")
      local n_low = lower(n)
      if (not endswith_ci(n_low, "_inserted")) and n_low:sub(1,1) == "@" then
        local key = n_low:sub(2)
        local slot = map[key]
        if slot and slot.cap then
          if insert_captured_at_time(slot, pos, patch_tr) then
            inserted = inserted + 1
            r.SetProjectMarker3(proj, markidx, false, pos, 0, n .. "_inserted", color or 0)
          end
        end
      end
    end
  end

  end_undo("34tools.edit: Insert all")

  if inserted > 0 then
    MP.set_status("Inserted: " .. inserted, false, 2.0)
  else
    MP.set_status("Nothing inserted", true, 4.0)
  end
end

function MP.get_state()
  local st = { slots = {} }
  for i, s in ipairs(MP.slots) do
    st.slots[i] = { name = s.name, has_cap = (s.cap ~= nil) }
  end
  return st
end

-- ============================================================================
-- UI
-- ============================================================================
local ctx = r.ImGui_CreateContext(CONFIG.WINDOW_TITLE)

local flags = 0
if r.ImGui_WindowFlags_NoResize then flags = flags | r.ImGui_WindowFlags_NoResize() end
if r.ImGui_WindowFlags_NoSavedSettings then flags = flags | r.ImGui_WindowFlags_NoSavedSettings() end
if r.ImGui_WindowFlags_NoDocking then flags = flags | r.ImGui_WindowFlags_NoDocking() end

local open = true
local show_help = false
local request_focus = false
local consume_next_frame = false

-- Startup refresh workaround (2 frames)
local _startup_refresh_count = 0
local function startup_refresh_once()
  if _startup_refresh_count >= 2 then return end
  _startup_refresh_count = _startup_refresh_count + 1
  r.TrackList_AdjustWindows(false)
  r.UpdateArrange()
  if r.UpdateTimeline then r.UpdateTimeline() end
end

-- Input buffers
local ui_name_buf = {}
local ui_inited = false

local function rebuild_bufs()
  local st = MP.get_state()
  ui_name_buf = {}
  for i, row in ipairs(st.slots) do
    ui_name_buf[i] = (row.name == CONFIG.EMPTY_NAME) and "" or tostring(row.name or "")
  end
  ui_inited = true
end

local function ensure_buf_size()
  for i = 1, #MP.slots do
    if ui_name_buf[i] == nil then ui_name_buf[i] = "" end
  end
end

local function calc_btn_w(label)
  if r.ImGui_CalcTextSize then
    local tw = select(1, r.ImGui_CalcTextSize(ctx, label))
    return math.floor(tw + 18)
  end
  return 100
end

local function calc_name_w_3chars()
  if r.ImGui_CalcTextSize then
    local tw = select(1, r.ImGui_CalcTextSize(ctx, "WWW"))
    return math.floor(tw + 16)
  end
  return 40
end

-- Draw status inline with FIXED width (no border). Returns (w,h).
local function draw_status_inline_fixed(w_fixed)
  local s, iserr = MP.get_status()

  local w = math.max(20, math.floor((w_fixed or 0) + 0.5))
  local h = CONFIG.STATUS_H

  local x0, y0 = r.ImGui_GetCursorScreenPos(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local x1 = x0 + w
  local y1 = y0 + h

  if r.ImGui_DrawList_AddRectFilled then
    r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x0F0F0FFF, 4)
  end

  if s ~= "" and r.ImGui_DrawList_AddText then
    local col = iserr and CONFIG.COLOR_ERR or CONFIG.COLOR_INFO
    r.ImGui_DrawList_AddText(dl, x0 + CONFIG.STATUS_PAD_X, y0 + CONFIG.STATUS_PAD_Y, col, s)
  end

  if r.ImGui_Dummy then r.ImGui_Dummy(ctx, w, h) end
  return w, h
end

local function draw_help_overlay_drawlist()
  if r.ImGui_Key_Escape and r.ImGui_IsKeyPressed then
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then
      show_help = false
      return
    end
  end

  if r.ImGui_IsMouseClicked and r.ImGui_IsMouseClicked(ctx, 0) then
    show_help = false
    request_focus = true
    consume_next_frame = true
    return
  end

  if not (r.ImGui_GetWindowPos and r.ImGui_GetWindowSize and r.ImGui_GetForegroundDrawList) then return end

  local wx, wy = r.ImGui_GetWindowPos(ctx)
  local ww, wh = r.ImGui_GetWindowSize(ctx)
  if ww <= 0 or wh <= 0 then return end

  local dl = r.ImGui_GetForegroundDrawList(ctx)
  if not dl then return end

  local glass    = 0x00000099
  local panel_bg = 0x1A1A1AFF
  local panel_bd = 0x2A2A2AFF
  local text_col = 0xFFFFFFFF
  local sub_col  = 0xB0B0B0FF

  r.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + wh, glass)

  local pw, ph = CONFIG.HELP_PANEL_W, CONFIG.HELP_PANEL_H
  local px = wx + math.max(10, math.floor((ww - pw) * 0.5))
  local py = wy + math.max(10, math.floor((wh - ph) * 0.5))
  local rounding = 8

  r.ImGui_DrawList_AddRectFilled(dl, px, py, px + pw, py + ph, panel_bg, rounding)
  r.ImGui_DrawList_AddRect(dl, px, py, px + pw, py + ph, panel_bd, rounding, 0, 1.0)

  local tx = px + 12
  local ty = py + 10
  local lh = 18

  local function add_text(x, y, col, t)
    r.ImGui_DrawList_AddText(dl, x, y, col, tostring(t))
  end

  add_text(tx, ty, text_col, CONFIG.HEADER_TITLE); ty = ty + lh + 6
  add_text(tx, ty, sub_col, "Capture: select exactly ONE audio item, then press Capture."); ty = ty + lh
  add_text(tx, ty, sub_col, "Insert to point: inserts at edit cursor on selected track."); ty = ty + lh
  add_text(tx, ty, sub_col, "Insert all: markers @<slot> in time selection -> PATCH."); ty = ty + lh
  add_text(tx, ty, sub_col, "Renames markers to ..._inserted, skips already inserted."); ty = ty + lh + 8
  add_text(tx, ty, sub_col, "Close help: click anywhere or press Esc."); ty = ty + lh
end

local function draw_header()
  r.ImGui_Text(ctx, CONFIG.HEADER_TITLE)
end

local function draw_ui()
  local st = MP.get_state()
  if not ui_inited then rebuild_bufs() end
  ensure_buf_size()

  local GAP_X = CONFIG.ROW_GAP_X

  draw_header()
  if r.ImGui_Dummy then r.ImGui_Dummy(ctx, 0, CONFIG.GAP_AFTER_HEADER) end
  r.ImGui_Separator(ctx)

  local NAME_W  = calc_name_w_3chars()
  local W_CAP   = calc_btn_w("Capture")
  local W_INS   = calc_btn_w("Insert to point")
  local W_RESET = calc_btn_w("Reset")
  local W_DEL   = CONFIG.SMALL_BTN_W

  local frame_h = r.ImGui_GetFrameHeight and r.ImGui_GetFrameHeight(ctx) or 22
  local rows = CONFIG.SLOTS_VISIBLE_ROWS
  local list_h = (rows * frame_h) + ((rows - 1) * CONFIG.ROW_SPACING_Y) + 8

  local delete_request = nil

  r.ImGui_BeginChild(ctx, "##MBCP_SLOTS", 0, list_h, (r.ImGui_ChildFlags_Border and r.ImGui_ChildFlags_Border() or 0))

  for i, row in ipairs(st.slots) do
    r.ImGui_PushID(ctx, i)

    local row_start_x = r.ImGui_GetCursorPosX(ctx)
    local row_avail_w = select(1, r.ImGui_GetContentRegionAvail(ctx))

    r.ImGui_SetNextItemWidth(ctx, NAME_W)
    local hint = CONFIG.EMPTY_NAME
    local changed, newtxt
    if r.ImGui_InputTextWithHint then
      changed, newtxt = r.ImGui_InputTextWithHint(ctx, "##name", hint, ui_name_buf[i] or "")
    else
      changed, newtxt = r.ImGui_InputText(ctx, "##name", ui_name_buf[i] or "")
    end

    if changed then
      ui_name_buf[i] = newtxt or ""
      MP.set_slot_name(i, ui_name_buf[i])
      local sn = MP.slots[i].name
      ui_name_buf[i] = (sn == CONFIG.EMPTY_NAME) and "" or sn
    end

    r.ImGui_SameLine(ctx, nil, GAP_X)
    if r.ImGui_Button(ctx, "Capture", W_CAP, 0) then
      begin_undo()
      MP.capture(i)
      end_undo("34tools.edit: Capture")
    end

    r.ImGui_SameLine(ctx, nil, GAP_X)
    if not row.has_cap then r.ImGui_BeginDisabled(ctx) end
    if r.ImGui_Button(ctx, "Insert to point", W_INS, 0) then MP.insert_to_point(i) end
    if not row.has_cap then r.ImGui_EndDisabled(ctx) end

    r.ImGui_SameLine(ctx, nil, GAP_X)
    if r.ImGui_Button(ctx, "Reset", W_RESET, 0) then
      MP.reset(i)
      ui_name_buf[i] = ""
    end

    if #MP.slots > 1 then
      local x_btn = row_start_x + math.max(0, row_avail_w - W_DEL)
      if r.ImGui_SameLine then r.ImGui_SameLine(ctx, nil, 0) end
      if r.ImGui_SetCursorPosX then r.ImGui_SetCursorPosX(ctx, x_btn) end
      if r.ImGui_Button(ctx, "X", W_DEL, 0) then
        delete_request = i
      end
    end

    r.ImGui_PopID(ctx)
    if r.ImGui_Dummy then r.ImGui_Dummy(ctx, 0, CONFIG.ROW_SPACING_Y) end
  end

  r.ImGui_EndChild(ctx)

  if delete_request then
    if MP.delete_slot(delete_request) then rebuild_bufs() end
  end

  if r.ImGui_Dummy then r.ImGui_Dummy(ctx, 0, CONFIG.GAP_BEFORE_FOOTER) end

  -- Footer row: status fixed-width (left) + buttons right aligned
  do
    local start_x = r.ImGui_GetCursorPosX(ctx)
    local avail_w = select(1, r.ImGui_GetContentRegionAvail(ctx))

    local w_add  = calc_btn_w("Add slot...")
    local w_all  = calc_btn_w("Insert all")
    local w_help = CONFIG.SMALL_BTN_W
    local gap = CONFIG.FOOTER_GAP
    local total_btn_w = w_add + gap + w_all + gap + w_help

    local buttons_x = start_x + math.max(0, avail_w - total_btn_w)

    local status_w = math.max(0, (buttons_x - start_x) - gap)
    draw_status_inline_fixed(status_w)

    if r.ImGui_SameLine then r.ImGui_SameLine(ctx, nil, 0) end
    if r.ImGui_SetCursorPosX then r.ImGui_SetCursorPosX(ctx, buttons_x) end

    if r.ImGui_Button(ctx, "Add slot...", w_add, 0) then
      local idx = MP.add_slot()
      ui_name_buf[idx] = ""
    end

    r.ImGui_SameLine(ctx, nil, gap)

    if r.ImGui_Button(ctx, "Insert all", w_all, 0) then
      MP.insert_all()
    end

    r.ImGui_SameLine(ctx, nil, gap)

    if r.ImGui_Button(ctx, "?", w_help, 0) then
      show_help = not show_help
      request_focus = true
    end
  end
end

local function compute_window_h()
  local frame_h = r.ImGui_GetFrameHeight and r.ImGui_GetFrameHeight(ctx) or 22
  local rows = CONFIG.SLOTS_VISIBLE_ROWS
  local list_h = (rows * frame_h) + ((rows - 1) * CONFIG.ROW_SPACING_Y) + 8

  local header_h = (r.ImGui_GetTextLineHeightWithSpacing and r.ImGui_GetTextLineHeightWithSpacing(ctx) or 22) + 6
  local sep = 8
  local footer_row = math.max(frame_h, CONFIG.STATUS_H) + 6

  local total =
    header_h +
    CONFIG.GAP_AFTER_HEADER + sep +
    list_h +
    CONFIG.GAP_BEFORE_FOOTER +
    footer_row +
    CONFIG.GAP_AFTER_FOOTER +
    10

  total = total + CONFIG.EXTRA_BOTTOM_PX
  total = total + 6 -- small safety
  return math.floor(total + 0.5)
end

local function loop()
  startup_refresh_once()
  if not open then return end

  if request_focus and r.ImGui_SetNextWindowFocus then
    r.ImGui_SetNextWindowFocus(ctx)
    request_focus = false
  end

  local win_h = compute_window_h()
  if r.ImGui_SetNextWindowSize and r.ImGui_Cond_Always then
    r.ImGui_SetNextWindowSize(ctx, CONFIG.WIN_W, win_h, r.ImGui_Cond_Always())
  end

  local visible
  visible, open = r.ImGui_Begin(ctx, CONFIG.WINDOW_TITLE, open, flags)
  if visible then
    if consume_next_frame then
      r.ImGui_BeginDisabled(ctx)
      draw_ui()
      r.ImGui_EndDisabled(ctx)
      consume_next_frame = false
    else
      draw_ui()
    end

    if show_help then
      draw_help_overlay_drawlist()
    end
  end
  r.ImGui_End(ctx)

  r.defer(loop)
end

loop()

