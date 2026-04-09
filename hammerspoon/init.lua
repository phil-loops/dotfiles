-- Vim Sticky Notes
-- Toggle with Cmd+Alt+Ctrl+V

local sheet = nil

local notes = {
  {
    title = "Folds",
    body = [==[
zf{motion}  create fold
zo          open fold
zc          close fold
za          toggle fold
zR          open ALL folds
zM          close ALL folds
zd          delete fold
zj / zk     next / prev fold
]==]
  },
  {
    title = "Registers",
    body = [==[
"ay         yank into reg a
"ap         paste from reg a
:reg        show all registers
""          default (last d/y/c)
"0          last yank
"1-"9       last deletes (stack)
"+          system clipboard
"*          selection clipboard
"_          black hole (discard)
".          last inserted text
":          last command
"/          last search
]==]
  },
}

local function buildText()
  local lines = {}
  for _, note in ipairs(notes) do
    table.insert(lines, "━━ " .. note.title .. " ━━")
    table.insert(lines, note.body)
  end
  return table.concat(lines, "\n")
end

function toggleSheet()
  if sheet then
    sheet:delete()
    sheet = nil
    return
  end

  local screen = hs.screen.mainScreen():frame()
  local w, h = 300, 480
  local x = screen.x + screen.w - w - 20
  local y = screen.y + 40

  sheet = hs.canvas.new({ x = x, y = y, w = w, h = h })
  sheet:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  sheet:level(hs.canvas.windowLevels.floating)

  -- sticky note background
  sheet:appendElements({
    type = "rectangle",
    fillColor = { red = 1, green = 0.95, blue = 0.7, alpha = 0.95 },
    strokeColor = { red = 0.85, green = 0.8, blue = 0.55, alpha = 1 },
    strokeWidth = 1,
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
  })

  -- header bar
  sheet:appendElements({
    type = "rectangle",
    frame = { x = 0, y = 0, w = "100%", h = 28 },
    fillColor = { red = 0.95, green = 0.88, blue = 0.55, alpha = 1 },
    roundedRectRadii = { xRadius = 8, yRadius = 8 },
  })

  -- title
  sheet:appendElements({
    type = "text",
    text = hs.styledtext.new("  Vim Cheat Sheet  ⌘⌥⌃V to dismiss", {
      font = { name = "Menlo", size = 10 },
      color = { red = 0.4, green = 0.35, blue = 0.2 },
    }),
    frame = { x = "2%", y = 6, w = "96%", h = 20 },
  })

  -- content
  sheet:appendElements({
    type = "text",
    text = hs.styledtext.new(buildText(), {
      font = { name = "Menlo", size = 12 },
      color = { red = 0.1, green = 0.1, blue = 0.1 },
      paragraphStyle = { lineSpacing = 2 },
    }),
    frame = { x = "4%", y = 34, w = "92%", h = "88%" },
  })

  sheet:show()
end

hs.hotkey.bind({"cmd", "alt", "ctrl"}, "v", toggleSheet)

hs.alert.show("Hammerspoon loaded — ⌘⌥⌃V for Vim sticky note")
