--!strict
--!optimize 2
--!native

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local VERTICAL_OFFSET:         number = 3
local RENDER_DISTANCE_SQ:      number = 500 * 500
local CACHE_REFRESH_INTERVAL:  number = 0.3
local RAY_PARALLEL_EPSILON:    number = 1e-5
local DISTANCE_MIN_EPSILON:    number = 1e-10
local ANCESTOR_LIMIT:          number = 4
local TELEPORT_HOLD_FRAMES:    number = 10

local mathSqrt   = math.sqrt
local mathHuge   = math.huge
local mathTan    = math.tan
local mathRad    = math.rad
local osClock    = os.clock
local Workspace  = workspace

type OBBEntry = {
    PX: number, PY: number, PZ: number,
    RX: number, RY: number, RZ: number, HX: number,
    UX: number, UY: number, UZ: number, HY: number,
    FX: number, FY: number, FZ: number, HZ: number,
    BSR: number,
}

local LocalPlayer:    Player         = Players.LocalPlayer :: Player
local OBBCache:       { OBBEntry }   = {}
local OBBCount:       number         = 0
local CharacterRoots: { [Instance]: boolean } = {}
local LastCacheTime:  number         = 0
local WasPressed:     boolean        = false
local TeleportTarget: Vector3?       = nil
local FramesLeft:     number         = 0

local CACHEABLE: { [string]: boolean } = {
    Part = true, MeshPart = true, UnionOperation = true,
}

local function IsCharacterDescendant(instance: Instance): boolean
    local current: Instance? = instance.Parent
    for _ = 1, ANCESTOR_LIMIT do
        if current == nil or current == (Workspace :: Instance) then return false end
        if CharacterRoots[current :: Instance] then return true end
        current = (current :: Instance).Parent
    end
    return false
end

local function RefreshCache()
    table.clear(CharacterRoots)
    for _, obj in Players:GetChildren() do
        if obj.ClassName ~= "Player" then continue end
        local char = (obj :: Player).Character
        if char ~= nil then CharacterRoots[char] = true end
    end

    local camera = Workspace.CurrentCamera
    if camera == nil then return end
    local camPos = camera.Position
    local cx, cy, cz = camPos.X, camPos.Y, camPos.Z
    local cache = OBBCache
    local count = 0

    for _, inst in Workspace:GetDescendants() do
        if not CACHEABLE[inst.ClassName] or inst.Parent == nil or IsCharacterDescendant(inst) then continue end
        local part   = inst :: BasePart
        local cf     = part.CFrame
        local pos    = cf.Position
        local dx, dy, dz = pos.X - cx, pos.Y - cy, pos.Z - cz
        if dx * dx + dy * dy + dz * dz > RENDER_DISTANCE_SQ then continue end
        local size = part.Size
        local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
        local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
        count += 1
        local entry: OBBEntry? = cache[count]
        if entry ~= nil then
            local e  = entry :: OBBEntry
            e.PX = pos.X ; e.PY = pos.Y ; e.PZ = pos.Z
            e.RX = r.X   ; e.RY = r.Y   ; e.RZ = r.Z   ; e.HX = hx
            e.UX = u.X   ; e.UY = u.Y   ; e.UZ = u.Z   ; e.HY = hy
            e.FX = -l.X  ; e.FY = -l.Y  ; e.FZ = -l.Z  ; e.HZ = hz
            e.BSR = hx * hx + hy * hy + hz * hz
        else
            cache[count] = {
                PX = pos.X, PY = pos.Y, PZ = pos.Z,
                RX = r.X,   RY = r.Y,   RZ = r.Z,   HX = hx,
                UX = u.X,   UY = u.Y,   UZ = u.Z,   HY = hy,
                FX = -l.X,  FY = -l.Y,  FZ = -l.Z,  HZ = hz,
                BSR = hx * hx + hy * hy + hz * hz,
            }
        end
    end

    for i = count + 1, #cache do cache[i] = nil :: any end
    OBBCount = count
end

local function RayOBB(
    ox: number, oy: number, oz: number,
    dx: number, dy: number, dz: number,
    e: OBBEntry
): number?
    local ex, ey, ez = e.PX - ox, e.PY - oy, e.PZ - oz
    local tMin, tMax = -mathHuge, mathHuge
    local proj, dot, near, far, half: number

    proj = e.RX * ex + e.RY * ey + e.RZ * ez
    dot  = e.RX * dx + e.RY * dy + e.RZ * dz
    half = e.HX
    if dot > RAY_PARALLEL_EPSILON or dot < -RAY_PARALLEL_EPSILON then
        near = (proj + half) / dot ; far = (proj - half) / dot
        if near > far then near, far = far, near end
        if near > tMin then tMin = near end
        if far  < tMax then tMax = far  end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj - half > 0 or -proj + half < 0 then return nil end

    proj = e.UX * ex + e.UY * ey + e.UZ * ez
    dot  = e.UX * dx + e.UY * dy + e.UZ * dz
    half = e.HY
    if dot > RAY_PARALLEL_EPSILON or dot < -RAY_PARALLEL_EPSILON then
        near = (proj + half) / dot ; far = (proj - half) / dot
        if near > far then near, far = far, near end
        if near > tMin then tMin = near end
        if far  < tMax then tMax = far  end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj - half > 0 or -proj + half < 0 then return nil end

    proj = e.FX * ex + e.FY * ey + e.FZ * ez
    dot  = e.FX * dx + e.FY * dy + e.FZ * dz
    half = e.HZ
    if dot > RAY_PARALLEL_EPSILON or dot < -RAY_PARALLEL_EPSILON then
        near = (proj + half) / dot ; far = (proj - half) / dot
        if near > far then near, far = far, near end
        if near > tMin then tMin = near end
        if far  < tMax then tMax = far  end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj - half > 0 or -proj + half < 0 then return nil end

    return if tMin >= 0 then tMin else 0
end

local function GetMouseRay(camera: Camera, mouse: Vector2): (number, number, number)
    local vp   = camera.ViewportSize
    local half = mathTan(mathRad(camera.FieldOfView * 0.5))
    local asp  = vp.X / vp.Y
    local nx   = (mouse.X / vp.X) * 2 - 1
    local ny   = 1 - (mouse.Y / vp.Y) * 2
    local sx   = nx * asp * half
    local sy   = ny * half
    local r, u, l = camera.RightVector, camera.UpVector, camera.LookVector
    local rx = r.x * sx + u.x * sy + l.x
    local ry = r.y * sx + u.y * sy + l.y
    local rz = r.z * sx + u.z * sy + l.z
    local mag = mathSqrt(rx * rx + ry * ry + rz * rz)
    if mag < DISTANCE_MIN_EPSILON then return 0, 0, 1 end
    return rx / mag, ry / mag, rz / mag
end

local function IsEDown(): boolean
    for _, key in getpressedkeys() do
        if key == "E" then return true end
    end
    return false
end

RunService.PostLocal:Connect(function()
    if not isrbxactive() then
        WasPressed     = false
        TeleportTarget = nil
        FramesLeft     = 0
        return
    end

    local now = osClock()
    if now - LastCacheTime >= CACHE_REFRESH_INTERVAL then
        LastCacheTime = now
        RefreshCache()
    end

    local character = LocalPlayer.Character
    local rootPart  = if character ~= nil then (character :: Model).PrimaryPart else nil

    if FramesLeft > 0 and rootPart ~= nil and TeleportTarget ~= nil then
        local t = TeleportTarget :: Vector3
        rootPart.CFrame   = CFrame.new(t)
        rootPart.Velocity = Vector3.new(0, 0, 0)
        FramesLeft -= 1
        if FramesLeft == 0 then TeleportTarget = nil end
    end

    local isPressed = isleftpressed()
    local isClick   = isPressed and not WasPressed
    WasPressed      = isPressed

    if not isClick or not IsEDown() or character == nil or rootPart == nil then return end

    local camera = Workspace.CurrentCamera
    if camera == nil then return end

    local camPos       = camera.Position
    local ox, oy, oz   = camPos.X, camPos.Y, camPos.Z
    local rdx, rdy, rdz = GetMouseRay(camera, UserInputService:GetMouseLocation())
    local best:  number  = mathHuge
    local cache  = OBBCache
    local count  = OBBCount

    for i = 1, count do
        local e   = cache[i]
        local bx  = e.PX - ox
        local by  = e.PY - oy
        local bz  = e.PZ - oz
        local cp  = bx * rdx + by * rdy + bz * rdz
        if bx * bx + by * by + bz * bz - cp * cp > e.BSR then continue end
        local t = RayOBB(ox, oy, oz, rdx, rdy, rdz, e)
        if t ~= nil and t < best then best = t end
    end

    if best == mathHuge then return end

    TeleportTarget = Vector3.new(ox + rdx * best, oy + rdy * best + VERTICAL_OFFSET, oz + rdz * best)
    FramesLeft     = TELEPORT_HOLD_FRAMES
end)

print("Click Teleportation Initilised")
