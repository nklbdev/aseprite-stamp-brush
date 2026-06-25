-- Clone Stamp Extension for Aseprite
-- dlg:canvas approach: custom tiled canvas with pan/zoom and overlay indicators.
-- Precomputed brush mask (smoothstep), stamp interpolation, max-alpha accumulator.
-- workImg = sprite canvas sized; cel is drawn onto it at its position.
-- snapshot = cel.image (source sampling and tiling).
-- State stored in module-level local variables; dlg=nil means data is disposed.
--
-- API: Aseprite >= 1.3
--
-- Feature request: soft brush painting mode (non-stamp).
-- Would need color picker, palette, and input flow redesign.

local TILED_X, TILED_Y, TILED_BOTH = 1, 2, 3

-- =========================================================================
-- Module-level state variables
-- dlg == nil  ->  all important data disposed
-- dlg ~= nil  ->  dialog is open, data is alive
-- =========================================================================
local dlg = nil

-- Brush parameters
local radius, softness, opacity, spacing = 16, 0.5, 1.0, 0.25

-- Editing state
local workImg, sourcePoint, offset = nil, nil, nil  -- workImg = canvas-sized
local undoStack, undoPos = nil, 0
local snapshot = nil          -- cel.image (source sampling)
local tiledMode = TILED_BOTH  -- affects source wrapping only
local celX, celY = 0, 0       -- cel position on canvas (fixed during session)
local celColorMode = nil      -- ColorMode of cel.image (for applyToCel)

-- Brush mask cache
local brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1

-- Accumulator (per stroke)
local alphaAcc, colorAcc = nil, nil
local dirtyX1, dirtyY1, dirtyX2, dirtyY2 = 0, 0, -1, -1

-- Selection mask (255 = selected, 0 = not)
local selMask = nil
local selBounds = nil  -- Rectangle bounds of selection for overlay
local selEdgeImg = nil  -- precomputed selection edge bitmask

-- Marker (now drawn via paths, no cache needed)

-- =========================================================================
-- Helpers: dispose / init
-- =========================================================================
local function disposeState()
	workImg, sourcePoint, offset = nil, nil, nil
	undoStack, undoPos = nil, 0
	snapshot = nil
	celX, celY = 0, 0
	celColorMode = nil
		brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
		alphaAcc, colorAcc = nil, nil
		dirtyX1, dirtyY1, dirtyX2, dirtyY2 = 0, 0, -1, -1
	selMask, selBounds, selEdgeImg = nil, nil, nil
end

local function initState(prefs)
	if not app.activeCel then return false end
	local sprite = app.activeSprite
	if not sprite then return false end
	local activeCel = app.activeCel

	radius   = prefs.radius or 16
	softness = prefs.softness or 0.5
	opacity  = prefs.opacity or 1.0
	spacing  = 0.25

	-- Capture cel position (fixed during session)
	celX, celY = activeCel.position.x, activeCel.position.y
	celColorMode = activeCel.image.colorMode

	-- workImg = sprite-sized canvas (in cel's color mode)
	workImg = Image(sprite.width, sprite.height, celColorMode)
	workImg:clear()
	workImg:drawImage(activeCel.image, activeCel.position)

	-- snapshot = cel.image (clone source, tiling wraps on this)
	snapshot = Image(activeCel.image)

	sourcePoint, offset = nil, nil
	undoStack, undoPos = {}, 0
	undoStack[0] = Image(workImg)
	tiledMode = TILED_BOTH
	brushMask, brushMaskR, brushMaskS, brushMaskO = nil, -1, -1, -1
	alphaAcc, colorAcc = nil, nil
		dirtyX1, dirtyY1, dirtyX2, dirtyY2 = 0, 0, -1, -1

	-- Selection mask
	selMask = nil
	selBounds = nil
	selEdgeImg = nil
	local sel = sprite.selection
	if sel and not sel.isEmpty then
		selMask = Image(sprite.width, sprite.height, ColorMode.GRAYSCALE)
		selMask:clear()
		selBounds = sel.bounds
		local b = selBounds
		for y = b.y, math.min(b.y + b.height - 1, sprite.height - 1) do
			for x = b.x, math.min(b.x + b.width - 1, sprite.width - 1) do
				if sel:contains(x, y) then selMask:drawPixel(x, y, 255) end
			end
		end
		-- Build selection edge bitmask (1=top, 2=right, 4=bottom, 8=left)
		selEdgeImg = Image(sprite.width, sprite.height, ColorMode.GRAYSCALE)
		selEdgeImg:clear()
		for y = b.y, math.min(b.y + b.height - 1, sprite.height - 1) do
			for x = b.x, math.min(b.x + b.width - 1, sprite.width - 1) do
				if selMask:getPixel(x, y) ~= 0 then
					local mask = 0
					if y == 0 or selMask:getPixel(x, y - 1) == 0 then mask = mask + 1 end
					if x == sprite.width - 1 or selMask:getPixel(x + 1, y) == 0 then mask = mask + 2 end
					if y == sprite.height - 1 or selMask:getPixel(x, y + 1) == 0 then mask = mask + 4 end
					if x == 0 or selMask:getPixel(x - 1, y) == 0 then mask = mask + 8 end
					if mask ~= 0 then selEdgeImg:drawPixel(x, y, mask) end
				end
			end
		end
	end

	return true
end

local function savePrefs(prefs)
	prefs.radius   = radius
	prefs.softness = softness
	prefs.opacity  = opacity
end

-- =========================================================================
-- Apply helper: merge dirty region from workImg into cel
-- =========================================================================
local function applyToCel()
	local activeCel = app.activeCel
	if not activeCel then return end

	-- No dirty/overlap with cel -- nothing to apply
	if dirtyX1 > dirtyX2 or dirtyY1 > dirtyY2 then return end
	local cw, ch = snapshot.width, snapshot.height
	if dirtyX2 < celX or dirtyX1 > celX + cw or
	   dirtyY2 < celY or dirtyY1 > celY + ch then return end

	-- Check if cel needs to expand
	local needLeft  = math.min(0, dirtyX1 - celX)
	local needTop   = math.min(0, dirtyY1 - celY)
	local needRight = math.max(activeCel.image.width  - 1, dirtyX2 - celX)
	local needBot   = math.max(activeCel.image.height - 1, dirtyY2 - celY)

	local newW = needRight - needLeft + 1
	local newH = needBot - needTop + 1
	local offX = -needLeft
	local offY = -needTop

	if newW ~= activeCel.image.width or newH ~= activeCel.image.height then
		-- Expand cel.image (new Image, drawImage old, drawImage dirty)
		local newCelImg = Image(newW, newH, celColorMode)
		newCelImg:clear()
		newCelImg:drawImage(activeCel.image, Point(offX, offY))
		-- Copy dirty region from workImg into cel (drawImage handles color conversion)
		newCelImg:drawImage(workImg, Point(offX - celX, offY - celY))
		activeCel.image = newCelImg
		activeCel.position = Point(celX - offX, celY - offY)
	else
		-- No expansion: drawImage copies the intersection
		activeCel.image:drawImage(workImg, Point(-celX, -celY))
	end
end

----------------------------------------------------------------------
-- Brush mask (smoothstep)
----------------------------------------------------------------------
local function smoothstep(t)
	local t2 = t * t
	return 3 * t2 - 2 * t2 * t
end

local function ensureBrushMask()
	if brushMaskR == radius and brushMaskS == softness and brushMaskO == opacity then return end
	brushMaskR, brushMaskS, brushMaskO = radius, softness, opacity
	local size = radius * 2 + 1
	brushMask = Image(size, size, ColorMode.GRAYSCALE)
	local inner = radius * (1.0 - softness)
	for dy = -radius, radius do for dx = -radius, radius do
		local dist = math.sqrt(dx*dx + dy*dy)
		local v = 0.0
		if dist < radius then
			if softness <= 0 or dist <= inner then v = 1.0
			else v = 1.0 - smoothstep((dist - inner) / (radius - inner)) end
		end
		brushMask:drawPixel(dx + radius, dy + radius, math.floor(v * opacity * 255 + 0.5))
	end end
end

----------------------------------------------------------------------
-- Accumulator
----------------------------------------------------------------------
local function beginAccum()
	alphaAcc = Image(workImg.width, workImg.height, ColorMode.GRAYSCALE)
	colorAcc = Image(workImg.width, workImg.height, workImg.colorMode)
	dirtyX1, dirtyY1 = workImg.width, workImg.height
	dirtyX2, dirtyY2 = -1, -1
end

local function flushAccumTo(dstImg)
	if not alphaAcc or dirtyX1 > dirtyX2 or dirtyY1 > dirtyY2 then return end
	local mode = dstImg.colorMode
	for y = dirtyY1, dirtyY2 do for x = dirtyX1, dirtyX2 do
		local maskVal = alphaAcc:getPixel(x, y)
		if maskVal ~= 0 then
			local srcPx = colorAcc:getPixel(x, y)
			if srcPx == 0 then goto fcont end
			local a = maskVal / 255.0
			local dstPx = dstImg:getPixel(x, y)
			if mode == ColorMode.RGB then
				local sr, sg, sb, sa = app.pixelColor.rgbaR(srcPx), app.pixelColor.rgbaG(srcPx),
				                       app.pixelColor.rgbaB(srcPx), app.pixelColor.rgbaA(srcPx)
				local dr, dg, db, da = app.pixelColor.rgbaR(dstPx), app.pixelColor.rgbaG(dstPx),
				                       app.pixelColor.rgbaB(dstPx), app.pixelColor.rgbaA(dstPx)
				dstImg:drawPixel(x, y, app.pixelColor.rgba(
					math.floor(sr*a + dr*(1-a) + 0.5), math.floor(sg*a + dg*(1-a) + 0.5),
					math.floor(sb*a + db*(1-a) + 0.5), math.floor(sa*a + da*(1-a) + 0.5)))
			else if a > 0.5 then dstImg:drawPixel(x, y, srcPx) end end
		end ::fcont::
	end end
end

----------------------------------------------------------------------
-- Source sampling (tiling on snapshot = cel.image)
----------------------------------------------------------------------
local function isTiledX() return tiledMode == TILED_X or tiledMode == TILED_BOTH end
local function isTiledY() return tiledMode == TILED_Y or tiledMode == TILED_BOTH end

local function sampleSource(tx, ty, offX, offY)
	-- source coordinates in cel-local space, with tiledMode wrapping
	local sx = tx - offX - celX
	local sy = ty - offY - celY
	if isTiledX() then sx = sx % snapshot.width
	elseif sx < 0 or sx >= snapshot.width then return 0 end
	if isTiledY() then sy = sy % snapshot.height
	elseif sy < 0 or sy >= snapshot.height then return 0 end
	return snapshot:getPixel(sx, sy)
end

local function stampWithMask(cx, cy, offX, offY)
	local w, h, r = workImg.width, workImg.height, brushMaskR
	for my = 0, brushMask.height - 1 do for mx = 0, brushMask.width - 1 do
		local mv = brushMask:getPixel(mx, my)
		if mv == 0 then goto mcont end
		local tx = (cx + mx - r) % w
		local ty = (cy + my - r) % h
				local cur = alphaAcc:getPixel(tx, ty)
				if cur >= mv then goto mcont end
				-- Selection mask check
				if selMask and selMask:getPixel(tx, ty) == 0 then goto mcont end
				alphaAcc:drawPixel(tx, ty, mv)
		colorAcc:drawPixel(tx, ty, sampleSource(tx, ty, offX, offY))
		if tx < dirtyX1 then dirtyX1 = tx end
		if ty < dirtyY1 then dirtyY1 = ty end
		if tx > dirtyX2 then dirtyX2 = tx end
		if ty > dirtyY2 then dirtyY2 = ty end
		::mcont::
	end end
end

local function stampSegment(x1, y1, x2, y2, offX, offY)
	local step = math.max(1, math.floor(brushMaskR * spacing))
	local dx, dy = x2 - x1, y2 - y1
	local dist = math.sqrt(dx*dx + dy*dy)
	if dist < step then
		stampWithMask(x2, y2, offX, offY)
		return
	end
	for i = 1, math.floor(dist / step) do
		local t = i / math.floor(dist / step)
		stampWithMask(math.floor(x1 + dx*t + 0.5), math.floor(y1 + dy*t + 0.5), offX, offY)
	end
	end

----------------------------------------------------------------------
-- Dialog
----------------------------------------------------------------------
local function drawMarker(gc, csx, csy, r)
		gc:beginPath()
		gc:oval(Rectangle(csx - r, csy - r, r * 2, r * 2))
		gc:moveTo(csx - 4, csy)
		gc:lineTo(csx + 4, csy)
		gc:moveTo(csx, csy - 4)
		gc:lineTo(csx, csy + 4)
		gc:stroke()
	end

local function stampBrushDialog(prefs)
	if not workImg then
		if not initState(prefs) then
			app.alert("No active cel!")
			return
		end
	end

	dlg = Dialog{ title = "Clone Stamp", notitlebar = false, resizeable = true,
		onclose = function()
			if undoPos > 0 then
				local r = app.alert{ title = "Apply changes?",
					text = tostring(undoPos) .. " stroke(s) made.",
					buttons = { "Apply", "Discard", "Continue Editing" } }
				if r == 1 then
					app.transaction(function()
						applyToCel()
					end)
					app.refresh()
					disposeState()
				elseif r == 2 then
					disposeState()
				elseif r == 3 then
					-- Keep state, reopen dialog
					alphaAcc, colorAcc = nil, nil
					stampBrushDialog(prefs)
				end
			else
				disposeState()
			end
		end}

	-- Reset only accumulator (dirty bounds live until Apply/Discard)
	alphaAcc, colorAcc = nil, nil

	local isDrawing = false
	local mouseX, mouseY = -1, -1
	local lastWX, lastWY, previewImg = nil, nil, nil
	local stampPreview, stampPWX, stampPWY = nil, -1, -1
	local vScale, vOffX, vOffY = 1.0, 0.0, 0.0
	local isPanning, panSX, panSY, panOX, panOY = false, 0, 0, 0, 0
	local centered = false

	local function updateStampPreview(wx, wy, offX, offY)
		if offX == nil or offY == nil then
			stampPreview = nil
			return
		end
		ensureBrushMask()
		local r = radius
		stampPreview = Image(r*2+1, r*2+1, ColorMode.RGB)
		local isRgb = (workImg.colorMode == ColorMode.RGB)
		for dy = -r, r do for dx = -r, r do
			local mv = brushMask:getPixel(dx + r, dy + r)
			if mv == 0 then goto pskip end
			local spx = sampleSource(wx + dx, wy + dy, offX, offY)
			if spx ~= 0 then
				if isRgb then
					local a = math.floor(app.pixelColor.rgbaA(spx) * mv / 255)
					stampPreview:drawPixel(dx + r, dy + r, app.pixelColor.rgba(
						app.pixelColor.rgbaR(spx), app.pixelColor.rgbaG(spx),
						app.pixelColor.rgbaB(spx), a))
				else
					local a = math.floor(200 * mv / 255)
					stampPreview:drawPixel(dx + r, dy + r, app.pixelColor.rgba(255, 255, 255, a))
				end
			end ::pskip::
		end end
		stampPWX, stampPWY = wx, wy
	end

	local function updatePreview()
		stampPreview = nil
		if not alphaAcc then return end
		if not previewImg or previewImg.width ~= workImg.width or previewImg.height ~= workImg.height then
			previewImg = Image(workImg)
		else
			previewImg:drawImage(workImg, Point(0, 0))
		end
		flushAccumTo(previewImg)
	end

	local function toWork(x, y)
		return math.floor((x - vOffX) / vScale),
		       math.floor((y - vOffY) / vScale)
	end

	local function toCanvas(wx, wy)
		return math.floor(wx*vScale + vOffX + vScale/2 + 0.5),
		       math.floor(wy*vScale + vOffY + vScale/2 + 0.5)
	end

	local function toCanvasCorner(wx, wy)
		return math.floor(wx*vScale + vOffX + 0.5), math.floor(wy*vScale + vOffY + 0.5)
	end

	local function pushUndo()
		undoPos = undoPos + 1
		for i = undoPos, #undoStack do undoStack[i] = nil end
		undoStack[undoPos] = Image(workImg)
	end

	local function undo()
		if undoPos <= 0 then return end
		undoPos = undoPos - 1
		workImg = Image(undoStack[undoPos])
		snapshot = Image(workImg)
		dlg:repaint()
	end

	local function redo()
		if undoPos >= #undoStack then return end
		undoPos = undoPos + 1
		workImg = Image(undoStack[undoPos])
		snapshot = Image(workImg)
		dlg:repaint()
	end

	local function refreshPreview()
		if sourcePoint and not isDrawing and mouseX >= 0 then
			local wx, wy = toWork(mouseX, mouseY)
			updateStampPreview(wx, wy,
				(offset and offset.x) or (wx - sourcePoint.x),
				(offset and offset.y) or (wy - sourcePoint.y))
		end
		dlg:repaint()
	end

	dlg
		:newrow{ always = false }
		:label { text = "Tiled Mode" }
		:label { text = "Radius" }
		:label { text = "Opacity" }
		:label { text = "Softness" }
		:slider { id="tiled", min=0, max=3, value=tiledMode,
			onchange = function()
				local function tileCenter(mode)
					local cx = (mode == TILED_X or mode == TILED_BOTH) and 1 or 0
					local cy = (mode == TILED_Y or mode == TILED_BOTH) and 1 or 0
					return cx, cy
				end
				local oldCX, oldCY = tileCenter(tiledMode)
				tiledMode = dlg.data.tiled
				local newCX, newCY = tileCenter(tiledMode)
				vOffX = vOffX + (oldCX - newCX) * workImg.width * vScale
				vOffY = vOffY + (oldCY - newCY) * workImg.height * vScale
				refreshPreview() end }
		:slider { id="radius", min=1, max=64, value=radius,
			onchange = function()
				radius = dlg.data.radius
				savePrefs(prefs)
				refreshPreview() end }
		:slider { id="opacity", min=0, max=100, value=math.floor(opacity*100),
			onchange = function()
				opacity = dlg.data.opacity / 100
				savePrefs(prefs)
				refreshPreview() end }
		:slider { id="softness", min=0, max=100, value=math.floor(softness*100),
			onchange = function()
				softness = dlg.data.softness / 100
				savePrefs(prefs)
				refreshPreview() end }
		:newrow { always = false }
				:canvas{ id="canvas", autoscaling=false, focus=true,
				onpaint = function(ev)
					local gc = ev.context
			if not centered then
				centered = true
				local cx = (tiledMode == TILED_X or tiledMode == TILED_BOTH) and 3 or 1
				local cy = (tiledMode == TILED_Y or tiledMode == TILED_BOTH) and 3 or 1
				local fitW = gc.width / (workImg.width * cx)
				local fitH = gc.height / (workImg.height * cy)
				local fit = math.min(fitW, fitH)
				-- Largest power of two fitting the available area
				vScale = 0.5
				while vScale * 2 <= fit and vScale < 32 do vScale = vScale * 2 end
				vOffX = (gc.width - workImg.width * cx * vScale) / 2
				vOffY = (gc.height - workImg.height * cy * vScale) / 2
			end
					if isDrawing then stampPreview = nil end
			local s, ox, oy = vScale, vOffX, vOffY
			local src = previewImg or workImg
			local wImg, hImg = src.width, src.height

			-- workImg / previewImg -- tiling according to tiledMode
			local countX = (tiledMode == TILED_X or tiledMode == TILED_BOTH) and 3 or 1
			local countY = (tiledMode == TILED_Y or tiledMode == TILED_BOTH) and 3 or 1
			for ty = 0, countY - 1 do for tx = 0, countX - 1 do
				gc:drawImage(src, 0, 0, wImg, hImg,
					math.floor((tx * wImg) * s + ox + 0.5),
					math.floor((ty * hImg) * s + oy + 0.5),
					math.floor(wImg * s + 0.5),
					math.floor(hImg * s + 0.5))
			end end

					-- Tile boundary lines (DIFFERENCE blend -- always visible)
					if countX > 1 or countY > 1 then
						gc:save()
						gc.blendMode = BlendMode.DIFFERENCE
						gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
						gc.strokeWidth = 1
						for tx = 1, countX - 1 do
							local lx = math.floor(tx * wImg * s + ox + 0.5)
							gc:beginPath()
							gc:moveTo(lx, math.floor(oy))
							gc:lineTo(lx, math.floor(countY * hImg * s + oy))
							gc:stroke()
						end
						for ty = 1, countY - 1 do
							local ly = math.floor(ty * hImg * s + oy + 0.5)
							gc:beginPath()
							gc:moveTo(math.floor(ox), ly)
							gc:lineTo(math.floor(countX * wImg * s + ox), ly)
							gc:stroke()
						end
						gc:restore()
					end

			-- Over tiles: stamp preview + markers
			if mouseX >= 0 and sourcePoint then
				local wx, wy = toWork(mouseX, mouseY)
				-- Wrapped coordinates (where the brush actually paints)
				local wwx = wx % wImg
				local wwy = wy % hImg
				-- Stamp preview (when not drawing)
				if not isDrawing and stampPreview then
					local dstW = math.floor(stampPreview.width * s + 0.5)
					local dstH = math.floor(stampPreview.height * s + 0.5)
					for ty = 0, countY - 1 do for tx = 0, countX - 1 do
						local csx, csy = toCanvasCorner(tx * wImg + wwx - radius, ty * hImg + wwy - radius)
						gc:drawImage(stampPreview,
							0, 0, stampPreview.width, stampPreview.height,
							csx, csy, dstW, dstH)
					end end
				end
			-- Green marker (target) -- on all tiles
			gc:save()
			gc.blendMode = BlendMode.DIFFERENCE
			gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
			for ty = 0, countY - 1 do for tx = 0, countX - 1 do
				local csx, csy = toCanvas(tx * wImg + wwx, ty * hImg + wwy)
				drawMarker(gc, csx, csy, radius * vScale)
			end end
			gc:restore()
			-- Yellow marker (source) -- on all tiles
			local sx = offset and (wx - offset.x) or sourcePoint.x
			local sy = offset and (wy - offset.y) or sourcePoint.y
			local wsx = sx % wImg
			local wsy = sy % hImg
			gc:save()
			gc.blendMode = BlendMode.DIFFERENCE
			gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
			for ty = 0, countY - 1 do for tx = 0, countX - 1 do
				local scsx, scsy = toCanvas(tx * wImg + wsx, ty * hImg + wsy)
				drawMarker(gc, scsx, scsy, radius * vScale)
			end end
			gc:restore()
							end

			-- Selection overlay (paths + DIFFERENCE blend, on top, on all tiles)
			if selEdgeImg then
				gc:save()
				gc.blendMode = BlendMode.DIFFERENCE
				gc.color = Color{ red=255, green=255, blue=255, alpha=255 }
				gc.strokeWidth = 1
				for ty = 0, countY - 1 do for tx = 0, countX - 1 do
					local bx = tx * wImg
					local by = ty * hImg
					local vx1 = math.max(0, math.floor((-ox) / s) - bx)
					local vy1 = math.max(0, math.floor((-oy) / s) - by)
					local vx2 = math.min(wImg - 1, math.floor((gc.width - ox) / s) - bx)
					local vy2 = math.min(hImg - 1, math.floor((gc.height - oy) / s) - by)
					gc:beginPath()
					for y = vy1, vy2 do for x = vx1, vx2 do
						local mask = selEdgeImg:getPixel(x, y)
						if mask ~= 0 then
							local cx = math.floor((bx + x) * s + ox + 0.5)
							local cy = math.floor((by + y) * s + oy + 0.5)
							local cw = math.max(1, math.floor(s + 0.5))
							-- top
							if mask % 2 == 1 then
								gc:moveTo(cx, cy)
								gc:lineTo(cx + cw, cy)
							end
							-- right
							if math.floor(mask / 2) % 2 == 1 then
								gc:moveTo(cx + cw, cy)
								gc:lineTo(cx + cw, cy + cw)
							end
							-- bottom
							if math.floor(mask / 4) % 2 == 1 then
								gc:moveTo(cx, cy + cw)
								gc:lineTo(cx + cw, cy + cw)
							end
							-- left
							if mask >= 8 then
								gc:moveTo(cx, cy)
								gc:lineTo(cx, cy + cw)
							end
						end
					end end
					gc:stroke()
				end end
				gc:restore()
			end
						end,
		onwheel = function(ev)
			-- Note: if using Linear Mouse app on macOS to normalize mouse behavior,
			-- configure it with: Scrolling Mode: By Pixels,
			-- all Modifier Keys set to Default Action
			if ev.deltaY == 0 then return end  -- trackpad / Shift+scroll (intercepted by Aseprite)
			if ev.shiftKey then
				radius = math.max(1, math.min(64, radius - ev.deltaY))
				dlg:modify{ id="radius", value=radius }
				savePrefs(prefs)
				refreshPreview()
				dlg:repaint()
				return
			end
			local mx, my = ev.x, ev.y
			local ns = vScale * (ev.deltaY < 0 and 2 or 0.5)
			ns = math.max(0.5, math.min(32, ns))
			vOffX = mx - (mx - vOffX) * (ns / vScale)
			vOffY = my - (my - vOffY) * (ns / vScale)
			vScale, mouseX, mouseY = ns, mx, my
			dlg:repaint()
		end,
		onmousedown = function(ev)
			mouseX, mouseY = ev.x, ev.y
			if ev.button == MouseButton.MIDDLE then
				isPanning, panSX, panSY, panOX, panOY = true, ev.x, ev.y, vOffX, vOffY
				return
			end
			local wx, wy = toWork(ev.x, ev.y)
			if ev.button == MouseButton.RIGHT then
				if isDrawing then
					alphaAcc, colorAcc, previewImg, stampPreview = nil, nil, nil, nil
					isDrawing = false
					dlg:repaint()
					return
				end
				sourcePoint, offset, stampPreview = Point(wx, wy), nil, nil
				snapshot = Image(workImg)
				dlg:repaint()
				return
			end
			if not sourcePoint then
				sourcePoint, offset, stampPreview = Point(wx, wy), nil, nil
				snapshot = Image(workImg)
				dlg:repaint()
				return
			end
			isDrawing, lastWX, lastWY, stampPreview = true, wx, wy, nil
			alphaAcc, colorAcc = nil, nil
			if not offset then offset = Point(wx - sourcePoint.x, wy - sourcePoint.y) end
			ensureBrushMask()
			beginAccum()
			stampWithMask(wx, wy, offset.x, offset.y)
			updatePreview()
			dlg:repaint()
		end,
		onmousemove = function(ev)
			mouseX, mouseY = ev.x, ev.y
			if isPanning then
				vOffX = panOX + (ev.x - panSX)
				vOffY = panOY + (ev.y - panSY)
				dlg:repaint()
				return
			end
			if isDrawing and offset then
				local wx, wy = toWork(ev.x, ev.y)
				if lastWX then stampSegment(lastWX, lastWY, wx, wy, offset.x, offset.y) end
				lastWX, lastWY = wx, wy
				updatePreview()
			elseif sourcePoint and snapshot and not isDrawing then
				local wx, wy = toWork(ev.x, ev.y)
				if wx ~= stampPWX or wy ~= stampPWY then
					updateStampPreview(wx, wy,
						(offset and offset.x) or (wx - sourcePoint.x),
						(offset and offset.y) or (wy - sourcePoint.y))
				end
			end
			dlg:repaint()
		end,
		onmouseup = function(ev)
			if isPanning then
				isPanning = false
				return
			end
			if isDrawing then
				flushAccumTo(workImg)
				pushUndo()
				snapshot = Image(workImg)
				alphaAcc, colorAcc, previewImg, stampPreview = nil, nil, nil, nil
				dlg:repaint()
			end
			isDrawing = false
		end,
		onkeydown = function(ev)
			if ev.repeatCount > 0 then return end
			if (ev.metaKey or ev.ctrlKey) and ev.code == "KeyZ" then
				ev:stopPropagation()
				if ev.shiftKey then redo() else undo() end
			elseif (ev.metaKey or ev.ctrlKey) and ev.code == "KeyY" then
				ev:stopPropagation()
				redo()
			end
		end }
		:show { wait = true, bounds = Rectangle(0, 0, app.window.width, app.window.height) }
end

----------------------------------------------------------------------
-- Plugin
----------------------------------------------------------------------
function init(plugin)
	local prefs = plugin.preferences
	if prefs.radius   == nil then prefs.radius   = 16   end
	if prefs.softness == nil then prefs.softness = 0.5  end
	if prefs.spacing  == nil then prefs.spacing  = 0.25 end
	if prefs.opacity  == nil then prefs.opacity  = 1.0  end
	plugin:newCommand{ id="StampBrush_Clone", title="Clone Stamp", group="edit_fill",
		onclick   = function() stampBrushDialog(prefs) end,
		onenabled = function() return app.activeSprite ~= nil and app.activeCel ~= nil end }
end

function exit(plugin)
	savePrefs(plugin.preferences)
	disposeState()
	dlg = nil
end
