-- -*- Lua -*-

local lgi = require 'lgi'
local GdkPixbuf = lgi.GdkPixbuf

local names = { "A", "2", "3", "4", "5", "6",
		"7", "8", "9", "10", "J", "Q", "K" }
local suits = { "club", "diamond", "heart", "spade" }
local colours = { club = false, diamond = true, heart = true, spade = false }
local allcards = {}
local card_meta = {}

local M = {
    names = names,
    suits = suits,
}

-- There are actually 3 classes in here: Card, Position, Layout.

local CardMethods = {
}

local CardMeta = {
    __index = CardMethods
}

local LayoutMethods = {
}

local LayoutMeta = {
    __index = LayoutMethods
}

local PositionMethods = {
}

local PositionMeta = {
    __index = PositionMethods
}

local function new_card(name,val,suit)
    local fullname = name .. suit
    local img = GdkPixbuf.Pixbuf.new_from_file("cards/" .. fullname .. ".png")
    local rimg = GdkPixbuf.Pixbuf.new_from_file("cards/r" .. fullname .. ".png")
    local card = { name = name, _value = val, _suitname = suit,
		   fullname = fullname, image = img, revimage = rimg }
    setmetatable(card, CardMeta)
    allcards[1+#allcards] = card
    card_meta[card] = { __index = card, __name = fullname }
end
    
for _,suit in ipairs(suits) do
    for val,name in ipairs(names) do
	new_card(name,val,suit)
    end
end

--

function CardMethods:value()
    return self._value
end

function CardMethods:suit()
    return self._suitname
end

function CardMethods:colour()
    return colours[self._suitname]
end

function CardMethods:pos()
    local parent = assert(self.parent)
    return parent:card_pos(self)
end

function CardMethods:movable()
    return self:pos():topcard() == self
end

function CardMethods:coords()
    return self:pos():coords(self)
end

function CardMethods:place(pos,n)
    local parent = assert(self.parent)
    if not n then
	local cardlist = pos:cardlist()
	n = 1 + #cardlist
    end
    assert(not pos[n])
    local oldpos,oldidx = parent.cardpos[self], parent.cardidx[self]
    parent.cardpos[self] = pos
    parent.cardidx[self] = n
    pos:add(self)
    if oldpos then
	oldpos:remove(self)
    end
end

--
-- The layout object we create and manipulate represents a shuffled
-- deck in which each card is associated with a "position", the set of
-- positions being defined more or less on the fly. A position is
-- associated with an x,y location that may be static or dynamic.

local function clone_card(self,card)
    return setmetatable({ parent = self }, card_meta[card])
end

local function shuffle(self,allcards)
    local res = {}
    for i = 1,52 do
	res[i] = clone_card(self,allcards[i])
    end
    for i = 1,51 do
	local j = i + math.random(0, 52-i)
	res[i], res[j] = res[j], res[i]
    end
    return res
end

function M.new_layout(...)
    local self = setmetatable({ pos = {},
				cardpos = {},
				cardidx = {},
				poscache = {},
			      }, LayoutMeta)
    self:init_positions(...)
    self.deck = shuffle(self,allcards)
    self.allcards = {}
    for _,s in ipairs(suits) do
	self.allcards[s] = {}
    end
    for _,c in ipairs(self.deck) do
	self.allcards[c:suit()][c:value()] = c
    end
    if self.pos.deck[1] then
	for i,c in ipairs(self.deck) do
	    c:place(self.pos.deck[1],i)
	end
    end
    return self
end

function LayoutMethods:find_card(suit,val)
    return self.allcards[suit][val]
end
    
function LayoutMethods:card_pos(card)
    return self.cardpos[card], self.cardidx[card]
end

local function derive_table(tab)
    return setmetatable({}, {__index=tab})
end
local function underive_table(tab)
    return getmetatable(tab).__index
end
local function rederive_table(tab)
    return setmetatable({},getmetatable(tab).__index)
end

local function seq_to_string(s)
    local t = {}
    for _,v in ipairs(s) do
	t[1+#t] = tostring(v)
    end
    return "{"..table.concat(t,",").."}"
end

local function derive_cow_sequence(tab)
    if tab then
	return setmetatable(
	    {},
	    {__index=tab,
	     __len=function(t) return #tab end,
	     __newindex=function(t,k,v)
		 for i,v in ipairs(tab) do
		     rawset(t,i,v)
		 end
		 rawset(t,k,v)
		 setmetatable(t,nil)		 
	     end,
	     __tostring=seq_to_string
	    }
	)
    else
	return {}
    end
end

local function cache_check(self)
    local cardpos = self.cardpos
    local cardidx = self.cardidx
    local poscache = self.poscache
    for _,c in ipairs(self.deck) do
	local t = poscache[cardpos[c]]
	assert(not t or t[cardidx[c]] == c)
    end
    for pos,t in pairs(poscache) do
	if t then
	    for i,c in ipairs(t) do
		assert(cardpos[c] == pos)
		assert(cardidx[c] == i)
	    end
	end
    end
end
    
function LayoutMethods:push_state()
    cache_check(self)
    self.poscache = derive_table(self.poscache)
    self.cardpos = derive_table(self.cardpos)
    self.cardidx = derive_table(self.cardidx)
    cache_check(self)
end
function LayoutMethods:pop_state()
    cache_check(self)
    self.poscache = underive_table(self.poscache)
    self.cardpos = underive_table(self.cardpos)
    self.cardidx = underive_table(self.cardidx)
    cache_check(self)
end
function LayoutMethods:restore_state()
    self.poscache = rederive_table(self.poscache)
    self.cardpos = rederive_table(self.cardpos)
    self.cardidx = rederive_table(self.cardidx)
    cache_check(self)
end

function LayoutMethods:getcache(pos,popfn)
    local c = rawget(self.poscache,pos)
    if c then
	return c
    end
    -- if we don't need the cache now, we have to mark it
    -- invalid at this nesting level so that it will be
    -- rebuilt when needed. Otherwise changes we make that
    -- don't update the cache will be missed later
    if not popfn then
	self.poscache[pos] = false
	return nil
    end
    c = self.poscache[pos]
    if c then
	c = derive_cow_sequence(c)
	self.poscache[pos] = c
	return c
    end
    c = setmetatable({}, {__tostring=seq_to_string})
    popfn(c)
    self.poscache[pos] = c
    return c
end    

function LayoutMethods:add_position(name, idx, x, y, posfn)
    if not self.pos[name] then self.pos[name] = {} end
    local npos = setmetatable({ parent = self,
				name = name, idx = idx, x = x, y = y,
				posfn = posfn or function(p,c,i,x,y) return x,y end,
				poscache = false
			      }, PositionMeta)
    self.pos[name][idx] = npos
    return npos
end
    
-- { { name = ..., num = ..., x = ..., y = ..., dx, dy, posfn = ..., init = ... }, ... }
function LayoutMethods:init_positions(poslist)
    for _,pos in ipairs(poslist) do
	for i = 0,pos.num-1 do
	    local px,py = pos.x + i*pos.dx, pos.y + i*pos.dy
	    local npos = self:add_position(pos.name, i+1, px, py, pos.posfn)
	    if pos.init then pos.init(npos,i+1,px,py) end
	end
    end
    return self
end

function LayoutMeta:__call(name,idx)
    return self.pos[name][idx]
end

--

function PositionMeta:__tostring()
    return self.name .. ":" .. self.idx
end

function PositionMethods:coords(card)
    local i
    if card then
	local pos,idx = self.parent:card_pos(card)
	if pos == self then i = idx end
    end
    return self.posfn(self, card, i, self.x, self.y)
end

function PositionMethods:getcache(opt)
    local cache = self.parent:getcache(
	self,
	(not opt) and 
	    function(tcache)	
		local idx = self.parent.cardidx
		for card,pos in pairs(self.parent.cardpos) do
		    if pos == self then
			tcache[idx[card]] = card
		    end
		end
    end)
    return cache
end

function PositionMethods:cardlist()
    return self:getcache(false)
end

function PositionMethods:remove(card)
    local cache = self:getcache(true)
    if cache then
	assert(card == cache[#cache], "assert failed: card "..tostring(card).." not last in cache: "..tostring(cache))
	cache[#cache] = nil
    end
end

function PositionMethods:add(card)
    local cache = self:getcache(true)
    if cache then
	cache[1+#cache] = card
    end
end

function PositionMethods:topcard()
    local cache = self:cardlist()
    return cache[#cache]
end

function PositionMethods:card_at(n)
    local cache = self:cardlist()
    if n > 0 and n <= #cache then
	return cache[n]
    elseif n < 0 and n >= -#cache then
	return cache[1+n+#cache]
    end
    return nil
end

function PositionMethods:empty()
    local cache = self:cardlist()
    return #cache == 0
end

return M
