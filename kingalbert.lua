#!/usr/local/bin/lua53

local lgi = require 'lgi'
local Gtk = lgi.Gtk
local Goo = lgi.GooCanvas
local GLib = lgi.GLib

local Cards = require 'cards'

local anim_time = 150
local anim_step = 17

local position

-- event management and coroutine stuff.

local GuardMethods = {}
local GuardMeta = { __index = GuardMethods }
local guard = setmetatable({ count = 0 }, GuardMeta)

function GuardMethods:inc()
    self.count = self.count + 1
end

function GuardMethods:dec()
    self.count = self.count - 1
end

function GuardMeta:__call(fn,...)
    if self.count == 0 then
	return fn(...)
    end
end

-- if the coroutine returned a function value, then call it
-- to schedule the next run. if it died, update the guard.

local function cocont(co,ok,val,...)
    if val and type(val) == "function" then
	val(...)
    end
    if coroutine.status(co) == "dead" then
	guard:dec()
    end
end
local function cowrap(co,...)
    cocont(co,assert(coroutine.resume(co,...)))
end

-- update() yields and reschedules as an idle task.

local function update_cont(co)
    GLib.idle_add(GLib.PRIORITY_DEFAULT, function() cowrap(co) end)
end

local function update()
    local co,f = coroutine.running()
    if f then return end
    coroutine.yield(update_cont, co)
end

-- pause(n) yields and reschedules after the timeout in ms.

local function pause_cont(co,t)
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, t, function() cowrap(co) end)
end

local function pause(t)
    local co,f = coroutine.running()
    if f then return end
    coroutine.yield(pause_cont, co, t)
end

-- cobegin starts a coroutine and resumes it immediately; codefer
-- starts a coroutine but immediately reschedules it as an idle task.

local function cobegin(func,...)
    guard:inc()
    cowrap(coroutine.create(func),...)
end
local function codefer(func,...)
    guard:inc()
    cowrap(coroutine.create(function(...) update() func(...) end),...)
end

-- basic card moves

local function in_sequence(a,b)
    return a:value() == b:value() + 1
	and a:colour() ~= b:colour()
end

local function longest_sequence_len(depot)
    local cards = depot:cardlist()
    local ncards = #cards
    local pos = ncards
    if ncards == 0 then
	return 0
    end
    while pos > 1 do
	if not in_sequence(cards[pos-1],cards[pos]) then
	    break
	end
	pos = pos - 1
    end
    return ncards - pos + 1
end
	
local function free_positions()
    local n = 0
    for i = 1,9 do
	if position("depot",i):empty() then
	    n = n + 1
	end
    end
    return n
end

local function max_move_size(nspare)
    if nspare > 0 then
	return 1 << nspare
    else
	return 1
    end
end

-- is a simple move of the card to the destination allowed?

local function can_move(card,to)
    local from = card:pos()
    if card
	and card:movable()
	and card:pos() ~= to
    then
	local dstcard = to:topcard()
	local dsttype = to.name
	if dsttype == "aces" then
	    if not dstcard then
		return card:value() == 1
	    else
		return card:suit() == dstcard:suit()
		    and card:value() == (dstcard:value() + 1)
	    end
	elseif dsttype == "depot" then
	    if card:value() == 1 then
		return false
	    elseif not dstcard then
		return true
	    else
		return in_sequence(dstcard, card)
	    end
	end
    end
    return false
end

--

local canvas
local gameno
local win
local raised_card
local selected_card
local shown_moves

-- move the card, both in the position model and on screen.

local function basic_card_move(card,dstpos)
    local item = card.item
    local ox,oy = item.x, item.y
    card:place(dstpos)
    local nx,ny = card:coords()
    item.x = nx
    item.y = ny
    item:raise(nil)
    return item,nx-ox,ny-oy
end

-- same, but with animation.

local function calc_accel_delay(i,n)
    if n < 3 then
	return anim_time
    end
    return math.max(2*anim_step, anim_time * (0.666 ^ (i-1)))
end

local function animate_card_move(card,dstpos)
    local item,dx,dy = basic_card_move(card,dstpos)
    -- apply a transform that puts the card back in its old place,
    -- then animate the transform away to nothing.
    item:set_simple_transform(-dx, -dy, 1, 0)
    item:animate(0,0,1,0,true,anim_time,anim_step,"FREEZE")
end

-- find cards that can be auto-moved to foundations.
-- This is called with the position state pushed; it can modify
-- the model, but not the display.

local function auto_drain_moves()
    local moves
    local done
    local function addmove(card,pos)
	if not moves then moves = {} end
	moves[1+#moves] = { card = card, pos = pos }
	card:place(pos)
	done = false
    end
    repeat
	done = true
	for _,suit in ipairs(Cards.suits) do
	    local ace = position:find_card(suit,1)
	    local acepos = ace:pos()
	    if acepos.name ~= "aces" then
		if ace:movable() then
		    -- find a free foundation
		    for i = 1,4 do
			local dstpos = position("aces",i)
			if not dstpos:topcard() then
			    addmove(ace,dstpos)
			    break
			end
		    end
		end
	    else
		local top = acepos:topcard()
		local nxt = position:find_card(top:suit(), top:value() + 1)
		if nxt and nxt:movable() then
		    local canmove = true
		    if nxt:value() > 2 then
			-- card > 2 should be moved if either:
			--   both suits of the opposite colour are no more than
			--   1 card behind
			-- OR
			--   both suits of the opposite colour are no more than
			--   2 cards behind, and the other suit of the same colour
			--   is no more than 3 cards behind
			-- i.e. we can move, say, 10club as long as we can't need
			-- it to support 9red, which is the case as long as both
			-- 9red could be moved to foundations _and_ we can't need
			-- a 9red to support 8spade. so at least 7spade, both 8red
			-- and 9club need to be on foundations for us to do this.
			local minval_opposite = 14
			local minval_othercolour = 14
			for _,suit2 in ipairs(Cards.suits) do
			    local ace2 = position:find_card(suit2,1)
			    local val = 0
			    if ace2:pos().name == "aces" then
				val = ace2:pos():topcard():value()
			    end
			    if ace2:colour() ~= nxt:colour() then
				minval_othercolour = math.min(minval_othercolour, val)
			    elseif ace2:suit() ~= nxt:suit() then
				minval_opposite = math.min(minval_opposite, val)
			    end
			end
			if minval_opposite < nxt:value() - 3
			    or minval_othercolour < nxt:value() - 2
			then
			    canmove = false
			end
		    end
		    if canmove then
			addmove(nxt,acepos)
		    end
		end
	    end
	end
    until done
    return moves
end

-- called to actually drain cards to foundations

local function auto_drain()
    position:push_state()
    local rc,moves = pcall(auto_drain_moves)
    position:pop_state()
    assert(rc,moves)
    if moves then
	for i,m in ipairs(moves) do
	    pause(calc_accel_delay(i,#moves))
	    animate_card_move(m.card,m.pos)
	end
    end
end

-- Compute complex move sequences

local append_move_sequence  -- function(seq,cards,src,dst,depots,spare...)

local function append_split_move_sequence(seq,cards,src,dst,spare,...)
    assert(spare)
    assert(#cards > 1)
    local nspares = select('#',...) + 1
    local tn = max_move_size(nspares - 1)
    local cards1,cards2 = {}, {}
    local n2 = math.max(1, #cards - tn)
    table.move(cards, 1, n2, 1, cards1)
    table.move(cards, n2+1, #cards, 1, cards2)
    append_move_sequence(seq,cards2,src,spare,nil,...)
    append_move_sequence(seq,cards1,src,dst,nil,...)
    append_move_sequence(seq,cards2,spare,dst,nil,...)
    return true
end

local function append_tricky_move_sequence(seq,cards,src,dst,depots,...)
    assert(#cards > 1)
    local cards1,cards2 = {},{}
    for split_at = 2, #cards do
	table.move(cards, 1, split_at-1, 1, cards1)
	table.move(cards, split_at, #cards + 1, 1, cards2)
	for i,depot in ipairs(depots) do
	    local depcard = depot:topcard()
	    if in_sequence(depcard, cards2[1]) then
		local nseq = {}
		local ndepots = {}
		table.move(depots, 1, i-1, 1, ndepots)
		table.move(depots, i+1, #depots, 1+#ndepots, ndepots)
		if append_move_sequence(nseq,cards2,src,depot,ndepots,...)
		    and append_move_sequence(nseq,cards1,src,dst,ndepots,...)
		    and append_move_sequence(nseq,cards2,depot,dst,ndepots,...)
		then
		    table.move(nseq, 1, #nseq, 1+#seq, seq)
		    return true
		end
	    end
	end
    end
    return false
end

append_move_sequence = function(seq,cards,src,dst,depots,...)
    local len = #cards
    if len == 1 then
	seq[1+#seq] = { card = cards[1], pos = dst }
	return true
    end
    local nspares = select('#',...)
    if len <= max_move_size(nspares)
	and append_split_move_sequence(seq,cards,src,dst,...)
    then
	return true
    end
    if depots and #depots then
	return append_tricky_move_sequence(seq,cards,src,dst,depots,...)
    end
    return false
end

local function try_complex_move(src,dst,doit)
    if src.name ~= "depot" or dst.name ~= "depot" then
	return false
    end
    local srclen = longest_sequence_len(src)
    if srclen < 2 then
	return false
    end
    local srctop = src:topcard()
    local dstcard = dst:topcard()
    -- reduce srclen to match dstcard
    if dstcard then
	if dstcard:value() <= srctop:value() + 1
	    or dstcard:value() > srctop:value() + srclen
	then
	    return false
	end
	srclen = dstcard:value() - srctop:value()
	if not in_sequence(dstcard, src:card_at(-srclen)) then
	    return false
	end
    end
    local cards = {}
    local srclist = src:cardlist()
    table.move(srclist, #srclist - srclen + 1, #srclist, 1, cards)
    local spares = {}
    local depots = {}
    for i = 1,9 do
	local pos = position("depot",i)
	if pos ~= src and pos ~= dst then
	    if pos:empty() then
		spares[1+#spares] = pos
	    else
		depots[1+#depots] = pos
	    end
	end
    end
    local seq = {}
    if not append_move_sequence(seq,cards,src,dst,depots,table.unpack(spares))
	and not dstcard
	and srclen > 2
    then
	repeat
	    srclen = srclen - 1
	    seq = {}
	    table.move(cards,2,#cards+1,1)
	until append_move_sequence(seq,cards,src,dst,depots,table.unpack(spares))
	    or srclen <= 2
    end
    if #seq == 0 then
	return false
    end
    if doit then
	for _,m in ipairs(seq) do
	    animate_card_move(m.card,m.pos)
	    pause(anim_time)
	end
    end
    return true
end

local function possible_moves()
    local moves = {}
    for src,srcname in position:positions() do
	local card = src:topcard()
	if card then
	    for pos,name in position:positions() do
		if can_move(card,pos)
		    or try_complex_move(src,pos,false)
		then
		    local boring = pos:empty()
		    moves[1+#moves] = { card = card, src = src, dst = pos, boring = boring }
		end
	    end
	end
    end
    return moves
end

--

local function card_unraise()
    if raised_card then
	raised_card:remove()
	raised_card = nil
    end
end

local function card_raise(card)
    local item = card.item
    raised_card = Goo.CanvasImage {
	parent = canvas.root_item,
	x = item.x, y = item.y,
	pixbuf = card.image,
	on_button_release_event = function(...) card_unraise() end,
	on_button_press_event = function(...) card_unraise() end,
    }
end

local function card_unselect()
    if selected_card then
	selected_card.item.pixbuf = selected_card.image
	selected_card = nil
    end
end

local function card_select(card)
    local is_self = selected_card == card
    if selected_card then
	card_unselect()
    end
    if not is_self and card == card:pos():topcard() then
	selected_card = card
	card.item.pixbuf = card.revimage
    end
end

local function perform_move(card,pos,simple)
    local srctype = card:pos().name
    local dsttype = pos.name
    local noauto = srctype == "aces"
    if srctype == "depot"
	and dsttype == "depot"
	and not simple
	and (pos:empty() or not can_move(card,pos))
	and try_complex_move(card:pos(), pos, true)
    then
	;
    elseif can_move(card,pos) then
	animate_card_move(card,pos)
    else
	return
    end
    if not noauto then
	codefer(auto_drain)
    end
end

local function card_2click(card,item,i2,e)
    card_unraise()
    card_unselect()
    if e.button == 1 and card:movable() then
	if card:value() == 1 then
	    for i = 1,4 do
		if position("aces",i):empty() then
		    codefer(perform_move,card,position("aces",i))
		    break
		end
	    end
	else
	    local acepos = position:find_card(card:suit(),1):pos()
	    codefer(perform_move,card,acepos)
	end
    end
end

local function card_click(card,item,i2,e)
    card_unraise()
    if e.button == 3 and card:pos().name == "depot" then
	card_raise(card)
    elseif e.button == 1 then
	if e.type == "DOUBLE_BUTTON_PRESS"
	    or e.type == "2BUTTON_PRESS"
	then
	    card_2click(card,item,i2,e)
	elseif selected_card and selected_card ~= card then
	    local topcard = selected_card
	    local pos = card:pos()
	    card_unselect()
	    codefer(perform_move,topcard,pos)
	else
	    card_select(card)
	end
    end
end

local function card_unclick(card,item,i2,e)
    if e.button == 3 then
	card_unraise()
    end
end

local function depot_click(pos,item,i2,e)
    card_unraise()
    if e.button == 1 then
	local topcard = pos:topcard()
	if selected_card and selected_card ~= topcard then
	    local card = selected_card
	    card_unselect()
	    codefer(perform_move,card,pos)
	elseif topcard then
	    card_select(topcard)
	end
    elseif e.button == 3 and selected_card and pos:empty() then
	local card = selected_card
	card_unselect()
	codefer(perform_move,card,pos,true)
    end
end

local function aces_click(pos,item,i2,e)
    card_unraise()
    if e.button == 1 then
	local topcard = pos:topcard()
	if selected_card and selected_card ~= topcard then
	    local card = selected_card
	    card_unselect()
	    codefer(perform_move,card,pos)
	else
	    card_select(topcard)
	end
    end
end

local function draw_moves(parent,moves)
    for _,move in ipairs(moves) do
	if not move.boring then
	    local x1,y1 = move.card:coords()
	    local x2,y2 = move.dst:coords(move.dst:topcard())
	    local points = Goo.CanvasPoints(2)
	    local yoff = 96
	    if move.src.name == "stock" then
		yoff = 24
	    elseif move.src.name == "depot" then
		yoff = 32 + 16*move.src.idx
	    end
	    points:set_point(0,x1+64,y1+96)
	    points:set_point(1,x2+64,y2+yoff)
	    Goo.CanvasPolyline {
		parent = parent,
		line_width = 5,
		fill_color = "#aa00aa",
		stroke_color = "#aa00aa",
		start_arrow = false,
		end_arrow = true,
		points = points
	    }
	end
    end
end

local function moves_show()
    local moves = possible_moves()
    if moves and #moves then
	shown_moves = Goo.CanvasGroup {
	    parent = canvas.root_item
	}
	codefer(draw_moves,shown_moves,moves)
    end
end

local function moves_unshow()
    if shown_moves then
	shown_moves:remove()
	shown_moves = nil
    end
end

local function canvas_click(obj,e)
    if e.button == 2 then
	moves_unshow()
	if e.type == "BUTTON_PRESS" then
	    moves_show()
	end
    end
end

--

local function initial_render(card)
    local x,y = card:coords()
    card.item = Goo.CanvasImage {
	parent = canvas.root_item,
	x = x, y = y,
	pixbuf = card.image,
	on_button_press_event = function(...) guard(card_click,card,...) end,
	on_button_release_event = function(...) card_unclick(card,...) end
    }
end

local function deal()
    local n = 9
    local p = 1
    for i = 1,52 do
	local card = position.deck[i]
	local dstpos
	if n < 1 then
	    dstpos = position("stock",p)
	    p = p + 1
	else
	    dstpos = position("depot",p)
	    p = p + 1
	    if p > n then
		n,p = n - 1, 1
	    end
	end
	initial_render(card)
	animate_card_move(card,dstpos)
	pause(math.floor(anim_time*0.66))
    end
end

local function restart_game()

    local cwidth, cheight = 1192, 852

    if canvas then
	canvas:destroy()
	canvas = nil
    end
    
    canvas = Goo.Canvas {
	id = 'canvas',
	width = cwidth, height = cheight,
	on_button_press_event = function(...) guard(canvas_click,...) end,
	on_button_release_event = function(...) canvas_click(...) end,
    }

    canvas:set_bounds(0, 0, cwidth, cheight)
    
    local root = canvas.root_item

    Goo.CanvasRect {
	parent = root,
	x = 0, y = 0, width = cwidth, height = cheight,
	fill_color = "green",
	line_width = 0
    }

    math.randomseed(gameno)
    position = Cards.new_layout {
	{ name = "deck", num = 1,
	  x = 1056, dx = 0,
	  y = 654, dy = 0,
	},
	{ name = "aces", num = 4,
	  x = 84, dx = 296,
	  y = 4, dy = 0,
	  init = function(self,i,x,y)
	      Goo.CanvasRect {
		  parent = root,
		  x = x, y = y, width = 128, height = 192,
		  line_width = 3, fill_color = "darkgreen",
		  pointer_events = "ALL",
		  on_button_press_event = function(...) guard(aces_click,self,...) end
	      }
	  end
	},
	{ name = "stock", num = 7,
	  x = 20, dx = 169,
	  y = 202, dy = 0,
	  init = function(self,i,x,y)
	      Goo.CanvasRect {
		  parent = root,
		  x = x, y = y, width = 128, height = 192,
		  line_width = 0,
		  pointer_events = "NONE",
	      }
	  end
	},
	{ name = "depot", num = 9,
	  x = 4, dx = 132,
	  y = 400, dy = 0,
	  posfn = function(p,c,i,x,y)
	      return x, y + 22*(i-1)
	  end,
	  init = function(self,i,x,y)
	      Goo.CanvasRect {
		  parent = root,
		  x = x, y = y, width = 128, height = 192 + 20*22,
		  line_width = 0,
		  pointer_events = "ALL",
		  on_button_press_event = function(...) guard(depot_click,self,...) end
	      }
	  end
	},
    }

    win.child.box:add(canvas)
    win.title = "King Albert's Patience #"..gameno
    win:show_all()
    deal()
end

local function init_game()
    math.randomseed(math.floor(os.clock() * 1000000) ~ os.time())
    math.random()
    math.random()
    math.random()
    gameno = math.random(1,131072)
    restart_game()
end

win = Gtk.Window {
    type = Gtk.TOPLEVEL,
    title = "King Albert's Patience",
    border_width = 0,
    on_delete_event = Gtk.main_quit,
    on_key_press_event = nil,
    on_map_event = function()
	codefer(init_game)
	win.on_map_event = nil
    end,
    Gtk.Box {
	id = 'box',
	orientation = "VERTICAL",
	Gtk.MenuBar {
	    id = 'menubar',
	    Gtk.MenuItem {
		label = "File",
		visible = true,
		submenu = Gtk.Menu {
		    id = 'menu',
		    Gtk.MenuItem {
			label = "Restart Game",
			visible = true,
			on_activate = function() guard(codefer,restart_game) end
		    },
		    Gtk.MenuItem {
			label = "New Game",
			visible = true,
			on_activate = function() guard(codefer,init_game) end
		    },
		    Gtk.MenuItem {
			label = "Quit",
			visible = true,
			on_activate = Gtk.main_quit
		    },
		}
	    }
	}
    }
}

init_game()

Gtk.main()
  
