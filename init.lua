if farming.mod ~= "redo" then
	error("planting interpolation requires farming redo")
end

planting_interpolation = fmod.create()

local s = planting_interpolation.settings

local max_delay = s.max_delay -- in us
local max_distance = s.max_distance

local last_place_by_player_name = {}

-- keep track of server lag a bit
local steps_to_count = s.steps_to_count

local cumulative_dtimes = 0
local dtimes = {}
local dtime_index = 1

for _ = 1, steps_to_count do
	table.insert(dtimes, 0)
end

local function xor(a, b)
	return (a or b) and not (a and b)
end

local function iterate_between(p1, p2)
	assert(p1.x == p2.x or p1.z == p2.z)
	local p = table.copy(p1)
	if p1.x == p2.x then
		-- iterate z
		local z = p1.z
		local stop = p2.z
		local step = stop > z and 1 or -1

		return function()
			if z == stop then
				return
			end
			z = z + step
			p.z = z
			return p
		end
	else
		-- iterate x
		local x = p1.x
		local stop = p2.x
		local step = stop > x and 1 or -1

		return function()
			if x == stop then
				return
			end
			x = x + step
			p.x = x
			return p
		end
	end
end

local function get_refill(player, item_name)
	local inv = player:get_inventory()
	local wield_index = player:get_wield_index()

	for i, stack in ipairs(inv:get_list("main")) do
		if stack:get_name() == item_name and i ~= wield_index then
			inv:set_stack("main", i, "")
			return stack
		end
	end

	return ItemStack()
end

local function place_seedling(pos, player, itemstack, item_name, plant)
	if minetest.get_node(pos).name ~= "air" then
		return false
	end

	local under = vector.new(pos.x, pos.y - 1, pos.z)
	local under_name = minetest.get_node(under).name

	if minetest.get_item_group(under_name, "soil") < 2 then
		return false
	end

	if minetest.is_protected(pos, player:get_player_name()) then
		return false
	end

	local param2 = minetest.registered_nodes[plant].place_param2 or 1
	minetest.set_node(pos, { name = plant, param2 = param2 })
	minetest.sound_play("default_place_node", { pos = pos, gain = 1.0 })

	if minetest.is_creative_enabled(player) then
		return true
	end

	if itemstack:is_empty() then
		itemstack:replace(get_refill(player, item_name))
	else
		itemstack:take_item()
	end

	return not itemstack:is_empty()
end

local old_place_seed = farming.place_seed

function farming.place_seed(itemstack, player, pointed_thing, plant)
	if not (itemstack and (not itemstack:is_empty()) and pointed_thing and pointed_thing.type == "node" and plant) then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	if not minetest.is_player(player) then
		-- machines are not applicable
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	if pointed_thing.above.y ~= pointed_thing.under.y + 1 then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	local player_name = player:get_player_name()
	local now = minetest.get_us_time()
	local pos = vector.copy(pointed_thing.above)

	local last_place = last_place_by_player_name[player_name]
	last_place_by_player_name[player_name] = { pos = pos, plant = plant, when = now }

	if not last_place then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	if last_place.plant ~= plant then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	local elapsed_since_last_place = now - last_place.when

	if elapsed_since_last_place > math.max(max_delay, cumulative_dtimes) then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	local offset = pos - last_place.pos

	if offset.y ~= 0 and not xor(offset.x == 0, offset.z == 0) then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	local distance = math.abs(offset.x + offset.z)

	if 2 > distance or distance >= max_distance then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	local item_name = itemstack:get_name()
	local num_placed = 0

	for pos2 in iterate_between(last_place.pos, pos) do
		if not place_seedling(pos2, player, itemstack, item_name, plant) then
			break
		end
		num_placed = num_placed + 1
	end

	if itemstack:is_empty() then
		itemstack = get_refill(player, item_name)
	elseif num_placed == 0 then
		return old_place_seed(itemstack, player, pointed_thing, plant)
	end

	return itemstack
end

minetest.register_globalstep(function(dtime)
	dtime = dtime * 1e6
	cumulative_dtimes = cumulative_dtimes - dtimes[dtime_index] + dtime
	dtimes[dtime_index] = dtime
	dtime_index = (dtime_index % steps_to_count) + 1

	local now = minetest.get_us_time()
	for player_name, last_place in pairs(last_place_by_player_name) do
		local elapsed_since_last_place = now - last_place.when

		if elapsed_since_last_place > math.max(max_delay, cumulative_dtimes) then
			last_place_by_player_name[player_name] = nil
		else
			local player = minetest.get_player_by_name(player_name)

			if player then
				local control = player:get_player_control()

				if not control.place then
					last_place_by_player_name[player_name] = nil
				end
			else
				last_place_by_player_name[player_name] = nil
			end
		end
	end
end)
