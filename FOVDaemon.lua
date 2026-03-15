--!strict

-- FOVDaemon (St0rmCast3r / Hammercroft)

-- !!! !!! !!! NOTE: DROP IN StarterPlayerScripts !!! !!! !!!

--[[
    ( PURPOSE )
    -> Allow the base field of view to be set via a number value instance
    -> For converting 4:3 HFOV values to Roblox's VFOV
    -> For applying dynamic FOV modifiers via number value instances
    -> Do all of these without critical dependencies / module requires.
    
    all 'Base' modifiers are first added to the Base FOV, then the Base FOV is 
    multiplied by each existing 'Multipliers' modifiers.

    ( HOW TO USE )
    -> Set your default/base FOV by adding a "BaseFov" NumberValue child to
       this script instance. (Or modify the constant default FOV below.)
    -> For any script / scripted subsystems that wishes to change the FOV, have
       them create a named NumberValue in FOVDaemon.Base (for add/subtract)
       or in FOVDaemon.Multipliers (for multiplication). Instead of updating
       Camera.FieldOfView per frame on those scripts, regularly update the 
       mentioned NumberValues instead.
    -> Cleaning up modifiers is as easy as deleting the NumberValues in
       FOVDaemon.Base or FOVDaemon.Multipliers
    -> TIP: Have modifier NumberValue names for guns be a common name, like
       `WeaponRecoilFOVAdd`, or `WeaponZoomFOVMultiplier` 
]] 

--[[
    MIT License
    
    Copyright (c) 2025 Hammercroft
    
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:
    
    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.
    
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]

-- default 4:3 horizontal field of view, degrees
local DEFAULT_43_HFOV = 90 

-- Some 4:3 HFOV values that you might like:
-- Call of Duty 4: Modern Warfare (2007) = 65
-- HL2 & TF2 = 75
-- Battlefield 2 (2005) and older Battlefield games = 80
-- Quake 1 (1996), Quake 2, Quake 3, HL1, and all Counter-Strike games = 90
-- Quake 1 Remastered = 95
-- Half-Life 25th Anniversary GoldSrc 'Allow Widescreen Field Of View' setting for 16:9 displays = 107

-- oddly enough, most of the listed games (except Battlefield) are part of
-- Quake's lineage. pretty cool.


-- Folders & Value Instances
local addModifiersFolder = script:FindFirstChild("Base") or Instance.new("Folder")
addModifiersFolder.Name = "Base"
addModifiersFolder.Parent = script
local multiplyModifiersFolder = script:FindFirstChild("Multipliers") or Instance.new("Folder")
multiplyModifiersFolder.Name = "Multipliers"
multiplyModifiersFolder.Parent = script
local baseFovNumberValue = script:WaitForChild("BaseFov", 1) :: NumberValue
if not baseFovNumberValue or baseFovNumberValue.Value == nil then
    baseFovNumberValue = Instance.new("NumberValue")
    baseFovNumberValue.Name = "BaseFov"
    baseFovNumberValue.Value = DEFAULT_43_HFOV
    baseFovNumberValue.Parent = script
    end
    assert(baseFovNumberValue)
    
    -- Base FOV value & caching
    local currentBaseHFOV = baseFovNumberValue.Value
    function updateBaseFOV()
    currentBaseHFOV = baseFovNumberValue.Value
    end
    baseFovNumberValue:GetPropertyChangedSignal("Value"):Connect(updateBaseFOV)
    
    -- other fields
    local appliedPreModifierFov = 0
    
    -- convert 4:3 hfov to vfov, degrees
    @native
    function convertHFovToVFov(viewport_size : Vector2, h_fov : number)
    local currentAspectRatio = (viewport_size.X + 1e-8) / (viewport_size.Y + 1e-8)
    local baseAspectRatio = 1.33333337306976318359375
    local calcRatio = math.min(currentAspectRatio, baseAspectRatio)
    
    -- VFOVrad  = 2 * atan(tan(HFOVrad / 2) / AspectRatio)
    local hFovRad = math.rad(h_fov)
    local vFovRad = 2 * math.atan(math.tan((hFovRad + 1e-8) / 2) / calcRatio)
    
    return math.deg(vFovRad)
    end
    
    repeat wait() until workspace.CurrentCamera ~= nil
    assert(workspace.CurrentCamera)
    local camera : Camera = workspace.CurrentCamera
    
    camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
    local viewport_size = camera.ViewportSize
    local vFov = convertHFovToVFov(viewport_size, currentBaseHFOV)
    appliedPreModifierFov = vFov 
    end)
    --updateCameraFOV()
    
    
    local runSvc = game:GetService("RunService")
    local function update()
    assert(camera)
    camera.FieldOfView = appliedPreModifierFov
    
    -- for each add modifier
    for _, inst in addModifiersFolder:GetChildren() do
        if not inst:IsA("NumberValue") then return end
        camera.FieldOfView += inst.Value
    end
    -- for each multiply modifier
    for _, inst in multiplyModifiersFolder:GetChildren() do
        if not inst:IsA("NumberValue") then return end
        camera.FieldOfView *= inst.Value
    end
end
runSvc.RenderStepped:Connect(update)
                    
                    
