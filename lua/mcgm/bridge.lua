MC_GM = MC_GM or {}

local P = MC_GM.Protocol
local C = MC_GM.Config

local socketLib
local server
local clients = {}
local proxyOwners = {}
local sharedPlatform = {}
local worldBlocks = {}
local minecraftBlockEnts = {}
local minecraftProfileCache = {}
local nextEntityId = 9000
local lastPosSync = 0
local lastPropScan = 0
local lastHitboxSync = 0

local STATE_HANDSHAKE = 0
local STATE_STATUS = 1
local STATE_LOGIN = 2
local STATE_PLAY = 3

local ITEM_BOW = 261
local ITEM_ARROW = 262
local ITEM_IRON_SWORD = 267

local sendPacket
local sendChat
local sendSystemChat
local broadcastChat
local chatJson
local isSharedPlatform
local minecraftAngle
local sendBridgeArenaBlocks
local sendSpawnChunks
local distanceToSegment
local sendGmodPlayersToMinecraft
local sendMinecraftPlayersToMinecraft
local sendGmodPlayerEquipment
local sendDeferredWorldSync
local refreshMinecraftPlayerForViewers

local function log(msg)
    MsgC(Color(90, 200, 255), "[MCGM] ", color_white, tostring(msg), "\n")
end

local function blockKey(x, y, z)
    return tostring(math.floor(x)) .. "," .. tostring(math.floor(y)) .. "," .. tostring(math.floor(z))
end

local function getWorldBlock(x, y, z)
    return worldBlocks[blockKey(x, y, z)]
end

local function parseBlockKey(key)
    local x, y, z = string.match(key, "^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

local function ensureWorldStorage()
    if not file or not util then return end
    if not file.Exists("mcgm", "DATA") then
        file.CreateDir("mcgm")
    end
    if not file.Exists(MC_GM.WorldPath, "DATA") then
        local fresh = {
            version = C.world_version,
            created_at = os.time(),
            seed = math.random(1, 2147483647),
            blocks = {}
        }
        file.Write(MC_GM.WorldPath, util.TableToJSON(fresh, true))
        log("created fresh Minecraft bridge world at data/" .. MC_GM.WorldPath)
    end
end

local function loadWorldStorage()
    ensureWorldStorage()
    if not file or not util or not file.Exists(MC_GM.WorldPath, "DATA") then return end

    local raw = file.Read(MC_GM.WorldPath, "DATA")
    local decoded = raw and util.JSONToTable(raw) or nil
    if not decoded or type(decoded.blocks) ~= "table" then
        log("world storage was missing or invalid; recreating from scratch")
        file.Delete(MC_GM.WorldPath)
        ensureWorldStorage()
        decoded = util.JSONToTable(file.Read(MC_GM.WorldPath, "DATA") or "")
    end

    worldBlocks = decoded and decoded.blocks or {}
    log("loaded " .. table.Count(worldBlocks) .. " stored Minecraft blocks")
end

local function saveWorldStorage()
    ensureWorldStorage()
    if not file or not util then return end
    file.Write(MC_GM.WorldPath, util.TableToJSON({
        version = C.world_version,
        saved_at = os.time(),
        blocks = worldBlocks
    }, true))
end

local function vecToMinecraft(vec)
    local origin = C.gmod_origin
    local scale = C.world_scale

    return {
        x = (vec.x - origin.x) / scale,
        y = (vec.z - origin.z) / scale + C.minecraft_spawn.y,
        z = (vec.y - origin.y) / scale
    }
end

local function minecraftToVec(pos)
    local origin = C.gmod_origin
    local scale = C.world_scale

    return Vector(
        origin.x + pos.x * scale,
        origin.y + pos.z * scale,
        origin.z + (pos.y - C.minecraft_spawn.y) * scale
    )
end

local function minecraftLookVector(yaw, pitch)
    yaw = math.rad(tonumber(yaw) or 0)
    pitch = math.rad(tonumber(pitch) or 0)

    local mcX = -math.cos(pitch) * math.sin(yaw)
    local mcY = -math.sin(pitch)
    local mcZ = math.cos(pitch) * math.cos(yaw)

    return Vector(mcX, mcZ, mcY):GetNormalized()
end

local function minecraftProxyAngle(client)
    return Angle(0, (tonumber(client and client.yaw) or 0) + 90, 0)
end

local function applyMinecraftProxyHeadPose(client)
    local ent = client and client.proxyEnt
    if not IsValid(ent) then return end

    local pitch = tonumber(client.pitch) or 0
    local yaw = tonumber(client.yaw) or 0
    local bodyYaw = minecraftProxyAngle(client).y
    local localYaw = math.AngleDifference and math.AngleDifference(yaw + 90, bodyYaw) or 0
    local lookDir = minecraftLookVector(yaw, pitch)

    if ent.SetEyeTarget and client.gmodPos then
        ent:SetEyeTarget(client.gmodPos + Vector(0, 0, 56) + lookDir * 256)
    end

    if ent.SetPoseParameter then
        ent:SetPoseParameter("aim_pitch", -pitch)
        ent:SetPoseParameter("head_pitch", -pitch)
        ent:SetPoseParameter("aim_yaw", localYaw)
        ent:SetPoseParameter("head_yaw", localYaw)
        if ent.InvalidateBoneCache then ent:InvalidateBoneCache() end
    end

    if not ent.LookupBone or not ent.ManipulateBoneAngles then return end

    local headBones = C.minecraft_proxy_head_bones or {}
    local headAngle = Angle(
        pitch * (C.minecraft_proxy_head_pitch_scale or 1),
        localYaw * (C.minecraft_proxy_head_yaw_scale or 0.35),
        0
    )

    for _, boneName in ipairs(headBones) do
        local bone = ent:LookupBone(boneName)
        if bone then
            ent:ManipulateBoneAngles(bone, headAngle)
            return
        end
    end
end

local function minecraftBlockToVec(x, y, z)
    return minecraftToVec({ x = x + 0.5, y = y + 0.5, z = z + 0.5 })
end

local function enablePlayerBlockCollisionRule(ent)
    if C.minecraft_block_collide_players == false and IsValid(ent) and ent.SetCustomCollisionCheck then
        ent:SetCustomCollisionCheck(true)
    end
end

local function removeMinecraftBlockEnt(key)
    if IsValid(minecraftBlockEnts[key]) then
        minecraftBlockEnts[key]:Remove()
    end
    minecraftBlockEnts[key] = nil
end

local function getMinecraftBlockType(state)
    state = tonumber(state) or 0
    local types = C.minecraft_block_types or {}
    return types[state] or types[state - (state % 16)] or {}
end

local function spawnMinecraftBlockEnt(x, y, z, state)
    if not C.enable_minecraft_block_building or state == 0 then return end

    local key = blockKey(x, y, z)
    removeMinecraftBlockEnt(key)

    local blockType = getMinecraftBlockType(state)
    local model = blockType.model or C.minecraft_block_model
    if util and util.IsValidModel and not util.IsValidModel(model) then
        log("configured minecraft_block_model is invalid: " .. tostring(model) .. "; using hunter cube fallback")
        model = "models/hunter/blocks/cube025x025x025.mdl"
    end

    util.PrecacheModel(model)

    local ent = ents.Create(C.minecraft_block_entity_class or "base_anim")
    if not IsValid(ent) then
        log("failed to create GMod block entity for " .. key)
        return
    end

    local pos = minecraftBlockToVec(x, y, z)
    local color = blockType.color or C.minecraft_block_color or Color(80, 220, 120, 255)
    ent:SetModel(model)
    ent:SetPos(pos)
    ent:SetAngles(Angle(0, 0, 0))
    ent:SetColor(color)
    ent:SetRenderMode(color.a and color.a < 255 and RENDERMODE_TRANSCOLOR or RENDERMODE_NORMAL)
    ent:SetMaterial(blockType.material or C.minecraft_block_material or "")
    ent.MCGM_BlockKey = key
    ent.MCGM_BlockState = state
    ent:Spawn()
    ent:PhysicsInitBox(C.minecraft_block_mins or Vector(-16, -16, -16), C.minecraft_block_maxs or Vector(16, 16, 16))
    ent:SetMoveType(MOVETYPE_NONE)
    ent:SetPos(minecraftBlockToVec(x, y, z))
    ent:SetAngles(Angle(0, 0, 0))
    ent:SetModelScale(blockType.scale or C.minecraft_block_scale or 1, 0)
    ent:Activate()
    ent:SetNoDraw(false)
    ent:DrawShadow(true)
    ent:SetSolid(C.minecraft_block_solid and SOLID_VPHYSICS or SOLID_NONE)
    ent:SetCollisionBounds(C.minecraft_block_mins or Vector(-16, -16, -16), C.minecraft_block_maxs or Vector(16, 16, 16))
    ent:SetCollisionGroup(COLLISION_GROUP_NONE)
    enablePlayerBlockCollisionRule(ent)

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(false)
    end

    minecraftBlockEnts[key] = ent

    if C.debug_gmod_block_spawns then
        log("spawned GMod block " .. key .. " at " .. tostring(pos) .. " model=" .. tostring(model))
    end
end

local function applySoftMinecraftBlockCollision(ply)
    if not C.minecraft_block_soft_player_collision or not IsValid(ply) or not ply:Alive() then return end

    local plyPos = ply:GetPos()
    local playerHalfWidth = 16
    local blockHalf = C.minecraft_block_soft_collision_half_size or 16
    local expandedHalf = blockHalf + playerHalfWidth
    local margin = 0.5
    local newPos = Vector(plyPos.x, plyPos.y, plyPos.z)
    local moved = false

    for _, ent in pairs(minecraftBlockEnts) do
        if IsValid(ent) then
            local blockPos = ent:GetPos()
            local blockTop = blockPos.z + blockHalf
            local playerBottom = newPos.z
            local footSnapDepth = 10

            if playerBottom >= blockPos.z and playerBottom < blockTop and blockTop - playerBottom <= footSnapDepth then
                local dx = newPos.x - blockPos.x
                local dy = newPos.y - blockPos.y
                local absX = math.abs(dx)
                local absY = math.abs(dy)

                if absX < expandedHalf and absY < expandedHalf then
                    newPos.z = blockTop + margin
                    moved = true
                end
            end
        end
    end

    if moved then
        ply:SetPos(newPos)
        local velocity = ply:GetVelocity()
        if velocity.z < 0 then
            ply:SetVelocity(Vector(0, 0, -velocity.z))
        end
    end
end

local function rebuildMinecraftBlockEnts()
    for key, ent in pairs(minecraftBlockEnts) do
        if IsValid(ent) then ent:Remove() end
        minecraftBlockEnts[key] = nil
    end

    for key, state in pairs(worldBlocks) do
        local x, y, z = parseBlockKey(key)
        local isBaseFloor = y == C.floor_y and state == C.floor_block_state
        if x and y and z and state ~= 0 and not isBaseFloor then
            spawnMinecraftBlockEnt(x, y, z, state)
        end
    end
end

local function updateMinecraftProxy(client)
    if not C.enable_minecraft_player_proxies or not client.gmodPos then return end

    if not IsValid(client.proxyEnt) then
        local ent = ents.Create(C.minecraft_proxy_entity_class or "prop_dynamic")
        if not IsValid(ent) then return end

        ent:SetModel(C.minecraft_proxy_model)
        ent:SetPos(client.gmodPos)
        ent:SetAngles(minecraftProxyAngle(client))
        ent:Spawn()
        ent:SetMoveType(MOVETYPE_NONE)
        ent:SetSolid(SOLID_BBOX)
        ent:SetCollisionBounds(C.minecraft_proxy_mins or Vector(-16, -16, 0), C.minecraft_proxy_maxs or Vector(16, 16, 72))
        ent:SetCollisionGroup(COLLISION_GROUP_PLAYER)
        ent:SetColor(Color(80, 180, 255))
        ent:SetName("mcgm_" .. tostring(client.username or client.entityId))
        ent:SetNWBool("MCGM_MinecraftProxy", C.enable_minecraft_nametags)
        ent:SetNWString("MCGM_Name", "[MC] " .. tostring(client.username or "Minecraft"))
        ent:SetNoDraw(false)
        ent:DrawShadow(true)
        if ent.LookupSequence and ent.ResetSequence then
            local seq = ent:LookupSequence("idle_all_01")
            if seq and seq >= 0 then
                ent:ResetSequence(seq)
            end
        end
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableMotion(false)
        end
        client.proxyEnt = ent
        proxyOwners[ent] = client
    end

    client.proxyEnt:SetPos(client.gmodPos)
    client.proxyEnt:SetAngles(minecraftProxyAngle(client))
    client.proxyEnt:SetCollisionBounds(C.minecraft_proxy_mins or Vector(-16, -16, 0), C.minecraft_proxy_maxs or Vector(16, 16, 72))
    client.proxyEnt:SetNWBool("MCGM_MinecraftProxy", C.enable_minecraft_nametags)
    client.proxyEnt:SetNWString("MCGM_Name", "[MC] " .. tostring(client.username or "Minecraft"))
    client.proxyEnt:SetNoDraw(false)
    client.proxyEnt:DrawShadow(true)
    local phys = client.proxyEnt:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetPos(client.gmodPos)
        phys:SetAngles(minecraftProxyAngle(client))
        phys:EnableMotion(false)
        phys:Wake()
    end
    applyMinecraftProxyHeadPose(client)

    if C.debug_minecraft_movement and (not client.nextMoveLog or CurTime() >= client.nextMoveLog) then
        client.nextMoveLog = CurTime() + 1
        log((client.username or "MC") .. " proxy at " .. tostring(client.gmodPos))
    end
end

local function setMinecraftClientPosition(client, x, y, z, yaw, pitch)
    client.mcPos = { x = x or 0, y = y or 0, z = z or 0 }
    if yaw then client.yaw = yaw end
    if pitch then client.pitch = pitch end
    client.gmodPos = minecraftToVec(client.mcPos)
    updateMinecraftProxy(client)
end

local function removeMinecraftProxy(client)
    if IsValid(client.proxyEnt) then
        proxyOwners[client.proxyEnt] = nil
        client.proxyEnt:Remove()
    end
    client.proxyEnt = nil
end

local function resetClientVisibleEntities(client)
    if not client then return end

    client.spawnedGmodEntities = {}
    client.pendingGmodSpawns = {}
    client.spawnedMinecraftEntities = {}
    client.pendingMinecraftSpawns = {}
end

local function recreateMinecraftProxy(client)
    removeMinecraftProxy(client)
    updateMinecraftProxy(client)
end

local function sendSetSlot(client, slot, itemId, count, damage)
    sendPacket(client, 0x16,
        string.char(0) ..
        P.writeShort(slot) ..
        P.writeSlot(itemId, count or 1, damage or 0)
    )
end

local function sendMinecraftCombatHotbar(client)
    sendSetSlot(client, 36, ITEM_IRON_SWORD, 1, 0)
    sendSetSlot(client, 37, ITEM_BOW, 1, 0)
    sendSetSlot(client, 38, ITEM_ARROW, 64, 0)

    for hotbarSlot, state in pairs(C.minecraft_hotbar_blocks or {}) do
        local blockType = getMinecraftBlockType(state)
        local itemId = blockType.item_id or math.floor((tonumber(state) or 0) / 16)
        if hotbarSlot >= 0 and hotbarSlot <= 8 and itemId > 0 then
            sendSetSlot(client, 36 + hotbarSlot, itemId, blockType.count or 64, blockType.damage or 0)
        end
    end
end

local function sendMinecraftGameMode(client, mode)
    sendPacket(client, 0x1E,
        string.char(3) ..
        P.writeFloat(mode or 1)
    )
end

local function sendMinecraftAbilities(client, creative)
    sendPacket(client, 0x2C,
        string.char(creative and 0x0D or 0) ..
        P.writeFloat(0.05) ..
        P.writeFloat(0.1)
    )
end

local function sendMinecraftMaxHealth(client)
    local maxHealth = tonumber(C.minecraft_proxy_health) or 100
    sendPacket(client, 0x4E,
        P.writeVarInt(client.entityId) ..
        P.writeInt(1) ..
        P.writeString("generic.maxHealth") ..
        P.writeDouble(maxHealth) ..
        P.writeVarInt(0)
    )
end

local function sendMinecraftHealth(client)
    sendPacket(client, 0x41,
        P.writeFloat(client.mcHealth or C.minecraft_proxy_health) ..
        P.writeVarInt(20) ..
        P.writeFloat(5)
    )
end

local function respawnMinecraftClient(client)
    if not client or client.state ~= STATE_PLAY then return end

    local spawn = C.minecraft_spawn
    log("respawning Minecraft client " .. tostring(client.username or client.entityId))

    client.deadInMinecraft = false
    client.mcHealth = C.minecraft_proxy_health
    client.mcPos = table.Copy(spawn)
    client.gmodPos = minecraftToVec(client.mcPos)
    recreateMinecraftProxy(client)

    -- Vanilla 1.12 clients need a dimension change before respawning back into
    -- the same dimension, otherwise the respawn screen can get stuck.
    sendPacket(client, 0x35,
        P.writeInt(-1) ..
        string.char(1) ..
        string.char(1) ..
        P.writeString("flat")
    )
    sendPacket(client, 0x35,
        P.writeInt(0) ..
        string.char(1) ..
        string.char(1) ..
        P.writeString("flat")
    )
    if C.send_chunks_on_login then
        sendSpawnChunks(client)
    end
    sendMinecraftGameMode(client, 1)
    sendMinecraftAbilities(client, true)
    sendMinecraftMaxHealth(client)
    sendMinecraftHealth(client)
    sendMinecraftCombatHotbar(client)
    sendPacket(client, 0x2F,
        P.writeDouble(spawn.x + 0.5) ..
        P.writeDouble(spawn.y) ..
        P.writeDouble(spawn.z + 0.5) ..
        P.writeFloat(0) ..
        P.writeFloat(0) ..
        string.char(0) ..
        P.writeVarInt(math.floor(CurTime() * 1000) % 2147483647)
    )
    resetClientVisibleEntities(client)
    if refreshMinecraftPlayerForViewers then
        refreshMinecraftPlayerForViewers(client)
    end
    timer.Simple(C.defer_world_sync_after_respawn or 0.75, function()
        sendDeferredWorldSync(client)
    end)
end

local function killMinecraftClient(client, attackerName)
    if not client or client.deadInMinecraft then return end

    client.deadInMinecraft = true
    client.mcHealth = 0
    sendMinecraftGameMode(client, 0)
    sendMinecraftAbilities(client, false)
    sendMinecraftHealth(client)
    sendPacket(client, 0x2D,
        P.writeVarInt(2) ..
        P.writeVarInt(client.entityId) ..
        P.writeInt(client.entityId) ..
        chatJson(tostring(attackerName or "GMod") .. " killed " .. tostring(client.username or "Minecraft"))
    )
end

local function damageMinecraftClient(client, amount, attackerName)
    if not client or client.state ~= STATE_PLAY or client.deadInMinecraft then return end

    client.mcHealth = math.max(0, (client.mcHealth or C.minecraft_proxy_health) - amount)
    sendMinecraftHealth(client)
    sendSystemChat(client, "Ouch: " .. tostring(attackerName or "GMod") .. " hit you for " .. amount)

    if client.mcHealth <= 0 then
        killMinecraftClient(client, attackerName)
    end
end

sendPacket = function(client, packetId, payload)
    if not client or not client.sock then return end

    local bytes = P.packet(packetId, payload)
    client.outBuffer = (client.outBuffer or "") .. bytes
end

local function flushClientOutput(client)
    if not client.outBuffer or client.outBuffer == "" then return end

    local sent, err, partial = client.sock:send(client.outBuffer)
    if sent then
        client.outBuffer = string.sub(client.outBuffer, sent + 1)
        return
    end

    if err == "timeout" then
        local sentBytes = tonumber(partial) or 0
        if sentBytes > 0 then
            client.outBuffer = string.sub(client.outBuffer, sentBytes + 1)
        end
        return
    end

    client.dead = true
end

local function broadcastPacket(packetId, payload)
    for _, client in pairs(clients) do
        if client.state == STATE_PLAY then
            sendPacket(client, packetId, payload)
        end
    end
end

local function sendBlockChange(client, x, y, z, state)
    sendPacket(client, 0x0B,
        P.writePosition(math.floor(x), math.floor(y), math.floor(z)) ..
        P.writeVarInt(state)
    )
end

local function broadcastBlockChange(x, y, z, state)
    for _, client in pairs(clients) do
        if client.state == STATE_PLAY then
            sendBlockChange(client, x, y, z, state)
        end
    end
end

local function resendSpawnChunksToMinecraft()
    for _, client in pairs(clients) do
        if client.state == STATE_PLAY then
            sendSpawnChunks(client)
        end
    end
end

local function setWorldBlock(x, y, z, state, persist)
    x = math.floor(x)
    y = math.floor(y)
    z = math.floor(z)
    state = tonumber(state) or 0

    if persist then
        local key = blockKey(x, y, z)
        if state == 0 then
            worldBlocks[key] = nil
            removeMinecraftBlockEnt(key)
        else
            worldBlocks[key] = state
            spawnMinecraftBlockEnt(x, y, z, state)
        end
        saveWorldStorage()
    end

    broadcastBlockChange(x, y, z, state)
end

local function selectedMinecraftBuildState(client)
    local slot = client and client.selectedHotbarSlot
    local state = slot and (C.minecraft_hotbar_blocks or {})[slot]
    return tonumber(state) or C.minecraft_build_block_state
end

local function rayAabbTrace(startPos, dir, minPos, maxPos, maxDist)
    local enter = 0
    local exit = maxDist
    local hitNormal = Vector(0, 0, 0)

    local axes = {
        { s = startPos.x, d = dir.x, min = minPos.x, max = maxPos.x, normal = Vector(1, 0, 0) },
        { s = startPos.y, d = dir.y, min = minPos.y, max = maxPos.y, normal = Vector(0, 1, 0) },
        { s = startPos.z, d = dir.z, min = minPos.z, max = maxPos.z, normal = Vector(0, 0, 1) }
    }

    for _, axis in ipairs(axes) do
        if math.abs(axis.d) < 0.000001 then
            if axis.s < axis.min or axis.s > axis.max then return nil end
        else
            local t1 = (axis.min - axis.s) / axis.d
            local t2 = (axis.max - axis.s) / axis.d
            local normal = axis.normal

            if t1 > t2 then
                t1, t2 = t2, t1
                normal = -axis.normal
            end

            if t1 > enter then
                enter = t1
                hitNormal = normal
            end

            exit = math.min(exit, t2)
            if enter > exit then return nil end
        end
    end

    if enter < 0 or enter > maxDist then return nil end
    return enter, hitNormal
end

local function traceMinecraftBlockEnts(startPos, dir, maxDist)
    local bestDist
    local bestEnt
    local bestNormal
    local half = C.world_scale * 0.5

    for _, ent in pairs(minecraftBlockEnts) do
        if IsValid(ent) then
            local pos = ent:GetPos()
            local dist, normal = rayAabbTrace(
                startPos,
                dir,
                pos - Vector(half, half, half),
                pos + Vector(half, half, half),
                maxDist
            )

            if dist and (not bestDist or dist < bestDist) then
                bestDist = dist
                bestEnt = ent
                bestNormal = normal
            end
        end
    end

    if not bestEnt then return nil end

    return {
        Hit = true,
        Entity = bestEnt,
        HitPos = startPos + dir * bestDist,
        HitNormal = bestNormal
    }
end

local function gmodTraceForBlock(ply)
    if not IsValid(ply) then return nil end
    local startPos = ply:GetShootPos()
    local dir = ply:GetAimVector()
    local maxDist = C.gmod_block_place_range or 512

    local solidTrace = util.TraceLine({
        start = startPos,
        endpos = startPos + dir * maxDist,
        filter = ply,
        mask = MASK_SOLID
    })

    local blockTrace = traceMinecraftBlockEnts(startPos, dir, maxDist)
    if blockTrace and (not solidTrace.Hit or startPos:Distance(blockTrace.HitPos) < startPos:Distance(solidTrace.HitPos)) then
        return blockTrace
    end

    return solidTrace
end

local function gmodPlaceBridgeBlock(ply)
    local tr = gmodTraceForBlock(ply)
    if not tr then return false end

    local pos
    if tr.Hit then
        pos = vecToMinecraft(tr.HitPos + tr.HitNormal * (C.world_scale * 1.05))
    else
        pos = vecToMinecraft(ply:GetShootPos() + ply:GetAimVector() * 128)
    end

    local x = math.floor(pos.x)
    local y = math.floor(pos.y)
    local z = math.floor(pos.z)
    setWorldBlock(x, y, z, C.minecraft_build_block_state, true)
    resendSpawnChunksToMinecraft()
    broadcastBlockChange(x, y, z, C.minecraft_build_block_state)
    log((IsValid(ply) and ply:Nick() or "Console") .. " placed bridge block at " .. x .. "," .. y .. "," .. z)
    return true
end

local function gmodBreakBridgeBlock(ply)
    local tr = gmodTraceForBlock(ply)
    if not tr then return false end

    local key
    if tr.Hit and IsValid(tr.Entity) and tr.Entity.MCGM_BlockKey then
        key = tr.Entity.MCGM_BlockKey
    elseif tr.Hit then
        local pos = vecToMinecraft(tr.HitPos - tr.HitNormal * 2)
        key = blockKey(pos.x, pos.y, pos.z)
    end

    if not key or not worldBlocks[key] then return false end

    local x, y, z = parseBlockKey(key)
    if not x or not y or not z then return false end

    setWorldBlock(x, y, z, 0, true)
    broadcastBlockChange(x, y, z, 0)
    log((IsValid(ply) and ply:Nick() or "Console") .. " broke bridge block at " .. x .. "," .. y .. "," .. z)
    return true
end

local function replayWorldBlocks(client, quiet, limit)
    local count = 0
    if limit and limit <= 0 then limit = nil end
    for key, state in pairs(worldBlocks) do
        local x, y, z = parseBlockKey(key)
        if x and y and z then
            sendBlockChange(client, x, y, z, state)
            count = count + 1
            if limit and count >= limit then break end
        end
    end
    if not quiet then
        sendSystemChat(client, "Loaded " .. count .. " stored bridge blocks.")
    end
end

local function resetBridgeWorldBlocks()
    for key, ent in pairs(minecraftBlockEnts) do
        if IsValid(ent) then ent:Remove() end
        minecraftBlockEnts[key] = nil
    end

    for key in pairs(worldBlocks) do
        local x, y, z = parseBlockKey(key)
        if x and y and z then
            broadcastBlockChange(x, y, z, 0)
        end
        worldBlocks[key] = nil
    end

    saveWorldStorage()
    resendSpawnChunksToMinecraft()
    for _, client in pairs(clients) do
        if client.state == STATE_PLAY then
            client.spawnedGmodEntities = {}
            client.pendingGmodSpawns = {}
            sendGmodPlayersToMinecraft(client)
        end
    end
    log("reset Minecraft bridge world blocks")
end

local function chatPayload(text, position)
    local json = "{\"text\":\"" .. P.jsonString(text) .. "\"}"
    return P.writeString(json) .. string.char(position or 0)
end

chatJson = function(text)
    return P.writeString("{\"text\":\"" .. P.jsonString(text) .. "\"}")
end

sendChat = function(client, text)
    sendPacket(client, 0x0F, chatPayload(text, 0))
end

sendSystemChat = function(client, text)
    if C.quiet_minecraft_system_chat then
        log("MC system chat suppressed: " .. tostring(text))
        return
    end
    sendChat(client, text)
end

broadcastChat = function(text)
    broadcastPacket(0x0F, chatPayload(text, 0))
end

local function shortPlayerName(prefix, name)
    name = string.gsub(tostring(name or "Player"), "[^%w_]", "_")
    if name == "" then name = "Player" end
    return string.sub(prefix .. name, 1, 16)
end

local function profileUuidBytes(profile, fallbackSeed)
    if profile and profile.uuidBytes then
        return profile.uuidBytes
    end
    return P.writeUUIDBytes(fallbackSeed)
end

local function profileUuidString(profile)
    return profile and profile.uuid or nil
end

local function writeProfileProperties(properties)
    properties = properties or {}
    local out = { P.writeVarInt(#properties) }

    for _, property in ipairs(properties) do
        out[#out + 1] = P.writeString(property.name or "")
        out[#out + 1] = P.writeString(property.value or "")
        if property.signature and property.signature ~= "" then
            out[#out + 1] = P.writeBool(true)
            out[#out + 1] = P.writeString(property.signature)
        else
            out[#out + 1] = P.writeBool(false)
        end
    end

    return table.concat(out)
end

local function minecraftPlayerSkinParts(client)
    local parts
    if C.force_minecraft_skin_parts ~= false then
        parts = tonumber(C.minecraft_default_skin_parts) or 127
    else
        parts = client and tonumber(client.skinParts)
    end
    if not parts then
        parts = tonumber(C.minecraft_default_skin_parts) or 127
    end

    return math.max(0, math.min(255, math.floor(parts)))
end

local function minecraftPlayerMetadata(client)
    return string.char(13) ..
        P.writeVarInt(0) ..
        string.char(minecraftPlayerSkinParts(client)) ..
        "\255"
end

local function sendMinecraftPlayerMetadata(viewer, other)
    if not viewer or not other or viewer == other then return end
    if viewer.state ~= STATE_PLAY or other.state ~= STATE_PLAY then return end

    sendPacket(viewer, 0x3C,
        P.writeVarInt(other.entityId) ..
        minecraftPlayerMetadata(other)
    )
end

local function sendMinecraftSelfMetadata(client)
    if not client or client.state ~= STATE_PLAY then return end

    sendPacket(client, 0x3C,
        P.writeVarInt(client.entityId) ..
        minecraftPlayerMetadata(client)
    )
end

local function completeMinecraftProfileRequest(cacheEntry, profile)
    cacheEntry.loading = false
    cacheEntry.profile = profile

    for _, callback in ipairs(cacheEntry.callbacks or {}) do
        callback(profile)
    end
    cacheEntry.callbacks = {}
end

local function fetchMinecraftProfile(username, callback)
    if not C.enable_minecraft_profile_textures then
        callback(nil)
        return
    end
    if not http or not http.Fetch or not util or not util.JSONToTable then
        callback(nil)
        return
    end

    local safeName = string.sub(string.gsub(tostring(username or ""), "[^%w_]", ""), 1, 16)
    if safeName == "" then
        callback(nil)
        return
    end

    local cacheKey = string.lower(safeName)
    local cacheEntry = minecraftProfileCache[cacheKey]
    if cacheEntry and cacheEntry.profile then
        callback(cacheEntry.profile)
        return
    end

    if cacheEntry and cacheEntry.loading then
        cacheEntry.callbacks[#cacheEntry.callbacks + 1] = callback
        return
    end

    cacheEntry = { loading = true, callbacks = { callback } }
    minecraftProfileCache[cacheKey] = cacheEntry

    local lookupBase = C.minecraft_profile_lookup_endpoint or "https://api.mojang.com/users/profiles/minecraft"
    local textureBase = C.minecraft_profile_textures_endpoint or "https://sessionserver.mojang.com/session/minecraft/profile"

    http.Fetch(lookupBase .. "/" .. safeName, function(body)
        local lookup = util.JSONToTable(body or "")
        local uuidBytes = lookup and P.writeUUIDString(lookup.id)
        local uuid = lookup and P.formatUUID(lookup.id)
        if not uuidBytes or not uuid then
            completeMinecraftProfileRequest(cacheEntry, nil)
            return
        end

        http.Fetch(textureBase .. "/" .. tostring(lookup.id) .. "?unsigned=false", function(profileBody)
            local decoded = util.JSONToTable(profileBody or "")
            local textures
            for _, property in ipairs((decoded and decoded.properties) or {}) do
                if property.name == "textures" and property.value and property.signature then
                    textures = {
                        name = "textures",
                        value = property.value,
                        signature = property.signature
                    }
                    break
                end
            end

            completeMinecraftProfileRequest(cacheEntry, {
                uuid = uuid,
                uuidBytes = uuidBytes,
                properties = textures and { textures } or {}
            })
        end, function(err)
            log("failed to fetch Minecraft textures for " .. safeName .. ": " .. tostring(err))
            completeMinecraftProfileRequest(cacheEntry, {
                uuid = uuid,
                uuidBytes = uuidBytes,
                properties = {}
            })
        end)
    end, function(err)
        log("failed to look up Minecraft profile for " .. safeName .. ": " .. tostring(err))
        completeMinecraftProfileRequest(cacheEntry, nil)
    end)
end

local function sendTabListHeader(client)
    sendPacket(client, 0x4A,
        chatJson("MC+GM Bridge") ..
        chatJson("[MC] Minecraft  |  [GMod] Garry's Mod")
    )
end

local function sendPlayerListAdd(client, uuidBytes, name, displayName, ping, properties)
    sendPacket(client, 0x2E,
        P.writeVarInt(0) ..
        P.writeVarInt(1) ..
        uuidBytes ..
        P.writeString(name) ..
        writeProfileProperties(properties) ..
        P.writeVarInt(1) ..
        P.writeVarInt(ping or 0) ..
        P.writeBool(true) ..
        chatJson(displayName or name)
    )
end

local function sendPlayerListRemove(client, uuidBytes)
    sendPacket(client, 0x2E,
        P.writeVarInt(4) ..
        P.writeVarInt(1) ..
        uuidBytes
    )
end

local function sendDestroyEntity(client, entityId)
    sendPacket(client, 0x32,
        P.writeVarInt(1) ..
        P.writeVarInt(entityId)
    )
end

local function addGmodPlayerToMinecraftList(client, ply)
    if not IsValid(ply) then return end
    sendPlayerListAdd(
        client,
        P.writeUUIDBytes(100000 + ply:EntIndex()),
        shortPlayerName("GM_", ply:Nick()),
        "[GMod] " .. ply:Nick(),
        math.floor(ply:Ping() or 0)
    )
end

local function addMinecraftPlayerToList(client, other)
    if not other or not other.username then return end
    if other == client then return end
    local profile = other.minecraftProfile
    sendPlayerListAdd(
        client,
        profileUuidBytes(profile, other.entityId),
        other.username,
        "[MC] " .. other.username,
        0,
        profile and profile.properties
    )
end

local function addMinecraftSelfToList(client)
    if not client or not client.username then return end
    local profile = client.minecraftProfile
    sendPlayerListAdd(
        client,
        profileUuidBytes(profile, client.entityId),
        client.username,
        client.username,
        0,
        profile and profile.properties
    )
end

local function minecraftPlayerAngle(degrees)
    return minecraftAngle(tonumber(degrees) or 0)
end

local function sendMinecraftPlayerSpawn(client, other)
    if not C.enable_minecraft_player_visibility then return end
    if not client or not other or client == other then return end
    if client.state ~= STATE_PLAY or other.state ~= STATE_PLAY then return end
    if not other.username or not other.mcPos then return end

    client.spawnedMinecraftEntities = client.spawnedMinecraftEntities or {}
    if client.spawnedMinecraftEntities[other.entityId] then return end

    addMinecraftPlayerToList(client, other)

    sendPacket(client, 0x05,
        P.writeVarInt(other.entityId) ..
        profileUuidBytes(other.minecraftProfile, other.entityId) ..
        P.writeDouble(other.mcPos.x) ..
        P.writeDouble(other.mcPos.y) ..
        P.writeDouble(other.mcPos.z) ..
        string.char(minecraftPlayerAngle(other.yaw)) ..
        string.char(minecraftPlayerAngle(other.pitch)) ..
        minecraftPlayerMetadata(other)
    )

    sendPacket(client, 0x36,
        P.writeVarInt(other.entityId) ..
        string.char(minecraftPlayerAngle(other.yaw))
    )
    sendMinecraftPlayerMetadata(client, other)

    client.spawnedMinecraftEntities[other.entityId] = true
end

local function scheduleMinecraftPlayerSpawn(client, other)
    if not C.enable_minecraft_player_visibility then return end
    if not client or not other or client == other then return end
    if client.state ~= STATE_PLAY or other.state ~= STATE_PLAY then return end

    client.spawnedMinecraftEntities = client.spawnedMinecraftEntities or {}
    client.pendingMinecraftSpawns = client.pendingMinecraftSpawns or {}
    if client.spawnedMinecraftEntities[other.entityId] or client.pendingMinecraftSpawns[other.entityId] then return end

    client.pendingMinecraftSpawns[other.entityId] = true
    addMinecraftPlayerToList(client, other)

    timer.Simple(C.minecraft_player_spawn_delay or 0.15, function()
        if client and client.pendingMinecraftSpawns then
            client.pendingMinecraftSpawns[other.entityId] = nil
        end
        sendMinecraftPlayerSpawn(client, other)
    end)
end

local function sendMinecraftPlayerTeleport(client, other)
    if not C.enable_minecraft_player_visibility then return end
    if not client or not other or client == other then return end
    if client.state ~= STATE_PLAY or other.state ~= STATE_PLAY then return end
    if not other.mcPos then return end

    if not client.spawnedMinecraftEntities or not client.spawnedMinecraftEntities[other.entityId] then
        scheduleMinecraftPlayerSpawn(client, other)
        return
    end

    local yaw = minecraftPlayerAngle(other.yaw)
    local pitch = minecraftPlayerAngle(other.pitch)

    sendPacket(client, 0x4C,
        P.writeVarInt(other.entityId) ..
        P.writeDouble(other.mcPos.x) ..
        P.writeDouble(other.mcPos.y) ..
        P.writeDouble(other.mcPos.z) ..
        string.char(yaw) ..
        string.char(pitch) ..
        P.writeBool(other.onGround)
    )

    sendPacket(client, 0x36,
        P.writeVarInt(other.entityId) ..
        string.char(yaw)
    )
end

local function removeMinecraftPlayerFromViewer(client, other)
    if not client or not other or client == other then return end
    if client.state ~= STATE_PLAY then return end

    if client.spawnedMinecraftEntities then
        client.spawnedMinecraftEntities[other.entityId] = nil
    end
    if client.pendingMinecraftSpawns then
        client.pendingMinecraftSpawns[other.entityId] = nil
    end

    sendDestroyEntity(client, other.entityId)
    sendPlayerListRemove(client, P.writeUUIDBytes(other.entityId))
    local profileBytes = profileUuidBytes(other.minecraftProfile, other.entityId)
    if profileBytes ~= P.writeUUIDBytes(other.entityId) then
        sendPlayerListRemove(client, profileBytes)
    end
end

refreshMinecraftPlayerForViewers = function(respawnedClient)
    if not C.enable_minecraft_player_visibility then return end
    if not respawnedClient or respawnedClient.state ~= STATE_PLAY then return end

    for _, viewer in pairs(clients) do
        if viewer.state == STATE_PLAY and viewer ~= respawnedClient then
            removeMinecraftPlayerFromViewer(viewer, respawnedClient)
            scheduleMinecraftPlayerSpawn(viewer, respawnedClient)
        end
    end
end

local function nearestGmodPlayer(client, range)
    if not client.gmodPos then return nil end

    local best
    local bestDist = (range or C.minecraft_command_range) ^ 2
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() then
            local dist = ply:GetPos():DistToSqr(client.gmodPos)
            if dist <= bestDist then
                best = ply
                bestDist = dist
            end
        end
    end

    return best
end

local function damageGmodPlayerFromMinecraft(client, ply, amount, force)
    if not IsValid(ply) then return false end

    local dmg = DamageInfo()
    dmg:SetDamage(amount)
    dmg:SetDamageType(DMG_CLUB)
    dmg:SetAttacker(IsValid(client.proxyEnt) and client.proxyEnt or game.GetWorld())
    dmg:SetInflictor(IsValid(client.proxyEnt) and client.proxyEnt or game.GetWorld())
    if client.gmodPos then
        dmg:SetDamagePosition(client.gmodPos)
        dmg:SetDamageForce((ply:GetPos() - client.gmodPos):GetNormalized() * (force or 250))
    end
    ply:TakeDamageInfo(dmg)
    return true
end

local function selectedMinecraftDamage(client)
    if client.selectedHotbarSlot == 1 then
        return C.minecraft_bow_damage, C.minecraft_blast_force
    end

    return C.minecraft_sword_damage or C.minecraft_crowbar_damage, 350
end

local function fireMinecraftBow(client)
    if not client or not client.gmodPos or client.deadInMinecraft then return false end

    local startPos = client.gmodPos + Vector(0, 0, 56)
    local dir = minecraftLookVector(client.yaw or 0, client.pitch or 0)
    local endPos = startPos + dir * (C.minecraft_command_range or 512)
    local bestTarget
    local bestDist = 48

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() then
            local dist = distanceToSegment(ply:WorldSpaceCenter(), startPos, endPos)
            if dist < bestDist then
                bestDist = dist
                bestTarget = ply
            end
        end
    end

    if IsValid(bestTarget) then
        damageGmodPlayerFromMinecraft(client, bestTarget, C.minecraft_bow_damage, C.minecraft_blast_force)
        PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. " shot " .. bestTarget:Nick())
        return true
    end

    return false
end

local function minecraftCommand(client, message)
    local command = string.lower(string.Trim(message or ""))

    if command == "/crowbar" then
        local target = nearestGmodPlayer(client, C.minecraft_command_range)
        if damageGmodPlayerFromMinecraft(client, target, C.minecraft_crowbar_damage, 250) then
            sendSystemChat(client, "Crowbar hit " .. target:Nick())
            PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. " crowbarred " .. target:Nick())
        else
            sendSystemChat(client, "No GMod player close enough to crowbar.")
        end
        return true
    end

    if command == "/blast" then
        local hit = false
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) and ply:Alive() and client.gmodPos and ply:GetPos():DistToSqr(client.gmodPos) <= C.minecraft_command_range ^ 2 then
                damageGmodPlayerFromMinecraft(client, ply, C.minecraft_blast_damage, C.minecraft_blast_force)
                hit = true
            end
        end

        if client.gmodPos then
            for _, ent in ipairs(ents.FindInSphere(client.gmodPos, C.minecraft_command_range * 0.75)) do
                local phys = IsValid(ent) and ent:GetPhysicsObject()
                if IsValid(phys) and not isSharedPlatform(ent) then
                    phys:ApplyForceCenter((ent:GetPos() - client.gmodPos):GetNormalized() * C.minecraft_blast_force * phys:GetMass())
                    hit = true
                end
            end
        end

        sendSystemChat(client, hit and "Blast fired into GMod." or "Blast fizzled. Nothing nearby.")
        PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. " used /blast")
        return true
    end

    if command == "/where" then
        if client.gmodPos then
            sendSystemChat(client, "GMod proxy at " .. tostring(client.gmodPos))
        else
            sendSystemChat(client, "No proxy position yet.")
        end
        return true
    end

    if command == "/proxy" then
        if client.mcPos then
            setMinecraftClientPosition(client, client.mcPos.x, client.mcPos.y, client.mcPos.z, client.yaw, client.pitch)
            sendSystemChat(client, "Proxy refreshed.")
        end
        return true
    end

    if command == "/break" then
        if client.mcPos then
            local x = math.floor(client.mcPos.x)
            local y = math.floor(client.mcPos.y - 1)
            local z = math.floor(client.mcPos.z)
            setWorldBlock(x, y, z, 0, true)
            sendBlockChange(client, x, y, z, 0)
            sendSystemChat(client, "Removed block under you.")
            log((client.username or "MC") .. " used /break at " .. x .. "," .. y .. "," .. z)
        end
        return true
    end

    if command == "/debugblocks" then
        sendSystemChat(client, "Stored blocks: " .. table.Count(worldBlocks) .. ", GMod block ents: " .. table.Count(minecraftBlockEnts))
        return true
    end

    if command == "/resetworld" or command == "/resetblocks" then
        resetBridgeWorldBlocks()
        sendChat(client, "Bridge world reset. Stored blocks cleared.")
        PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. " reset the bridge world")
        return true
    end

    if command == "/rebuildblocks" then
        rebuildMinecraftBlockEnts()
        sendSystemChat(client, "Rebuilt GMod block ents: " .. table.Count(minecraftBlockEnts))
        return true
    end

    if command == "/testblock" then
        setWorldBlock(C.minecraft_spawn.x, C.minecraft_spawn.y, C.minecraft_spawn.z, C.minecraft_build_block_state, true)
        sendSystemChat(client, "Spawned a test GMod block at bridge origin.")
        return true
    end

    if command == "/sync" then
        if sendBridgeArenaBlocks then
            sendBridgeArenaBlocks(client)
        end
        return true
    end

    if command == "/help" then
        sendChat(client, "Bridge commands: /crowbar, /blast, /where, /proxy, /sync, /break, /debugblocks, /resetworld, /rebuildblocks, /testblock")
        return true
    end

    return false
end

local function spawnGmodPlayerOnBridge(ply)
    if not C.force_gmod_spawn_to_bridge or not IsValid(ply) then return end

    timer.Simple(0, function()
        if IsValid(ply) then
            local startPos = C.gmod_origin + Vector(0, 0, C.gmod_spawn_trace_height)
            local endPos = C.gmod_origin - Vector(0, 0, C.gmod_spawn_trace_height)
            local trace = util.TraceLine({
                start = startPos,
                endpos = endPos,
                mask = MASK_PLAYERSOLID
            })

            local pos = C.gmod_origin + C.gmod_spawn_offset
            if trace.Hit then
                pos = trace.HitPos + C.gmod_spawn_offset
            end

            ply:SetMoveType(MOVETYPE_WALK)
            ply:Freeze(false)
            ply:SetVelocity(-ply:GetVelocity())
            ply:SetPos(pos)
            ply:SetEyeAngles(Angle(0, 0, 0))
        end
    end)
end

local function createSharedPlatform()
    if not C.shared_platform_enabled then return end
    if #sharedPlatform > 0 then return end

    local tiles = C.shared_platform_tiles or 3
    local tileSize = C.shared_platform_tile_size or 384
    local half = math.floor(tiles / 2)

    for x = -half, half do
        for y = -half, half do
            local ent = ents.Create("prop_physics")
            if IsValid(ent) then
                ent:SetModel(C.shared_platform_model)
                ent:SetPos(C.gmod_origin + Vector(x * tileSize, y * tileSize, C.shared_platform_z or 0))
                ent:SetAngles(Angle(0, 0, 0))
                ent:Spawn()
                if C.shared_platform_align_top_to_origin then
                    local surfaceZ = C.gmod_origin.z + (C.shared_platform_surface_z or 0)
                    ent:SetPos(Vector(
                        C.gmod_origin.x + x * tileSize,
                        C.gmod_origin.y + y * tileSize,
                        surfaceZ - ent:OBBMaxs().z
                    ))
                end
                ent:SetSolid(SOLID_VPHYSICS)
                ent:SetCollisionGroup(COLLISION_GROUP_NONE)
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) then
                    phys:SetPos(ent:GetPos())
                    phys:EnableMotion(false)
                end
                sharedPlatform[#sharedPlatform + 1] = ent
            end
        end
    end

    log("spawned shared GMod/Minecraft platform at " .. tostring(C.gmod_origin))
end

local function removeSharedPlatform()
    for _, ent in ipairs(sharedPlatform) do
        if IsValid(ent) then ent:Remove() end
    end
    sharedPlatform = {}
end

isSharedPlatform = function(ent)
    for _, platformEnt in ipairs(sharedPlatform) do
        if platformEnt == ent then return true end
    end
    return false
end

local function isProtectedBridgeEntity(ent)
    return IsValid(ent) and (isSharedPlatform(ent) or ent.MCGM_BlockKey ~= nil)
end

local function samplePlatformBlock(blockX, blockZ)
    if C.always_make_spawn_platform then
        local dx = blockX - C.minecraft_spawn.x
        local dz = blockZ - C.minecraft_spawn.z
        if dx * dx + dz * dz <= C.spawn_platform_radius * C.spawn_platform_radius then
            return C.floor_block_state
        end
    end

    local scale = C.world_scale
    local worldX = C.gmod_origin.x + (blockX + 0.5) * scale
    local worldY = C.gmod_origin.y + (blockZ + 0.5) * scale
    local high = C.gmod_origin.z + C.platform_trace_height
    local low = C.gmod_origin.z - C.platform_trace_height

    local trace = util.TraceLine({
        start = Vector(worldX, worldY, high),
        endpos = Vector(worldX, worldY, low),
        mask = MASK_SOLID_BRUSHONLY
    })

    if trace.Hit then
        return C.floor_block_state
    end

    return 0
end

local function buildChunkSection(chunkX, chunkZ, sectionY)
    local bitsPerBlock = 4
    local longCount = 256
    local longs = {}
    local palette = { 0, C.floor_block_state }
    local paletteLookup = {
        [0] = 0,
        [C.floor_block_state] = 1
    }

    for i = 1, longCount do
        longs[i] = { low = 0, high = 0 }
    end

    local function paletteIndex(state)
        state = tonumber(state) or 0
        if state == 0 then return 0 end

        local found = paletteLookup[state]
        if found then return found end

        if #palette >= 16 then
            log("chunk palette is full; dropping block state " .. tostring(state))
            return 0
        end

        palette[#palette + 1] = state
        paletteLookup[state] = #palette - 1
        return #palette - 1
    end

    local function addToLong(index, offset, value)
        local long = longs[index]
        if offset < 32 then
            long.low = bit.bor(long.low, bit.lshift(value, offset))
        else
            long.high = bit.bor(long.high, bit.lshift(value, offset - 32))
        end
    end

    for y = 0, 15 do
        for z = 0, 15 do
            for x = 0, 15 do
                local blockIndex = y * 256 + z * 16 + x
                local blockX = chunkX * 16 + x
                local blockZ = chunkZ * 16 + z
                local globalY = sectionY * 16 + y
                local state = 0

                if globalY == C.floor_y then
                    state = samplePlatformBlock(blockX, blockZ)
                end

                local stored = getWorldBlock(blockX, globalY, blockZ)
                if stored ~= nil then
                    state = stored
                end

                local bitIndex = blockIndex * bitsPerBlock
                local longIndex = math.floor(bitIndex / 64) + 1
                local bitOffset = bitIndex % 64

                addToLong(longIndex, bitOffset, paletteIndex(state))
            end
        end
    end

    local packed = {}
    for i = 1, longCount do
        packed[i] = P.writeInt(longs[i].high) .. P.writeInt(longs[i].low)
    end

    local blockLight = string.rep("\255", 2048)
    local skyLight = string.rep("\255", 2048)

    local paletteData = { P.writeVarInt(#palette) }
    for _, state in ipairs(palette) do
        paletteData[#paletteData + 1] = P.writeVarInt(state)
    end

    return string.char(bitsPerBlock) ..
        table.concat(paletteData) ..
        P.writeVarInt(longCount) ..
        table.concat(packed) ..
        blockLight ..
        skyLight
end

local function sendPlatformChunk(client, chunkX, chunkZ)
    local biomeData = string.rep("\127", 256)
    local floorSection = math.floor(C.floor_y / 16)
    local radius = C.chunk_section_radius or 1
    local primaryBitMask = 0
    local sections = {}

    for sectionY = math.max(0, floorSection - radius), math.min(15, floorSection + radius) do
        primaryBitMask = bit.bor(primaryBitMask, bit.lshift(1, sectionY))
        sections[#sections + 1] = buildChunkSection(chunkX, chunkZ, sectionY)
    end

    local chunkData = table.concat(sections) .. biomeData

    sendPacket(client, 0x20,
        P.writeInt(chunkX) ..
        P.writeInt(chunkZ) ..
        P.writeBool(true) ..
        P.writeVarInt(primaryBitMask) ..
        P.writeVarInt(#chunkData) ..
        chunkData ..
        P.writeVarInt(0)
    )
end

sendSpawnChunks = function(client)
    local spawn = C.minecraft_spawn
    local chunkX = math.floor(spawn.x / 16)
    local chunkZ = math.floor(spawn.z / 16)

    for x = chunkX - C.spawn_chunk_radius, chunkX + C.spawn_chunk_radius do
        for z = chunkZ - C.spawn_chunk_radius, chunkZ + C.spawn_chunk_radius do
            sendPlatformChunk(client, x, z)
        end
    end
end

local function sendAabbBlocks(client, mins, maxs, state, limit)
    local a = vecToMinecraft(mins)
    local b = vecToMinecraft(maxs)

    local minX = math.floor(math.min(a.x, b.x))
    local maxX = math.floor(math.max(a.x, b.x))
    local minY = math.floor(math.min(a.y, b.y))
    local maxY = math.floor(math.max(a.y, b.y))
    local minZ = math.floor(math.min(a.z, b.z))
    local maxZ = math.floor(math.max(a.z, b.z))
    local count = 0

    for x = minX, maxX do
        for y = minY, maxY do
            for z = minZ, maxZ do
                local edge = x == minX or x == maxX or y == minY or y == maxY or z == minZ or z == maxZ
                if C.hitbox_fill_blocks or edge then
                    sendBlockChange(client, x, y, z, state)
                    count = count + 1
                    if count >= limit then return count end
                end
            end
        end
    end

    return count
end

local function ensureBasePlatformBlocks()
    if not C.enable_persistent_platform_blocks then return end

    local radius = C.spawn_platform_radius
    local added = 0

    for x = C.minecraft_spawn.x - radius, C.minecraft_spawn.x + radius do
        for z = C.minecraft_spawn.z - radius, C.minecraft_spawn.z + radius do
            local dx = x - C.minecraft_spawn.x
            local dz = z - C.minecraft_spawn.z
            if dx * dx + dz * dz <= radius * radius then
                local key = blockKey(x, C.floor_y, z)
                if worldBlocks[key] ~= C.floor_block_state then
                    worldBlocks[key] = C.floor_block_state
                    added = added + 1
                end
            end
        end
    end

    if added > 0 then
        saveWorldStorage()
        log("created " .. added .. " persistent platform blocks")
    end
end

sendBridgeArenaBlocks = function(client)
    local radius = C.spawn_platform_radius
    local sent = 0

    ensureBasePlatformBlocks()

    for x = C.minecraft_spawn.x - radius, C.minecraft_spawn.x + radius do
        for z = C.minecraft_spawn.z - radius, C.minecraft_spawn.z + radius do
            local dx = x - C.minecraft_spawn.x
            local dz = z - C.minecraft_spawn.z
            if dx * dx + dz * dz <= radius * radius then
                sendBlockChange(client, x, C.floor_y, z, C.floor_block_state)
                sent = sent + 1
            end
        end
    end

    replayWorldBlocks(client, false, C.max_initial_block_replay)

    for _, ent in ipairs(sharedPlatform) do
        if IsValid(ent) then
            local mins, maxs = ent:WorldSpaceAABB()
            sendAabbBlocks(client, mins, maxs, C.hitbox_block_state, C.max_hitbox_blocks_per_entity)
        end
    end

    sendSystemChat(client, "Bridge arena synced: " .. sent .. " platform blocks.")
end

minecraftAngle = function(degrees)
    return math.floor((degrees % 360) * 256 / 360)
end

local function gmodEyeYawToMinecraft(yaw)
    return minecraftAngle((tonumber(yaw) or 0) - 90)
end

local function sendGmodPlayerSpawn(client, ply)
    if not IsValid(ply) then return end

    local pos = vecToMinecraft(ply:GetPos())
    pos.y = pos.y + (C.gmod_player_minecraft_y_offset or 0)
    local angles = ply:EyeAngles()
    local yaw = gmodEyeYawToMinecraft(angles.y)
    local pitch = minecraftAngle(angles.p)

    if C.gmod_minecraft_entity_mode == "mob" then
        sendPacket(client, 0x03,
            P.writeVarInt(ply:EntIndex()) ..
            P.writeUUIDBytes(100000 + ply:EntIndex()) ..
            P.writeVarInt(C.gmod_minecraft_entity_type or 54) ..
            P.writeDouble(pos.x) ..
            P.writeDouble(pos.y) ..
            P.writeDouble(pos.z) ..
            string.char(yaw) ..
            string.char(pitch) ..
            string.char(yaw) ..
            P.writeShort(0) ..
            P.writeShort(0) ..
            P.writeShort(0) ..
            "\255"
        )
    else
        sendPacket(client, 0x05,
            P.writeVarInt(ply:EntIndex()) ..
            P.writeUUIDBytes(100000 + ply:EntIndex()) ..
            P.writeDouble(pos.x) ..
            P.writeDouble(pos.y) ..
            P.writeDouble(pos.z) ..
            string.char(yaw) ..
            string.char(pitch) ..
            "\255"
        )
    end

    sendPacket(client, 0x36,
        P.writeVarInt(ply:EntIndex()) ..
        string.char(yaw)
    )
end

local function scheduleGmodPlayerSpawn(client, ply)
    if not client or client.dead or client.state ~= STATE_PLAY or not IsValid(ply) then return end

    local entIndex = ply:EntIndex()
    client.pendingGmodSpawns = client.pendingGmodSpawns or {}
    if client.spawnedGmodEntities[entIndex] or client.pendingGmodSpawns[entIndex] then return end
    client.pendingGmodSpawns[entIndex] = true

    addGmodPlayerToMinecraftList(client, ply)

    timer.Simple(C.gmod_player_spawn_delay or 0.25, function()
        if client and client.pendingGmodSpawns then
            client.pendingGmodSpawns[entIndex] = nil
        end
        if not client or client.dead or client.state ~= STATE_PLAY or not IsValid(ply) then return end
        sendGmodPlayerSpawn(client, ply)
        sendGmodPlayerEquipment(client, ply, true)
        client.spawnedGmodEntities[entIndex] = true
    end)
end

local function weaponClassToMinecraftItem(class)
    class = string.lower(tostring(class or ""))
    if class == "" then return -1 end
    if class == "weapon_crowbar" then return ITEM_IRON_SWORD end

    if class == "weapon_physgun" or
        class == "weapon_physcannon" or
        class == "gmod_tool" or
        class == "gmod_camera" or
        class == "weapon_fists" then
        return -1
    end

    if string.find(class, "pistol", 1, true) or
        string.find(class, "smg", 1, true) or
        string.find(class, "ar2", 1, true) or
        string.find(class, "shotgun", 1, true) or
        string.find(class, "crossbow", 1, true) or
        string.find(class, "rpg", 1, true) or
        string.find(class, "rifle", 1, true) or
        string.find(class, "gun", 1, true) then
        return ITEM_BOW
    end

    if string.sub(class, 1, 7) == "weapon_" then
        return ITEM_BOW
    end

    return -1
end

local function getGmodPlayerEquipmentItem(ply)
    if not IsValid(ply) then return -1 end

    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) then return -1 end

    return weaponClassToMinecraftItem(weapon:GetClass())
end

sendGmodPlayerEquipment = function(client, ply, force)
    if not C.enable_gmod_equipment_sync or not IsValid(ply) then return end

    client.gmodEquipment = client.gmodEquipment or {}

    local entityId = ply:EntIndex()
    local itemId = getGmodPlayerEquipmentItem(ply)
    if not force and client.gmodEquipment[entityId] == itemId then return end

    client.gmodEquipment[entityId] = itemId
    sendPacket(client, 0x3F,
        P.writeVarInt(entityId) ..
        P.writeVarInt(0) ..
        P.writeSlot(itemId, 1, 0)
    )
end

local function sendGmodPlayerTeleport(client, ply)
    if not IsValid(ply) then return end

    local pos = vecToMinecraft(ply:GetPos())
    pos.y = pos.y + (C.gmod_player_minecraft_y_offset or 0)
    local angles = ply:EyeAngles()
    local yaw = gmodEyeYawToMinecraft(angles.y)
    local pitch = minecraftAngle(angles.p)

    sendPacket(client, 0x4C,
        P.writeVarInt(ply:EntIndex()) ..
        P.writeDouble(pos.x) ..
        P.writeDouble(pos.y) ..
        P.writeDouble(pos.z) ..
        string.char(yaw) ..
        string.char(pitch) ..
        P.writeBool(ply:IsOnGround())
    )

    sendPacket(client, 0x36,
        P.writeVarInt(ply:EntIndex()) ..
        string.char(yaw)
    )
end

sendGmodPlayersToMinecraft = function(client)
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            scheduleGmodPlayerSpawn(client, ply)
        end
    end
end

local function sendMinecraftPlayersToList(client)
    for _, other in pairs(clients) do
        if other.state == STATE_PLAY and other ~= client then
            addMinecraftPlayerToList(client, other)
        end
    end
end

sendMinecraftPlayersToMinecraft = function(client)
    if not C.enable_minecraft_player_visibility then return end
    if not client or client.state ~= STATE_PLAY then return end

    for _, other in pairs(clients) do
        if other.state == STATE_PLAY and other ~= client then
            scheduleMinecraftPlayerSpawn(client, other)
        end
    end
end

local function sendJoinGame(client)
    local spawn = C.minecraft_spawn

    log("sending minimal join game to " .. tostring(client.username or client.entityId))

    sendPacket(client, 0x23,
        P.writeInt(client.entityId) ..
        string.char(1) ..
        P.writeInt(0) ..
        string.char(1) ..
        string.char(C.max_players) ..
        P.writeString("flat") ..
        P.writeBool(false)
    )

    sendPacket(client, 0x46, P.writePosition(spawn.x, spawn.y, spawn.z))
    if C.send_chunks_on_login then
        sendSpawnChunks(client)
    end
    sendMinecraftAbilities(client, true)
    sendMinecraftMaxHealth(client)
    sendMinecraftHealth(client)
    sendMinecraftCombatHotbar(client)

    sendPacket(client, 0x2F,
        P.writeDouble(spawn.x + 0.5) ..
        P.writeDouble(spawn.y) ..
        P.writeDouble(spawn.z + 0.5) ..
        P.writeFloat(0) ..
        P.writeFloat(0) ..
        string.char(0) ..
        P.writeVarInt(1)
    )
    sendMinecraftSelfMetadata(client)
end

sendDeferredWorldSync = function(client)
    if not client or client.dead or client.state ~= STATE_PLAY then return end

    log("sending deferred world sync to " .. tostring(client.username or client.entityId))
    sendTabListHeader(client)
    addMinecraftSelfToList(client)
    sendMinecraftSelfMetadata(client)
    sendMinecraftPlayersToList(client)
    sendMinecraftPlayersToMinecraft(client)
    sendGmodPlayersToMinecraft(client)
    if C.send_blocks_on_login then
        sendBridgeArenaBlocks(client)
    end
    sendSystemChat(client, "Connected to the GMod bridge..")
end

local function handleStatus(client, packet)
    if packet.id == 0x00 then
        local online = 0
        for _, c in pairs(clients) do
            if c.state == STATE_PLAY then online = online + 1 end
        end

        local status = "{"
            .. "\"version\":{\"name\":\"" .. P.jsonString(C.minecraft_version) .. "\",\"protocol\":" .. C.protocol_version .. "},"
            .. "\"players\":{\"max\":" .. C.max_players .. ",\"online\":" .. online .. "},"
            .. "\"description\":{\"text\":\"" .. P.jsonString(C.motd) .. "\"}"
            .. "}"

        sendPacket(client, 0x00, P.writeString(status))
    elseif packet.id == 0x01 then
        sendPacket(client, 0x01, packet.payload)
    end
end

local function handleUseEntity(client, packet)
    local targetId, offset = P.readVarInt(packet.payload, 1)
    local action
    action, offset = P.readVarInt(packet.payload, offset)

    if action ~= 1 then return end

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:EntIndex() == targetId then
            local damage, force = selectedMinecraftDamage(client)
            if damageGmodPlayerFromMinecraft(client, ply, damage, force) then
                sendSystemChat(client, "You hit " .. ply:Nick())
            end
            return
        end
    end
end

local function handleClientSettings(client, packet)
    local offset = 1
    client.locale, offset = P.readString(packet.payload, offset)
    if not client.locale then return end
    client.viewDistance, offset = P.readByte(packet.payload, offset)
    if not client.viewDistance then return end
    client.chatMode, offset = P.readVarInt(packet.payload, offset)
    if not client.chatMode then return end
    local chatColors
    chatColors, offset = P.readByte(packet.payload, offset)
    if not chatColors then return end
    client.chatColors = chatColors == 1
    client.skinParts, offset = P.readByte(packet.payload, offset)
    if not client.skinParts then return end
    client.mainHand = P.readVarInt(packet.payload, offset)

    if client.state == STATE_PLAY then
        refreshMinecraftPlayerForViewers(client)
    end
end

local function blockFaceOffset(face)
    if face == 0 then return 0, -1, 0 end
    if face == 1 then return 0, 1, 0 end
    if face == 2 then return 0, 0, -1 end
    if face == 3 then return 0, 0, 1 end
    if face == 4 then return -1, 0, 0 end
    if face == 5 then return 1, 0, 0 end
    return 0, 1, 0
end

local function handleDigging(client, packet)
    local status, offset = P.readVarInt(packet.payload, 1)
    if status == 5 and client.selectedHotbarSlot == 1 then
        fireMinecraftBow(client)
        return
    end

    if not C.enable_minecraft_block_building then return end

    local pos
    pos, offset = P.readPosition(packet.payload, offset)
    if not pos then
        log((client.username or "MC") .. " sent dig packet but position decode failed")
        return
    end

    if C.debug_block_packets then
        log((client.username or "MC") .. " dig status=" .. tostring(status) .. " pos=" .. pos.x .. "," .. pos.y .. "," .. pos.z)
    end

    -- Treat start, finish, and creative-pick/drop variants as a completed break.
    -- The bridge world is server-authoritative, so this keeps cracked/offline
    -- clients from getting stuck waiting on vanilla mining state.
    if status == 0 or status == 2 or status == 3 or status == 4 then
        setWorldBlock(pos.x, pos.y, pos.z, 0, true)
        sendBlockChange(client, pos.x, pos.y, pos.z, 0)
        log((client.username or "MC") .. " removed bridge block at " .. pos.x .. "," .. pos.y .. "," .. pos.z)
    end
end

local function handleBlockPlacement(client, packet)
    if not C.enable_minecraft_block_building then return end

    local pos, offset = P.readPosition(packet.payload, 1)
    if not pos then
        log((client.username or "MC") .. " sent place packet but  position decode failed")
        return
    end

    local face
    face, offset = P.readVarInt(packet.payload, offset)
    local dx, dy, dz = blockFaceOffset(face)
    local x = pos.x + dx
    local y = pos.y + dy
    local z = pos.z + dz

    local state = selectedMinecraftBuildState(client)
    setWorldBlock(x, y, z, state, true)
    if C.debug_block_packets then
        log((client.username or "MC") .. " place face=" .. tostring(face) .. " base=" .. pos.x .. "," .. pos.y .. "," .. pos.z)
    end
    log((client.username or "MC") .. " placed bridge its called this not because its vibe coded because the oigonal block i used was not a real minecraft block and one i custom made therefore i called it bridge block this is the idiot which called my work vibecodes fault for this rant in my code block state=" .. tostring(state) .. " at " .. x .. "," .. y .. "," .. z)
end

local function handleHandshake(client, packet)
    if packet.id ~= 0x00 then return end

    local offset = packet.offset
    client.protocol, offset = P.readVarInt(packet.data, offset)
    client.host, offset = P.readString(packet.data, offset)
    client.port, offset = P.readUnsignedShort(packet.data, offset)
    client.nextState, offset = P.readVarInt(packet.data, offset)
    client.state = client.nextState == 1 and STATE_STATUS or STATE_LOGIN
end

local function sanitizeMinecraftUsername(username, entityId)
    username = tostring(username or ("mc_" .. tostring(entityId or 0)))
    username = string.sub(string.gsub(username, "[^%w_]", ""), 1, 16)
    if username == "" then username = "mc_" .. tostring(entityId or 0) end
    return username
end

local function disconnectLogin(client, reason)
    if not client then return end
    sendPacket(client, 0x00, chatJson(tostring(reason or "Disconnected")))
    client.dead = true
end

local function finishMinecraftLogin(client, username, profile, authMode)
    client.username = username
    client.minecraftProfile = profile
    client.state = STATE_PLAY
    client.gmodPos = minecraftToVec(client.mcPos)
    client.mcHealth = C.minecraft_proxy_health
    client.deadInMinecraft = false
    client.selectedHotbarSlot = 0
    updateMinecraftProxy(client)

    if profile and profile.properties and #profile.properties > 0 then
        log("loaded signed Minecraft textures for " .. username)
    end

    local loginUuid = profileUuidString(profile) or P.writeUUID()
    sendPacket(client, 0x02, P.writeString(loginUuid) .. P.writeString(username))
    sendJoinGame(client)
    timer.Simple(C.defer_world_sync_after_login or 1, function()
        sendDeferredWorldSync(client)
    end)

    PrintMessage(HUD_PRINTTALK, "[MC] " .. username .. " joined through the bridge")
    for _, other in pairs(clients) do
        if other.state == STATE_PLAY and other ~= client then
            addMinecraftPlayerToList(other, client)
            scheduleMinecraftPlayerSpawn(other, client)
        end
    end
    broadcastChat("[MC] " .. username .. " joined the bridge")
    log(username .. " logged in in " .. tostring(authMode or "offline") .. " mode")
end

local function beginOfflineMinecraftLogin(client, username)
    client.username = username

    local finished = false
    local function finish(profile)
        if finished then
            if profile and client and not client.dead and client.state == STATE_PLAY and client.username == username then
                client.minecraftProfile = profile
                log("loaded signed Minecraft textures for " .. username .. " after login")
                sendPlayerListRemove(client, P.writeUUIDBytes(client.entityId))
                sendPlayerListRemove(client, profileUuidBytes(profile, client.entityId))
                addMinecraftSelfToList(client)
                refreshMinecraftPlayerForViewers(client)
            end
            return
        end
        if not client or client.dead then return end
        if C.require_minecraft_profile and not profile then
            disconnectLogin(client, "This bridge requires a real Minecraft profile for skins/capes. Use your exact Java username.")
            log("rejected " .. username .. " because no Mojang profile was found")
            return
        end
        finished = true
        finishMinecraftLogin(client, username, profile, "offline")
    end

    fetchMinecraftProfile(username, finish)

    timer.Simple(C.minecraft_auth_timeout or 5, function()
        if finished or not client or client.dead then return end
        log("Minecraft profile lookup timed out for " .. username .. "; joining without skin/cape")
        finish(nil)
    end)
end

local function beginOnlineMinecraftLogin(client, username)
    client.username = username
    log(username .. " tried to log in with minecraft_online_mode enabled")
    disconnectLogin(client, "Minecraft online-mode auth is enabled in config, but this bridge does not have a crypto/encrypted-socket backend yet. Disable minecraft_online_mode or add RSA/AES auth support.")
end

local function handleLogin(client, packet)
    if packet.id ~= 0x00 then return end

    local username = sanitizeMinecraftUsername(P.readString(packet.payload, 1), client.entityId)

    if C.minecraft_online_mode then
        beginOnlineMinecraftLogin(client, username)
        return
    end

    beginOfflineMinecraftLogin(client, username)
end

local function handlePlay(client, packet)
    if packet.id == 0x02 then
        local message = P.readString(packet.payload, 1)
        if message and message ~= "" then
            if minecraftCommand(client, message) then return end
            PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. ": " .. message)
            broadcastChat("[MC] <" .. client.username .. "> " .. message)
        end
    elseif packet.id == 0x03 then
        local action = P.readVarInt(packet.payload, 1)
        if C.debug_combat then
            log((client.username or "MC") .. " sent client status action=" .. tostring(action) .. " dead=" .. tostring(client.deadInMinecraft))
        end
        if action == 0 and (client.deadInMinecraft or (client.mcHealth or C.minecraft_proxy_health) <= 0) then
            respawnMinecraftClient(client)
        end
    elseif packet.id == 0x04 then
        handleClientSettings(client, packet)
    elseif packet.id == 0x0A then
        handleUseEntity(client, packet)
    elseif packet.id == 0x0B then
        return
    elseif packet.id == 0x0C then
        client.onGround = P.readByte(packet.payload, 1) == 1
    elseif packet.id == 0x0D then
        local offset = 1
        local x, y, z
        x, offset = P.readDouble(packet.payload, offset)
        y, offset = P.readDouble(packet.payload, offset)
        z, offset = P.readDouble(packet.payload, offset)
        client.onGround = P.readByte(packet.payload, offset) == 1
        setMinecraftClientPosition(client, x, y, z, client.yaw, client.pitch)
    elseif packet.id == 0x0E then
        local offset = 1
        local x, y, z
        x, offset = P.readDouble(packet.payload, offset)
        y, offset = P.readDouble(packet.payload, offset)
        z, offset = P.readDouble(packet.payload, offset)
        client.yaw, offset = P.readFloat(packet.payload, offset)
        client.pitch, offset = P.readFloat(packet.payload, offset)
        client.onGround = P.readByte(packet.payload, offset) == 1
        setMinecraftClientPosition(client, x, y, z, client.yaw, client.pitch)
    elseif packet.id == 0x0F then
        local offset = 1
        client.yaw, offset = P.readFloat(packet.payload, offset)
        client.pitch, offset = P.readFloat(packet.payload, offset)
        client.onGround = P.readByte(packet.payload, offset) == 1
        if client.mcPos then
            setMinecraftClientPosition(client, client.mcPos.x, client.mcPos.y, client.mcPos.z, client.yaw, client.pitch)
        else
            updateMinecraftProxy(client)
        end
    elseif packet.id == 0x14 then
        handleDigging(client, packet)
    elseif packet.id == 0x1A then
        local slot = P.readShort and P.readShort(packet.payload, 1) or nil
        if not slot then
            local a, b = string.byte(packet.payload, 1, 2)
            if a and b then
                slot = a * 256 + b
                if slot >= 0x8000 then slot = slot - 0x10000 end
            end
        end
        if slot and slot >= 0 and slot <= 8 then
            client.selectedHotbarSlot = slot
        end
    elseif packet.id == 0x1F then
        handleBlockPlacement(client, packet)
    elseif C.debug_minecraft_movement and (packet.id >= 0x0B and packet.id <= 0x10) then
        if not client.nextUnhandledMoveLog or CurTime() >= client.nextUnhandledMoveLog then
            client.nextUnhandledMoveLog = CurTime() + 1
            log((client.username or "MC") .. " unhandled movement-ish packet 0x" .. string.format("%02X", packet.id))
        end
    end
end

local function handlePacket(client, packet)
    if client.state == STATE_HANDSHAKE then
        handleHandshake(client, packet)
    elseif client.state == STATE_STATUS then
        handleStatus(client, packet)
    elseif client.state == STATE_LOGIN then
        handleLogin(client, packet)
    elseif client.state == STATE_PLAY then
        handlePlay(client, packet)
    end
end

local function acceptClients()
    while true do
        local sock, err = server:accept()
        if not sock then
            if err ~= "timeout" then break end
            break
        end

        sock:settimeout(0)
        nextEntityId = nextEntityId + 1
        clients[sock] = {
            sock = sock,
            state = STATE_HANDSHAKE,
            buffer = "",
            entityId = nextEntityId,
            lastKeepalive = CurTime(),
            spawnedGmodEntities = {},
            pendingGmodSpawns = {},
            spawnedMinecraftEntities = {},
            pendingMinecraftSpawns = {},
            gmodEquipment = {},
            outBuffer = "",
            mcPos = table.Copy(C.minecraft_spawn)
        }
    end
end

local function pollClients()
    for key, client in pairs(clients) do
        while not client.dead do
            local chunk, err, partial = client.sock:receive(4096)
            chunk = chunk or partial

            if chunk and #chunk > 0 then
                client.buffer = client.buffer .. chunk
                while true do
                    local packet
                    packet, client.buffer = P.tryReadPacket(client.buffer)
                    if not packet then break end
                    local ok, err = pcall(handlePacket, client, packet)
                    if not ok then
                        log("packet handler error for packet 0x" .. string.format("%02X", packet.id or -1) .. ": " .. tostring(err))
                        client.dead = true
                        break
                    end
                end
            end

            if err == "timeout" then break end
            if err == "closed" then client.dead = true break end
            if not chunk then break end
        end

        if client.state == STATE_PLAY and CurTime() - client.lastKeepalive > C.keepalive_interval then
            client.lastKeepalive = CurTime()
            sendPacket(client, 0x1F, P.writeLong())
        end

        flushClientOutput(client)

        if client.dead then
            if client.username then
                PrintMessage(HUD_PRINTTALK, "[MC] " .. client.username .. " disconnected")
                for _, other in pairs(clients) do
                    if other.state == STATE_PLAY and other ~= client then
                        removeMinecraftPlayerFromViewer(other, client)
                    end
                end
                broadcastChat("[MC] " .. client.username .. " left the bridge")
            end
            removeMinecraftProxy(client)
            pcall(function() client.sock:close() end)
            clients[key] = nil
        end
    end
end

local function syncMinecraftPlayers()
    if not C.enable_minecraft_player_visibility then return end

    for _, client in pairs(clients) do
        if client.state == STATE_PLAY then
            for _, other in pairs(clients) do
                if other.state == STATE_PLAY and other ~= client then
                    sendMinecraftPlayerTeleport(client, other)
                end
            end
        end
    end
end

local function syncGmodPlayers()
    if CurTime() - lastPosSync < C.position_sync_interval then return end
    lastPosSync = CurTime()

    syncMinecraftPlayers()

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            local pos = vecToMinecraft(ply:GetPos())

            for _, client in pairs(clients) do
                if client.state == STATE_PLAY then
                    if not client.spawnedGmodEntities[ply:EntIndex()] then
                        scheduleGmodPlayerSpawn(client, ply)
                    end

                    if client.spawnedGmodEntities[ply:EntIndex()] then
                        sendGmodPlayerTeleport(client, ply)
                        sendGmodPlayerEquipment(client, ply, false)
                    end

                    if C.enable_gmod_player_marker_blocks then
                        sendPacket(client, 0x0B,
                            P.writePosition(math.floor(pos.x), C.floor_y + 1, math.floor(pos.z)) ..
                            P.writeVarInt(C.gmod_player_marker_block_state)
                        )
                    end
                end
            end
        end
    end
end

local function projectProps()
    if not C.enable_prop_blocks then return end
    if CurTime() - lastPropScan < C.prop_scan_interval then return end
    lastPropScan = CurTime()

    local count = 0
    for _, ent in ipairs(ents.FindByClass("prop_physics")) do
        if count >= C.max_prop_blocks_per_scan then break end
        if IsValid(ent) and ent:GetPos():DistToSqr(C.gmod_origin) <= C.prop_scan_radius * C.prop_scan_radius then
            local pos = vecToMinecraft(ent:GetPos())
            broadcastPacket(0x0B,
                P.writePosition(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)) ..
                P.writeVarInt(C.prop_block_state)
            )
            count = count + 1
        end
    end
end

local function syncHitboxBlocks()
    if not C.enable_hitbox_blocks then return end
    if CurTime() - lastHitboxSync < C.hitbox_sync_interval then return end
    lastHitboxSync = CurTime()

    local entityCount = 0
    local candidates = {}

    for _, ent in ipairs(sharedPlatform) do
        if IsValid(ent) then
            candidates[#candidates + 1] = ent
        end
    end

    for _, ent in ipairs(ents.FindInSphere(C.gmod_origin, C.hitbox_sync_radius)) do
        if IsValid(ent) and ent:GetClass() == "prop_physics" and not isSharedPlatform(ent) then
            candidates[#candidates + 1] = ent
        end
    end

    for _, ent in ipairs(candidates) do
        if entityCount >= C.max_hitbox_entities_per_scan then break end
        if IsValid(ent) then
            local mins, maxs = ent:WorldSpaceAABB()
            for _, client in pairs(clients) do
                if client.state == STATE_PLAY then
                    sendAabbBlocks(client, mins, maxs, C.hitbox_block_state, C.max_hitbox_blocks_per_entity)
                end
            end
            entityCount = entityCount + 1
        end
    end
end

distanceToSegment = function(point, startPos, endPos)
    local segment = endPos - startPos
    local lenSqr = segment:LengthSqr()
    if lenSqr <= 0 then return point:Distance(startPos) end

    local t = math.Clamp((point - startPos):Dot(segment) / lenSqr, 0, 1)
    return point:Distance(startPos + segment * t)
end

local function damageMinecraftClientsOnSegment(attacker, startPos, endPos, damage, radius)
    local hit = false
    radius = radius or C.minecraft_proxy_hit_radius
    damage = math.max(1, math.floor(tonumber(damage) or 8))

    for _, client in pairs(clients) do
        if client.state == STATE_PLAY and client.gmodPos and not client.deadInMinecraft then
            local targetPos = client.gmodPos + Vector(0, 0, 36)
            local dist = distanceToSegment(targetPos, startPos, endPos)
            if dist <= radius then
                local attackerName = IsValid(attacker) and attacker:IsPlayer() and attacker:Nick() or "GMod"
                damageMinecraftClient(client, damage, attackerName)
                if C.debug_combat then
                    log(attackerName .. " hit " .. tostring(client.username or "MC") .. " for " .. damage .. " hp=" .. tostring(client.mcHealth or 0))
                end
                hit = true
            end
        end
    end

    return hit
end

local function handleGmodBullets(ply, bullet)
    if not IsValid(ply) or not bullet or not bullet.Src or not bullet.Dir then return end

    local startPos = bullet.Src
    local endPos = startPos + bullet.Dir:GetNormalized() * (bullet.Distance or 8192)
    local damage = math.max(1, math.floor(tonumber(bullet.Damage) or 8))

    damageMinecraftClientsOnSegment(ply, startPos, endPos, damage, C.minecraft_proxy_hit_radius)
end

local function handleGmodMelee(ply)
    if not IsValid(ply) or not ply:Alive() then return end

    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) then return end

    local class = string.lower(weapon:GetClass() or "")
    if class == "weapon_physgun" or class == "weapon_physcannon" or class == "gmod_tool" or class == "gmod_camera" then
        return
    end

    local startPos = ply:GetShootPos()
    local endPos = startPos + ply:GetAimVector() * (C.minecraft_proxy_melee_range or 96)
    local damage = class == "weapon_crowbar" and C.minecraft_sword_damage or 10
    damageMinecraftClientsOnSegment(ply, startPos, endPos, damage, C.minecraft_proxy_hit_radius)
end

function MC_GM.Start()
    if server then return end

    local ok, lib = pcall(require, "socket")
    lib = lib or _G.socket
    if not ok or not lib then
        log("LuaSocket is not available: " .. tostring(lib))
        log("Install gmod_luasocket into garrysmod/lua/includes/modules and garrysmod/lua/bin.")
        return
    end

    socketLib = lib
    server = assert(socketLib.bind(C.bind_host or "*", C.port))
    server:settimeout(0)
    loadWorldStorage()
    ensureBasePlatformBlocks()
    rebuildMinecraftBlockEnts()
    createSharedPlatform()
    for _, ply in ipairs(player.GetAll()) do
        enablePlayerBlockCollisionRule(ply)
    end

    timer.Create("MCGM_Tick", C.tick_interval, 0, function()
        if not server then return end
        acceptClients()
        pollClients()
        for _, ply in ipairs(player.GetAll()) do
            applySoftMinecraftBlockCollision(ply)
        end
        syncGmodPlayers()
        projectProps()
        syncHitboxBlocks()
    end)

    hook.Add("PlayerSay", "MCGM_GmodChatToMinecraft", function(ply, text, teamChat)
        if teamChat then return end
        local command = string.lower(string.Trim(text or ""))
        if command == "!block" or command == "/block" then
            if gmodPlaceBridgeBlock(ply) then
                PrintMessage(HUD_PRINTTALK, "[MCGM] " .. ply:Nick() .. " placed a bridge block")
            end
            return ""
        end
        if command == "!breakblock" or command == "/breakblock" then
            if gmodBreakBridgeBlock(ply) then
                PrintMessage(HUD_PRINTTALK, "[MCGM] " .. ply:Nick() .. " broke a bridge block")
            end
            return ""
        end
        if command == "!resetworld" or command == "/resetworld" or command == "!resetblocks" or command == "/resetblocks" then
            if IsValid(ply) and not ply:IsAdmin() then
                PrintMessage(HUD_PRINTTALK, "[MCGM] " .. ply:Nick() .. " tried to reset the bridge world but is not an admin")
                return ""
            end
            resetBridgeWorldBlocks()
            PrintMessage(HUD_PRINTTALK, "[MCGM] " .. ply:Nick() .. " reset the bridge world")
            return ""
        end
        broadcastChat("[GMod] <" .. ply:Nick() .. "> " .. text)
    end)

    hook.Add("PlayerSpawn", "MCGM_SpawnOnBridge", function(ply)
        enablePlayerBlockCollisionRule(ply)
        spawnGmodPlayerOnBridge(ply)
        timer.Simple(0.2, function()
            if not IsValid(ply) then return end
            enablePlayerBlockCollisionRule(ply)
            for _, client in pairs(clients) do
                if client.state == STATE_PLAY then
                    client.spawnedGmodEntities[ply:EntIndex()] = nil
                    if client.pendingGmodSpawns then
                        client.pendingGmodSpawns[ply:EntIndex()] = nil
                    end
                    if client.gmodEquipment then
                        client.gmodEquipment[ply:EntIndex()] = nil
                    end
                    sendDestroyEntity(client, ply:EntIndex())
                    scheduleGmodPlayerSpawn(client, ply)
                end
            end
        end)
    end)

    hook.Add("PlayerInitialSpawn", "MCGM_InitialSpawnOnBridge", function(ply)
        enablePlayerBlockCollisionRule(ply)
        timer.Simple(1, function()
            enablePlayerBlockCollisionRule(ply)
            spawnGmodPlayerOnBridge(ply)
        end)
    end)

    concommand.Add("mcgm_spawn_bridge", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        for _, target in ipairs(player.GetAll()) do
            spawnGmodPlayerOnBridge(target)
        end
        log("moved GMod players to the shared bridge spawn")
    end)

    concommand.Add("mcgm_world_save", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        saveWorldStorage()
        log("saved " .. table.Count(worldBlocks) .. " Minecraft bridge blocks")
    end)

    concommand.Add("mcgm_world_reset", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        resetBridgeWorldBlocks()
    end)

    concommand.Add("mcgm_resetworld", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        resetBridgeWorldBlocks()
    end)

    concommand.Add("mcgm_block_place", function(ply)
        if IsValid(ply) and not ply:Alive() then return end
        if not gmodPlaceBridgeBlock(ply) then
            log("could not place bridge block")
        end
    end)

    concommand.Add("mcgm_block_break", function(ply)
        if IsValid(ply) and not ply:Alive() then return end
        if not gmodBreakBridgeBlock(ply) then
            log("no bridge block in crosshair")
        end
    end)

    concommand.Add("mcgm_block_test_visible", function(ply)
        if not IsValid(ply) then return end
        local pos = vecToMinecraft(ply:GetShootPos() + ply:GetAimVector() * 96)
        setWorldBlock(pos.x, pos.y, pos.z, C.minecraft_build_block_state, true)
        log("spawned test visible bridge block in front of " .. ply:Nick())
    end)

    concommand.Add("mcgm_rebuild_blocks", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        rebuildMinecraftBlockEnts()
        log("rebuilt " .. table.Count(minecraftBlockEnts) .. " GMod block entities")
    end)

    concommand.Add("mcgm_test_block", function(ply)
        if IsValid(ply) and not ply:IsAdmin() then return end
        setWorldBlock(C.minecraft_spawn.x, C.minecraft_spawn.y, C.minecraft_spawn.z, C.minecraft_build_block_state, true)
        log("spawned test Minecraft-origin block at bridge origin")
    end)

    hook.Add("PlayerDisconnected", "MCGM_RemoveGmodPlayerFromMinecraft", function(ply)
        for _, client in pairs(clients) do
            if client.state == STATE_PLAY then
                sendPlayerListRemove(client, P.writeUUIDBytes(100000 + ply:EntIndex()))
                sendDestroyEntity(client, ply:EntIndex())
                client.spawnedGmodEntities[ply:EntIndex()] = nil
                if client.pendingGmodSpawns then
                    client.pendingGmodSpawns[ply:EntIndex()] = nil
                end
                if client.gmodEquipment then
                    client.gmodEquipment[ply:EntIndex()] = nil
                end
            end
        end
    end)

    hook.Add("EntityFireBullets", "MCGM_GmodBulletsHitMinecraft", function(ent, bullet)
        if ent:IsPlayer() then
            handleGmodBullets(ent, bullet)
        end
    end)

    hook.Add("KeyPress", "MCGM_GmodMeleeHitMinecraft", function(ply, key)
        if key == IN_ATTACK then
            handleGmodMelee(ply)
        end
    end)

    hook.Add("EntityTakeDamage", "MCGM_ProxyDamageToMinecraft", function(ent, dmg)
        if IsValid(ent) and ent.MCGM_BlockKey and C.shared_platform_destructible then
            local x, y, z = parseBlockKey(ent.MCGM_BlockKey)
            if x and y and z then
                setWorldBlock(x, y, z, 0, true)
                return true
            end
        end

        if not C.shared_platform_destructible and isProtectedBridgeEntity(ent) then
            dmg:SetDamage(0)
            return true
        end

        local client = proxyOwners[ent]
        if client then
            local attacker = dmg:GetAttacker()
            local name = IsValid(attacker) and attacker:IsPlayer() and attacker:Nick() or "GMod"
            damageMinecraftClient(client, math.max(1, math.floor(dmg:GetDamage())), name)
            return true
        end
    end)

    hook.Add("PhysgunPickup", "MCGM_ProtectBridgePhysgun", function(ply, ent)
        if not C.shared_platform_destructible and isProtectedBridgeEntity(ent) then
            return false
        end
    end)

    hook.Add("GravGunPickupAllowed", "MCGM_ProtectBridgeGravgun", function(ply, ent)
        if not C.shared_platform_destructible and isProtectedBridgeEntity(ent) then
            return false
        end
    end)

    hook.Add("CanTool", "MCGM_ProtectBridgeToolgun", function(ply, tr)
        if tr and not C.shared_platform_destructible and isProtectedBridgeEntity(tr.Entity) then
            return false
        end
    end)

    hook.Add("ShouldCollide", "MCGM_BlockPlayerCollision", function(ent1, ent2)
        if C.minecraft_block_collide_players ~= false then return end
        if not IsValid(ent1) or not IsValid(ent2) then return end

        if ent1:IsPlayer() and ent2.MCGM_BlockKey then return false end
        if ent2:IsPlayer() and ent1.MCGM_BlockKey then return false end
    end)

    log("listening for Minecraft " .. C.minecraft_version .. " backend clients on " .. tostring(C.bind_host or "*") .. ":" .. C.port)
end

function MC_GM.Stop()
    timer.Remove("MCGM_Tick")
    hook.Remove("PlayerSay", "MCGM_GmodChatToMinecraft")
    hook.Remove("PlayerSpawn", "MCGM_SpawnOnBridge")
    hook.Remove("PlayerInitialSpawn", "MCGM_InitialSpawnOnBridge")
    hook.Remove("PlayerDisconnected", "MCGM_RemoveGmodPlayerFromMinecraft")
    concommand.Remove("mcgm_spawn_bridge")
    concommand.Remove("mcgm_world_save")
    concommand.Remove("mcgm_world_reset")
    concommand.Remove("mcgm_resetworld")
    concommand.Remove("mcgm_block_place")
    concommand.Remove("mcgm_block_break")
    concommand.Remove("mcgm_block_test_visible")
    concommand.Remove("mcgm_rebuild_blocks")
    concommand.Remove("mcgm_test_block")
    hook.Remove("EntityFireBullets", "MCGM_GmodBulletsHitMinecraft")
    hook.Remove("KeyPress", "MCGM_GmodMeleeHitMinecraft")
    hook.Remove("EntityTakeDamage", "MCGM_ProxyDamageToMinecraft")
    hook.Remove("PhysgunPickup", "MCGM_ProtectBridgePhysgun")
    hook.Remove("GravGunPickupAllowed", "MCGM_ProtectBridgeGravgun")
    hook.Remove("CanTool", "MCGM_ProtectBridgeToolgun")
    hook.Remove("ShouldCollide", "MCGM_BlockPlayerCollision")
    removeSharedPlatform()

    for key, ent in pairs(minecraftBlockEnts) do
        if IsValid(ent) then ent:Remove() end
        minecraftBlockEnts[key] = nil
    end

    for _, client in pairs(clients) do
        removeMinecraftProxy(client)
        pcall(function() client.sock:close() end)
    end
    clients = {}

    if server then
        pcall(function() server:close() end)
        server = nil
    end
end

function MC_GM.GetMinecraftClients()
    return clients
end
