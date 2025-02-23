function APClass(Nav, c, u, s, atlas, vBooster, hover, telemeter_1, antigrav,
    mabs, mfloor, atmosphere, isRemote, atan, systime, uclamp, 
    navCom, sysUpData, sysIsVwLock, msqrt, round) 
 

    local ap = {}
        local function GetAutopilotBrakeDistanceAndTime(speed)
            -- If we're in atmo, just return some 0's or LastMaxBrake, whatever's bigger
            -- So we don't do unnecessary API calls when atmo brakes don't tell us what we want
            local finalSpeed = AutopilotEndSpeed
            if not Autopilot then  finalSpeed = 0 end
            if not inAtmo then
                return Kinematic.computeDistanceAndTime(speed, finalSpeed, coreMass, 0, 0,
                    LastMaxBrake - (AutopilotPlanetGravity * coreMass))
            else
                if LastMaxBrakeInAtmo and LastMaxBrakeInAtmo > 0 then
                    return Kinematic.computeDistanceAndTime(speed, finalSpeed, coreMass, 0, 0,
                            LastMaxBrakeInAtmo - (AutopilotPlanetGravity * coreMass))
                else
                    return 0, 0
                end
            end
        end

        local function GetAutopilotTBBrakeDistanceAndTime(speed)
            local finalSpeed = AutopilotEndSpeed
            if not Autopilot then finalSpeed = 0 end

            return Kinematic.computeDistanceAndTime(speed, finalSpeed, coreMass, Nav:maxForceForward(),
                    warmup, LastMaxBrake - (AutopilotPlanetGravity * coreMass))
        end
    local speedLimitBreaking = false
    local lastPvPDist = 0
    local previousYawAmount = 0
    local previousPitchAmount = 0
    local lastApTickTime = systime()
    local ahDoubleClick = 0
    local apDoubleClick = 0
    local orbitPitch = 0
    local orbitRoll = 0
    local orbitAligned = false
    local orbitalRecover = false
    local OrbitTargetSet = false
    local OrbitTargetPlanet = nil
    local OrbitTicks = 0
    local apRoute = {}

    function ap.GetAutopilotBrakeDistanceAndTime(speed)
        return GetAutopilotBrakeDistanceAndTime(speed)
    end

    function ap.GetAutopilotTBBrakeDistanceAndTime(speed)
        return GetAutopilotTBBrakeDistanceAndTime(speed)
    end

    -- Local Functions used in apTick

        local function signedRotationAngle(normal, vecA, vecB)
            vecA = vecA:project_on_plane(normal)
            vecB = vecB:project_on_plane(normal)
            return atan(vecA:cross(vecB):dot(normal), vecA:dot(vecB))
        end

        local function AboveGroundLevel()
            local function hoverDetectGround()
                local vgroundDistance = -1
                local hgroundDistance = -1
                if vBooster then
                    vgroundDistance = vBooster.getDistance()
                end
                if hover then
                    hgroundDistance = hover.getDistance()
                end
                if vgroundDistance ~= -1 and hgroundDistance ~= -1 then
                    if vgroundDistance < hgroundDistance then
                        return vgroundDistance
                    else
                        return hgroundDistance
                    end
                elseif vgroundDistance ~= -1 then
                    return vgroundDistance
                elseif hgroundDistance ~= -1 then
                    return hgroundDistance
                else
                    return -1
                end
            end
            local hovGndDet = hoverDetectGround()  
            local groundDistance = -1
            if telemeter_1 then 
                groundDistance = telemeter_1.getDistance()
            end
            if hovGndDet ~= -1 and groundDistance ~= -1 then
                if hovGndDet < groundDistance then 
                    return hovGndDet 
                else
                    return groundDistance
                end
            elseif hovGndDet ~= -1 then
                return hovGndDet
            else
                return groundDistance
            end
        end

        local function showWaypoint(planet, coordinates, dontSet)
            local function zeroConvertToMapPosition(targetplanet, worldCoordinates)
                local worldVec = vec3(worldCoordinates)
                if targetplanet.id == 0 then
                    return setmetatable({
                        latitude = worldVec.x,
                        longitude = worldVec.y,
                        altitude = worldVec.z,
                        id = 0,
                        systemId = targetplanet.systemId
                    }, MapPosition)
                end
                local coords = worldVec - targetplanet.center
                local distance = coords:len()
                local altitude = distance - targetplanet.radius
                local latitude = 0
                local longitude = 0
                if not float_eq(distance, 0) then
                    local phi = atan(coords.y, coords.x)
                    longitude = phi >= 0 and phi or (2 * math.pi + phi)
                    latitude = math.pi / 2 - math.acos(coords.z / distance)
                end
                return setmetatable({
                    latitude = math.deg(latitude),
                    longitude = math.deg(longitude),
                    altitude = altitude,
                    id = targetplanet.id,
                    systemId = targetplanet.systemId
                }, MapPosition)
            end
            local waypoint = zeroConvertToMapPosition(planet, coordinates)
            waypoint = "::pos{"..waypoint.systemId..","..waypoint.id..","..waypoint.latitude..","..waypoint.longitude..","..waypoint.altitude.."}"
            if dontSet then 
                return waypoint
            else
                s.setWaypoint(waypoint) 
                return true
            end
        end
        local AutopilotPaused = false

    function ap.showWayPoint(planet, coordinates, dontSet)
        return showWaypoint(planet, coordinates, dontSet)
    end

    function ap.APTick()
        local function checkCollision()
            if collisionTarget and not BrakeLanding then
                local body = collisionTarget[1]
                local far, near = collisionTarget[2],collisionTarget[3] 
                local collisionDistance = math.min(far, near or far)
                local collisionTime = collisionDistance/velMag
                local ignoreCollision = AutoTakeoff and (velMag < 42 or abvGndDet ~= -1)
                local apAction = (AltitudeHold or VectorToTarget or LockPitch or Autopilot)
                if apAction and not ignoreCollision and (brakeDistance*1.5 > collisionDistance or collisionTime < 1) then
                        BrakeIsOn = true
                        apRoute = {}
                        AP.cmdThrottle(0)
                        if AltitudeHold then AP.ToggleAltitudeHold() end
                        if LockPitch then ToggleLockPitch() end
                        msgText = "Autopilot Cancelled due to possible collision"
                        if VectorToTarget or Autopilot then 
                            AP.ToggleAutopilot()
                        end
                        StrongBrakes = true
                        BrakeLanding = true
                        autoRoll = true
                end
                if collisionTime < 11 then 
                    collisionAlertStatus = body.name.." COLLISION "..FormatTimeString(collisionTime).." / "..getDistanceDisplayString(collisionDistance,2)
                else
                    collisionAlertStatus = body.name.." collision "..FormatTimeString(collisionTime)
                end
                if collisionTime < 6 then play("alarm","AL",2) end
            else
                collisionAlertStatus = false
            end
        end
        local function AlignToWorldVector(vector, tolerance, damping) -- Aligns ship to vector with a tolerance and a damping override of user damping if needed.
            local function getMagnitudeInDirection(vector, direction)
                -- return vec3(vector):project_on(vec3(direction)):len()
                vector = vec3(vector)
                direction = vec3(direction):normalize()
                local result = vector * direction -- To preserve sign, just add them I guess
                
                return result.x + result.y + result.z
            end
            -- Sets inputs to attempt to point at the autopilot target
            -- Meant to be called from Update or Tick repeatedly
            local alignmentTolerance = 0.001 -- How closely it must align to a planet before accelerating to it
            local autopilotStrength = 1 -- How strongly autopilot tries to point at a target
            if not inAtmo or not stalling or abvGndDet ~= -1 or velMag < minAutopilotSpeed then
                if damping == nil then
                    damping = DampingMultiplier
                end
    
                if tolerance == nil then
                    tolerance = alignmentTolerance
                end
                vector = vec3(vector):normalize()
                local targetVec = (vec3() - vector)
                local yawAmount = -getMagnitudeInDirection(targetVec, c.getConstructWorldOrientationRight()) * autopilotStrength
                local pitchAmount = -getMagnitudeInDirection(targetVec, c.getConstructWorldOrientationUp()) * autopilotStrength
                if previousYawAmount == 0 then previousYawAmount = yawAmount / 2 end
                if previousPitchAmount == 0 then previousPitchAmount = pitchAmount / 2 end
                -- Skip dampening at very low values, and force it to effectively overshoot so it can more accurately align back
                -- Instead of taking literal forever to converge
                if mabs(yawAmount) < 0.1 then
                    yawInput2 = yawInput2 - yawAmount*2
                else
                    yawInput2 = yawInput2 - (yawAmount + (yawAmount - previousYawAmount) * damping)
                end
                if mabs(pitchAmount) < 0.1 then
                    pitchInput2 = pitchInput2 + pitchAmount*2
                else
                    pitchInput2 = pitchInput2 + (pitchAmount + (pitchAmount - previousPitchAmount) * damping)
                end
    
    
                previousYawAmount = yawAmount
                previousPitchAmount = pitchAmount
                -- Return true or false depending on whether or not we're aligned
                if mabs(yawAmount) < tolerance and mabs(pitchAmount) < tolerance then
                    return true
                end
                return false
            elseif stalling and abvGndDet == -1 then
                -- If stalling, align to velocity to fix the stall
                -- IDK I'm just copy pasting all this
                vector = constructVelocity
                if damping == nil then
                    damping = DampingMultiplier
                end
    
                if tolerance == nil then
                    tolerance = alignmentTolerance
                end
                vector = vec3(vector):normalize()
                local targetVec = (constructForward - vector)
                local yawAmount = -getMagnitudeInDirection(targetVec, c.getConstructWorldOrientationRight()) * autopilotStrength
                local pitchAmount = -getMagnitudeInDirection(targetVec, c.getConstructWorldOrientationUp()) * autopilotStrength
                if previousYawAmount == 0 then previousYawAmount = yawAmount / 2 end
                if previousPitchAmount == 0 then previousPitchAmount = pitchAmount / 2 end
                -- Skip dampening at very low values, and force it to effectively overshoot so it can more accurately align back
                -- Instead of taking literal forever to converge
                if mabs(yawAmount) < 0.1 then
                    yawInput2 = yawInput2 - yawAmount*5
                else
                    yawInput2 = yawInput2 - (yawAmount + (yawAmount - previousYawAmount) * damping)
                end
                if mabs(pitchAmount) < 0.1 then
                    pitchInput2 = pitchInput2 + pitchAmount*5
                else
                    pitchInput2 = pitchInput2 + (pitchAmount + (pitchAmount - previousPitchAmount) * damping)
                end
                previousYawAmount = yawAmount
                previousPitchAmount = pitchAmount
                -- Return true or false depending on whether or not we're aligned
                if mabs(yawAmount) < tolerance and mabs(pitchAmount) < tolerance then
                    return true
                end
                return false
            end
        end
        
        inAtmo = (atmosphere() > 0)
        atmosDensity = atmosphere()
        coreAltitude = c.getAltitude()
        abvGndDet = AboveGroundLevel()
        time = systime()
        lastApTickTime = time


        if CollisionSystem then checkCollision() end

        if antigrav then
            antigravOn = (antigrav.getState() == 1)
        end
        
        local MousePitchFactor = 1 -- Mouse control only
        local MouseYawFactor = 1 -- Mouse control only
        local deltaTick = time - lastApTickTime
        local currentYaw = -math.deg(signedRotationAngle(constructUp, constructVelocity, constructForward))
        local currentPitch = math.deg(signedRotationAngle(constructRight, constructVelocity, constructForward)) -- Let's use a consistent func that uses global velocity
        local up = worldVertical * -1

        stalling = inAtmo and currentYaw < -YawStallAngle or currentYaw > YawStallAngle or currentPitch < -PitchStallAngle or currentPitch > PitchStallAngle
        local deltaX = s.getMouseDeltaX()
        local deltaY = s.getMouseDeltaY()

        if InvertMouse and not holdingShift then deltaY = -deltaY end
        yawInput2 = 0
        rollInput2 = 0
        pitchInput2 = 0
        sys = galaxyReference[0]
        planet = sys:closestBody(c.getConstructWorldPos())
        kepPlanet = Kep(planet)
        orbit = kepPlanet:orbitalParameters(c.getConstructWorldPos(), constructVelocity)
        if coreAltitude == 0 then
            coreAltitude = (worldPos - planet.center):len() - planet.radius
        end
        nearPlanet = u.getClosestPlanetInfluence() > 0 or (coreAltitude > 0 and coreAltitude < 200000)

        local gravity = planet:getGravity(c.getConstructWorldPos()):len() * coreMass
        targetRoll = 0
        maxKinematicUp = c.getMaxKinematicsParametersAlongAxis("ground", c.getConstructOrientationUp())[1]

        if sysIsVwLock() == 0 then
            if isRemote() == 1 and holdingShift then
                if not Animating then
                    simulatedX = uclamp(simulatedX + deltaX,-resolutionWidth/2,resolutionWidth/2)
                    simulatedY = uclamp(simulatedY + deltaY,-resolutionHeight/2,resolutionHeight/2)
                end
            else
                simulatedX = 0
                simulatedY = 0 -- Reset after they do view things, and don't keep sending inputs while unlocked view
                -- Except of course autopilot, which is later.
            end
        else
            simulatedX = uclamp(simulatedX + deltaX,-resolutionWidth/2,resolutionWidth/2)
            simulatedY = uclamp(simulatedY + deltaY,-resolutionHeight/2,resolutionHeight/2)
            distance = msqrt(simulatedX * simulatedX + simulatedY * simulatedY)
            if not holdingShift and isRemote() == 0 then -- Draw deadzone circle if it's navigating
                local dx,dy = 1,1
                if SelectedTab == "SCOPE" then
                    dx,dy = (scopeFOV/90),(scopeFOV/90)
                end
                if userControlScheme == "virtual joystick" then -- Virtual Joystick
                    -- Do navigation things

                    if simulatedX > 0 and simulatedX > DeadZone then
                        yawInput2 = yawInput2 - (simulatedX - DeadZone) * MouseXSensitivity * dx
                    elseif simulatedX < 0 and simulatedX < (DeadZone * -1) then
                        yawInput2 = yawInput2 - (simulatedX + DeadZone) * MouseXSensitivity * dx
                    else
                        yawInput2 = 0
                    end

                    if simulatedY > 0 and simulatedY > DeadZone then
                        pitchInput2 = pitchInput2 - (simulatedY - DeadZone) * MouseYSensitivity * dy
                    elseif simulatedY < 0 and simulatedY < (DeadZone * -1) then
                        pitchInput2 = pitchInput2 - (simulatedY + DeadZone) * MouseYSensitivity * dy
                    else
                        pitchInput2 = 0
                    end
                else
                    simulatedX = 0
                    simulatedY = 0
                    if userControlScheme == "mouse" then -- Mouse Direct
                        pitchInput2 = (-utils.smoothstep(deltaY, -100, 100) + 0.5) * 2 * MousePitchFactor
                        yawInput2 = (-utils.smoothstep(deltaX, -100, 100) + 0.5) * 2 * MouseYawFactor
                    end
                end
            end
        end

        local isWarping = (velMag > 8334)

        if velMag > SpaceSpeedLimit/3.6 and not inAtmo and not Autopilot and not isWarping then
            msgText = "Space Speed Engine Shutoff reached"
            AP.cmdThrottle(0)
        end

        if not isWarping and LastIsWarping then
            if not BrakeIsOn then
                AP.BrakeToggle()
            end
            if Autopilot then
                AP.ToggleAutopilot()
            end
        end
        LastIsWarping = isWarping

        if inAtmo and atmosDensity > 0.09 then
            if velMag > (adjustedAtmoSpeedLimit / 3.6) and not AtmoSpeedAssist and not speedLimitBreaking then
                    BrakeIsOn = true
                    speedLimitBreaking  = true
            elseif not AtmoSpeedAssist and speedLimitBreaking then
                if velMag < (adjustedAtmoSpeedLimit / 3.6) then
                    BrakeIsOn = false
                    speedLimitBreaking = false
                end
            end    
        end

        if BrakeIsOn then
            brakeInput = 1
        else
            brakeInput = 0
        end

        if ProgradeIsOn then
            if spaceLand then 
                BrakeIsOn = false -- wtf how does this keep turning on, and why does it matter if we're in cruise?
                local aligned = false
                if CustomTarget and spaceLand ~= 1 then
                    aligned = AlignToWorldVector(CustomTarget.position-worldPos,0.1) 
                else
                    aligned = AlignToWorldVector(vec3(constructVelocity),0.01) 
                end
                autoRoll = true
                if aligned then
                    AP.cmdCruise(mfloor(adjustedAtmoSpeedLimit))
                    if (mabs(adjustedRoll) < 2 or mabs(adjustedPitch) > 85) and velMag >= adjustedAtmoSpeedLimit/3.6-1 then
                        -- Try to force it to get full speed toward target, so it goes straight to throttle and all is well
                        BrakeIsOn = false
                        ProgradeIsOn = false
                        reentryMode = true
                        if spaceLand ~= 1 then finalLand = true end
                        spaceLand = false
                        Autopilot = false
                        --autoRoll = autoRollPreference   
                        AP.BeginReentry()
                    end
                elseif inAtmo and AtmoSpeedAssist then 
                    AP.cmdThrottle(1) -- Just let them full throttle if they're in atmo
                end
            elseif velMag > minAutopilotSpeed then
                AlignToWorldVector(vec3(constructVelocity),0.01) 
            end
        end

        if RetrogradeIsOn then
            if inAtmo then 
                RetrogradeIsOn = false
            elseif velMag > minAutopilotSpeed then -- Help with div by 0 errors and careening into terrain at low speed
                AlignToWorldVector(-(vec3(constructVelocity)))
            end
        end

        if not ProgradeIsOn and spaceLand and not IntoOrbit then 
            if atmosDensity == 0 then 
                reentryMode = true
                AP.BeginReentry()
                spaceLand = false
                finalLand = true
            else
                spaceLand = false
                AP.ToggleAutopilot()
            end
        end

        if finalLand and CustomTarget and (coreAltitude < (HoldAltitude + 250) and coreAltitude > (HoldAltitude - 250)) and ((velMag*3.6) > (adjustedAtmoSpeedLimit-250)) and mabs(vSpd) < 25 and atmosDensity >= 0.1
            and (CustomTarget.position-worldPos):len() > 2000 + coreAltitude then -- Only engage if far enough away to be able to turn back for it
                AP.ToggleAutopilot()
            finalLand = false
        end

        if VertTakeOff then
            autoRoll = true
            local targetAltitude = HoldAltitude
            if vSpd < -30 then -- saftey net
                msgText = "Unable to achieve lift. Safety Landing."
                upAmount = 0
                autoRoll = autoRollPreference
                VertTakeOff = false
                BrakeLanding = true
            elseif (not ExternalAGG and antigravOn) or HoldAltitude < planet.spaceEngineMinAltitude then
                if antigravOn then targetAltitude = antigrav.getBaseAltitude() end
                if coreAltitude < (targetAltitude - 100) then
                    VtPitch = 0
                    upAmount = 15
                    BrakeIsOn = false
                elseif vSpd > 0 then
                    BrakeIsOn = true
                    upAmount = 0
                elseif vSpd < -30 then
                    BrakeIsOn = true
                    upAmount = 15
                elseif coreAltitude >= targetAltitude then
                    if antigravOn then 
                        if Autopilot or VectorToTarget then
                            AP.ToggleVerticalTakeoff()

                        else
                            BrakeIsOn = true
                            VertTakeOff = false
                        end
                        msgText = "Takeoff complete. Singularity engaged"
                        play("aggLk","AG")
                    else
                        BrakeIsOn = false
                        msgText = "VTO complete. Engaging Horizontal Flight"
                        play("vtoc", "VT")
                        AP.ToggleVerticalTakeoff()
                    end
                    upAmount = 0
                end
            else
                if atmosDensity > 0.08 then
                    VtPitch = 0
                    BrakeIsOn = false
                    upAmount = 20
                elseif atmosDensity < 0.08 and atmosDensity > 0 then
                    BrakeIsOn = false
                    if SpaceEngineVertDn then
                        VtPitch = 0
                        upAmount = 20
                    else
                        upAmount = 0
                        VtPitch = 36
                        AP.cmdCruise(3500)
                    end
                else
                    autoRoll = autoRollPreference
                    IntoOrbit = true
                    OrbitAchieved = false
                    CancelIntoOrbit = false
                    orbitAligned = false
                    orbitPitch = nil
                    orbitRoll = nil
                    if OrbitTargetPlanet == nil then
                        OrbitTargetPlanet = planet
                    end
                    OrbitTargetOrbit = targetAltitude
                    OrbitTargetSet = true
                    VertTakeOff = false
                end
            end
            if VtPitch ~= nil then
                if (vTpitchPID == nil) then
                    vTpitchPID = pid.new(2 * 0.01, 0, 2 * 0.1)
                end
                local vTpitchDiff = uclamp(VtPitch-adjustedPitch, -PitchStallAngle*0.80, PitchStallAngle*0.80)
                vTpitchPID:inject(vTpitchDiff)
                local vTPitchInput = uclamp(vTpitchPID:get(),-1,1)
                pitchInput2 = vTPitchInput
            end
        end

        if IntoOrbit then
            local targetVec
            local yawAligned = false
            local orbitHeightString = getDistanceDisplayString(OrbitTargetOrbit)

            if OrbitTargetPlanet == nil then
                OrbitTargetPlanet = planet
                if VectorToTarget then
                    OrbitTargetPlanet = autopilotTargetPlanet
                end
            end
            if not OrbitTargetSet then
                OrbitTargetOrbit = mfloor(OrbitTargetPlanet.radius + OrbitTargetPlanet.surfaceMaxAltitude + LowOrbitHeight)
                if OrbitTargetPlanet.hasAtmosphere then
                    OrbitTargetOrbit = mfloor(OrbitTargetPlanet.radius + OrbitTargetPlanet.noAtmosphericDensityAltitude + LowOrbitHeight)
                end
                OrbitTargetSet = true
            end     

            if orbitalParams.VectorToTarget and CustomTarget then
                targetVec = CustomTarget.position - worldPos
            end
            local escapeVel, endSpeed = Kep(OrbitTargetPlanet):escapeAndOrbitalSpeed((worldPos -OrbitTargetPlanet.center):len()-OrbitTargetPlanet.radius)
            local orbitalRoll = adjustedRoll
            -- Getting as close to orbit distance as comfortably possible
            if not orbitAligned then
                local pitchAligned = false
                local rollAligned = false

                AP.cmdThrottle(0)
                orbitRoll = 0
                orbitMsg = "Aligning to orbital path - OrbitHeight: "..orbitHeightString

                if orbitalParams.VectorToTarget then
                    AlignToWorldVector(targetVec:normalize():project_on_plane(worldVertical)) -- Returns a value that wants both pitch and yaw to align, which we don't do
                    yawAligned = constructForward:dot(targetVec:project_on_plane(constructUp):normalize()) > 0.95
                else
                    AlignToWorldVector(constructVelocity)
                    yawAligned = currentYaw < 0.5
                    if velMag < 150 then yawAligned = true end-- Low velocities can never truly align yaw
                end
                pitchInput2 = 0
                orbitPitch = 0
                if adjustedPitch <= orbitPitch+1 and adjustedPitch >= orbitPitch-1 then
                    pitchAligned = true
                else
                    pitchAligned = false
                end
                if orbitalRoll <= orbitRoll+1 and orbitalRoll >= orbitRoll-1 then
                    rollAligned = true
                else
                    rollAligned = false
                end
                if pitchAligned and rollAligned and yawAligned then
                    orbitPitch = nil
                    orbitRoll = nil
                    orbitAligned = true
                end
            else
                if orbitalParams.VectorToTarget then
                    AlignToWorldVector(targetVec:normalize():project_on_plane(worldVertical))
                elseif velMag > 150 then
                    AlignToWorldVector(constructVelocity)
                end
                pitchInput2 = 0
                if orbitalParams.VectorToTarget and CustomTarget then
                    -- Orbit to target...

                    local brakeDistance, _ =  Kinematic.computeDistanceAndTime(velMag, adjustedAtmoSpeedLimit/3.6, coreMass, 0, 0, LastMaxBrake)
                    if OrbitAchieved and targetVec:len() > 15000+brakeDistance+coreAltitude then -- Triggers when we get close to passing it or within 15km+height I guess
                        orbitMsg = "Orbiting to Target"
                        if (coreAltitude - 100) <= OrbitTargetPlanet.noAtmosphericDensityAltitude or  (travelTime> orbit.timeToPeriapsis and  orbit.periapsis.altitude  < OrbitTargetPlanet.noAtmosphericDensityAltitude) then 
                            OrbitAchieved = false 
                        end
                    elseif OrbitAchieved or targetVec:len() < 15000+brakeDistance+coreAltitude then
                        msgText = "Orbit complete, proceeding with reentry"
                        play("orCom", "OB")
                        -- We can skip prograde completely if we're approaching from an orbit?
                        --BrakeIsOn = false -- Leave brakes on to be safe while we align prograde
                        AutopilotTargetCoords = CustomTarget.position -- For setting the waypoint
                        reentryMode = true
                        finalLand = true
                        orbitalParams.VectorToTarget, orbitalParams.AutopilotAlign = false, false -- Let it disable orbit
                        AP.ToggleIntoOrbit()
                        AP.BeginReentry()
                        return
                    end
                end
                if orbit.periapsis ~= nil and orbit.apoapsis ~= nil and orbit.eccentricity < 1 and coreAltitude > OrbitTargetOrbit*0.9 and coreAltitude < OrbitTargetOrbit*1.4 then
                    if orbit.apoapsis ~= nil then
                        if (orbit.periapsis.altitude >= OrbitTargetOrbit*0.99 and orbit.apoapsis.altitude >= OrbitTargetOrbit*0.99 and 
                            orbit.periapsis.altitude < orbit.apoapsis.altitude and orbit.periapsis.altitude*1.05 >= orbit.apoapsis.altitude) or OrbitAchieved then -- This should get us a stable orbit within 10% with the way we do it
                            if OrbitAchieved then
                                BrakeIsOn = false
                                AP.cmdThrottle(0)
                                orbitPitch = 0
                                
                                if not orbitalParams.VectorToTarget then
                                    msgText = "Orbit complete"
                                    play("orCom", "OB")
                                    AP.ToggleIntoOrbit()
                                end
                            else
                                OrbitTicks = OrbitTicks + 1 -- We want to see a good orbit for 2 consecutive ticks plz
                                if OrbitTicks >= 2 then
                                    OrbitAchieved = true
                                end
                            end
                            
                        else
                            orbitMsg = "Adjusting Orbit - OrbitHeight: "..orbitHeightString
                            orbitalRecover = true
                            -- Just set cruise to endspeed...
                            AP.cmdCruise(endSpeed*3.6+1)
                            -- And set pitch to something that scales with vSpd
                            -- Well, a pid is made for this stuff
                            local altDiff = OrbitTargetOrbit - coreAltitude

                            if (VSpdPID == nil) then
                                VSpdPID = pid.new(0.1, 0, 1 * 0.1)
                            end
                            -- Scale vspd up to cubed as altDiff approaches 0, starting at 2km
                            -- 20's are kinda arbitrary but I've tested lots of others and these are consistent
                            -- The 2000's also.  
                            -- Also the smoothstep might not be entirely necessary alongside the cubing but, I'm sure it helps...
                            -- Well many of the numbers changed, including the cubing but.  This looks amazing.  
                            VSpdPID:inject(altDiff-vSpd*uclamp((utils.smoothstep(2000-altDiff,-2000,2000))^6*10,1,10)) 
                            

                            orbitPitch = uclamp(VSpdPID:get(),-60,60) -- Prevent it from pitching so much that cruise starts braking
                            
                        end
                    end
                else
                    local orbitalMultiplier = 2.75
                    local pcs = mabs(round(escapeVel*orbitalMultiplier))
                    local mod = pcs%50
                    if mod > 0 then pcs = (pcs - mod) + 50 end
                    BrakeIsOn = false
                    if coreAltitude < OrbitTargetOrbit*0.8 then
                        orbitMsg = "Escaping planet gravity - OrbitHeight: "..orbitHeightString
                        orbitPitch = utils.map(vSpd, 200, 0, -15, 80)
                    elseif coreAltitude >= OrbitTargetOrbit*0.8 and coreAltitude < OrbitTargetOrbit*1.15 then
                        orbitMsg = "Approaching orbital corridor - OrbitHeight: "..orbitHeightString
                        pcs = pcs*0.75
                        orbitPitch = utils.map(vSpd, 100, -100, -15, 65)
                    elseif coreAltitude >= OrbitTargetOrbit*1.15 and coreAltitude < OrbitTargetOrbit*1.5 then
                        orbitMsg = "Approaching orbital corridor - OrbitHeight: "..orbitHeightString
                        pcs = pcs*0.75
                        if vSpd < 0 or orbitalRecover then
                            orbitPitch = utils.map(coreAltitude, OrbitTargetOrbit*1.5, OrbitTargetOrbit*1.01, -30, 0) -- Going down? pitch up.
                            --orbitPitch = utils.map(vSpd, 100, -100, -15, 65)
                        else
                            orbitPitch = utils.map(coreAltitude, OrbitTargetOrbit*0.99, OrbitTargetOrbit*1.5, 0, 30) -- Going up? pitch down.
                        end
                    elseif coreAltitude > OrbitTargetOrbit*1.5 then
                        orbitMsg = "Reentering orbital corridor - OrbitHeight: "..orbitHeightString
                        orbitPitch = -65 --utils.map(vSpd, 25, -200, -65, -30)
                        local pcsAdjust = utils.map(vSpd, -150, -400, 1, 0.55)
                        pcs = pcs*pcsAdjust
                    end
                    AP.cmdCruise(mfloor(pcs))
                end
            end
            if orbitPitch ~= nil then
                if (OrbitPitchPID == nil) then
                    OrbitPitchPID = pid.new(1 * 0.01, 0, 5 * 0.1)
                end
                local orbitPitchDiff = orbitPitch - adjustedPitch
                OrbitPitchPID:inject(orbitPitchDiff)
                local orbitPitchInput = uclamp(OrbitPitchPID:get(),-0.5,0.5)
                pitchInput2 = orbitPitchInput
            end
        end

        if Autopilot and atmosDensity == 0 and not spaceLand then
            local function finishAutopilot(msg, orbit)
                s.print(msg)
                BrakeIsOn = false
                AutopilotBraking = false
                Autopilot = false
                TargetSet = false
                AutopilotStatus = "Aligning" -- Disable autopilot and reset
                AP.cmdThrottle(0)
                apThrottleSet = false
                msgText = msg
                play("apCom","AP")
                if orbit or spaceLand then
                    if orbit and AutopilotTargetOrbit ~= nil and not spaceLand then 
                        if not coreAltitude or coreAltitude == 0 then return end
                        OrbitTargetOrbit = coreAltitude
                        OrbitTargetSet = true
                    end
                    AP.ToggleIntoOrbit()
                end
            end
            -- Planetary autopilot engaged, we are out of atmo, and it has a target
            -- Do it.  
            -- And tbh we should calc the brakeDistance live too, and of course it's also in meters
            
            -- Maybe instead of pointing at our vector, we point at our vector + how far off our velocity vector is
            -- This is gonna be hard to get the negatives right.
            -- If we're still in orbit, don't do anything, that velocity will suck
            local targetCoords, skipAlign = AutopilotTargetCoords, false
            -- This isn't right.  Maybe, just take the smallest distance vector between the normal one, and the wrongSide calculated one
            --local wrongSide = (CustomTarget.position-worldPos):len() > (autopilotTargetPlanet.center-worldPos):len()
            if CustomTarget and CustomTarget.planetname ~= "Space" then
                AutopilotRealigned = true -- Don't realign, point straight at the target.  Or rather, at AutopilotTargetOrbit above it
                if not TargetSet then
                    -- It's on the wrong side of the planet. 
                    -- So, get the 3d direction between our target and planet center.  Note that, this is basically a vector defining gravity at our target, too...
                    local initialDirection = (CustomTarget.position - autopilotTargetPlanet.center):normalize() -- Should be pointing up
                    local finalDirection = initialDirection:project_on_plane((autopilotTargetPlanet.center-worldPos):normalize()):normalize()
                    -- And... actually that's all that I need.  If forward is really gone, this should give us a point on the edge of the planet
                    local wrongSideCoords = autopilotTargetPlanet.center + finalDirection*(autopilotTargetPlanet.radius + AutopilotTargetOrbit)
                    -- This used to be calculated based on our direction instead of gravity, which helped us approach not directly overtop it
                    -- But that caused bad things to happen for nearside/farside detection sometimes
                    local rightSideCoords = CustomTarget.position + (CustomTarget.position - autopilotTargetPlanet.center):normalize() * (AutopilotTargetOrbit - autopilotTargetPlanet:getAltitude(CustomTarget.position))
                    if (worldPos-wrongSideCoords):len() < (worldPos-rightSideCoords):len() then
                        targetCoords = wrongSideCoords
                    else
                        targetCoords = rightSideCoords
                        AutopilotEndSpeed = 0
                    end
                    AutopilotTargetCoords = targetCoords
                    AP.showWayPoint(autopilotTargetPlanet, AutopilotTargetCoords)

                    skipAlign = true
                    TargetSet = true -- Only set the targetCoords once.  Don't let them change as we fly.
                end
                --AutopilotPlanetGravity = autopilotTargetPlanet.gravity*9.8 -- Since we're aiming straight at it, we have to assume gravity?
                AutopilotPlanetGravity = 0
            elseif CustomTarget and CustomTarget.planetname == "Space" then
                if not TargetSet then
                    AutopilotPlanetGravity = 0
                    skipAlign = true
                    AutopilotRealigned = true
                    TargetSet = true
                    -- We forgot to normalize this... though that should have really fucked everything up... 
                    -- Ah also we were using AutopilotTargetOrbit which gets set to 0 for space.  

                    -- So we should ... do what, if they're inside that range?  I guess just let it pilot them to outside. 
                    -- TODO: Later have some settable intervals like 10k, 5k, 1k, 500m and have it approach the nearest one that's below it
                    -- With warnings about what it's doing 

                    targetCoords = CustomTarget.position + (worldPos - CustomTarget.position):normalize()*AutopilotSpaceDistance
                    AutopilotTargetCoords = targetCoords
                    -- Unsure if we should update the waypoint to the new target or not.  
                    --AP.showWayPoint(autopilotTargetPlanet, targetCoords)
                end
            elseif CustomTarget == nil then -- and not autopilotTargetPlanet.name == planet.name then
                AutopilotPlanetGravity = 0

                if not TargetSet then
                    -- Set the target to something on the radius in the direction closest to velocity
                    -- We have to fudge a high velocity because at standstill this can give us bad results
                    local initialDirection = ((worldPos+(constructVelocity*100000)) - autopilotTargetPlanet.center):normalize() -- Should be pointing up
                    local finalDirection = initialDirection:project_on_plane((autopilotTargetPlanet.center-worldPos):normalize()):normalize()
                    if finalDirection:len() < 1 then
                        initialDirection = ((worldPos+(constructForward*100000)) - autopilotTargetPlanet.center):normalize()
                        finalDirection = initialDirection:project_on_plane((autopilotTargetPlanet.center-worldPos):normalize()):normalize() -- Align to nearest to ship forward then
                    end
                    -- And... actually that's all that I need.  If forward is really gone, this should give us a point on the edge of the planet
                    targetCoords = autopilotTargetPlanet.center + finalDirection*(autopilotTargetPlanet.radius + AutopilotTargetOrbit)
                    AutopilotTargetCoords = targetCoords
                    TargetSet = true
                    skipAlign = true
                    AutopilotRealigned = true
                    --AutopilotAccelerating = true
                    AP.showWayPoint(autopilotTargetPlanet, AutopilotTargetCoords)
                end
            end
            
            AutopilotDistance = (vec3(targetCoords) - worldPos):len()
            local intersectBody, farSide, nearSide = galaxyReference:getPlanetarySystem(0):castIntersections(worldPos, (constructVelocity):normalize(), function(body) if body.noAtmosphericDensityAltitude > 0 then return (body.radius+body.noAtmosphericDensityAltitude) else return (body.radius+body.surfaceMaxAltitude*1.5) end end)
            local atmoDistance = farSide
            if nearSide ~= nil and farSide ~= nil then
                atmoDistance = math.min(nearSide,farSide)
            end
            if atmoDistance ~= nil and atmoDistance < AutopilotDistance and intersectBody.name == autopilotTargetPlanet.name then
                AutopilotDistance = atmoDistance -- If we're going to hit atmo before our target, use that distance instead.
                -- Can we put this on the HUD easily?
                --local value, units = getDistanceDisplayString(atmoDistance)
                --msgText = "Adjusting Brake Distance, will hit atmo in: " .. value .. units
            end

            
            -- We do this in tenthSecond already.
            --sysUpData(widgetDistanceText, '{"label": "distance", "value": "' ..
            --    displayText.. '", "u":"' .. displayUnit .. '"}')
            local aligned = true -- It shouldn't be used if the following condition isn't met, but just in case

            local projectedAltitude = (autopilotTargetPlanet.center -
                                        (worldPos +
                                            (vec3(constructVelocity):normalize() * AutopilotDistance))):len() -
                                        autopilotTargetPlanet.radius
            local displayText = getDistanceDisplayString(projectedAltitude)
            sysUpData(widgetTrajectoryAltitudeText, '{"label": "Projected Altitude", "value": "' ..
                displayText.. '"}')
            

            local brakeDistance, brakeTime
            
            if not TurnBurn then
                brakeDistance, brakeTime = GetAutopilotBrakeDistanceAndTime(velMag)
            else
                brakeDistance, brakeTime = GetAutopilotTBBrakeDistanceAndTime(velMag)
            end

            --orbit.apoapsis == nil and 

            -- Brought this min velocity way down from 300 because the logic when velocity is low doesn't even point at the target or anything
            -- I'll prob make it do that, too, though.  There was just no reason for this to wait for such high speeds
            if velMag > 50 and AutopilotAccelerating then
                -- Use signedRotationAngle to get the yaw and pitch angles with shipUp and shipRight as the normals, respectively
                -- Then use a PID
                local targetVec = (vec3(targetCoords) - worldPos)
                local targetYaw = uclamp(math.deg(signedRotationAngle(constructUp, constructVelocity:normalize(), targetVec:normalize()))*(velMag/500),-90,90)
                local targetPitch = uclamp(math.deg(signedRotationAngle(constructRight, constructVelocity:normalize(), targetVec:normalize()))*(velMag/500),-90,90)

            
                -- If they're both very small, scale them both up a lot to converge that last bit
                if mabs(targetYaw) < 20 and mabs(targetPitch) < 20 then
                    targetYaw = targetYaw * 2
                    targetPitch = targetPitch * 2
                end
                -- If they're both very very small even after scaling them the first time, do it again
                if mabs(targetYaw) < 2 and mabs(targetPitch) < 2 then
                    targetYaw = targetYaw * 2
                    targetPitch = targetPitch * 2
                end

                -- We'll do our own currentYaw and Pitch
                local currentYaw = -math.deg(signedRotationAngle(constructUp, constructForward, constructVelocity:normalize()))
                local currentPitch = -math.deg(signedRotationAngle(constructRight, constructForward, constructVelocity:normalize()))

                if (apPitchPID == nil) then
                    apPitchPID = pid.new(2 * 0.01, 0, 2 * 0.1) -- magic number tweaked to have a default factor in the 1-10 range
                end
                apPitchPID:inject(targetPitch - currentPitch)
                local autoPitchInput = uclamp(apPitchPID:get(),-1,1)

                pitchInput2 = pitchInput2 + autoPitchInput

                if (apYawPID == nil) then -- Changed from 2 to 8 to tighten it up around the target
                    apYawPID = pid.new(2 * 0.01, 0, 2 * 0.1) -- magic number tweaked to have a default factor in the 1-10 range
                end
                --yawPID:inject(yawDiff) -- Aim for 85% stall angle, not full
                apYawPID:inject(targetYaw - currentYaw)
                local autoYawInput = uclamp(apYawPID:get(),-1,1) -- Keep it reasonable so player can override
                yawInput2 = yawInput2 + autoYawInput
                

                skipAlign = true

                if mabs(targetYaw) > 2 or mabs(targetPitch) > 2 then
                    if AutopilotStatus ~= "Adjusting Trajectory" then
                        AutopilotStatus = "Adjusting Trajectory"
                        play("apAdj","AP")
                    end
                else
                    if AutopilotStatus ~= "Accelerating" then
                        AutopilotStatus = "Accelerating"
                        play("apAcc","AP")
                    end
                end
            
            elseif AutopilotAccelerating and velMag <= 50 then
                -- Point at target... 
                AlignToWorldVector((targetCoords - worldPos):normalize())
            end
        

            if projectedAltitude < AutopilotTargetOrbit*1.5 then
                -- Recalc end speeds for the projectedAltitude since it's reasonable... 
                if CustomTarget and CustomTarget.planetname == "Space" then 
                    AutopilotEndSpeed = 0
                elseif CustomTarget == nil then
                    _, AutopilotEndSpeed = Kep(autopilotTargetPlanet):escapeAndOrbitalSpeed(projectedAltitude)
                end
            end
            if Autopilot and not AutopilotAccelerating and not AutopilotCruising and not AutopilotBraking then
                local intersectBody, atmoDistance = AP.checkLOS( (AutopilotTargetCoords-worldPos):normalize())
                if autopilotTargetPlanet.name ~= planet.name then 
                    if intersectBody ~= nil and autopilotTargetPlanet.name ~= intersectBody.name and atmoDistance < AutopilotDistance then 
                        msgText = "Collision with "..intersectBody.name.." in ".. getDistanceDisplayString(atmoDistance).."\nClear LOS to continue."
                        msgTimer = 5
                        AutopilotPaused = true
                    else
                        AutopilotPaused = false
                        msgText = ""
                    end
                end
            end
            if not AutopilotPaused then
                if not AutopilotCruising and not AutopilotBraking and not skipAlign then
                    aligned = AlignToWorldVector((targetCoords - worldPos):normalize())
                elseif TurnBurn and (AutopilotBraking or AutopilotCruising) then
                    aligned = AlignToWorldVector(-vec3(constructVelocity):normalize())
                end
            end
            if AutopilotAccelerating then
                if not apThrottleSet then
                    BrakeIsOn = false
                    AP.cmdThrottle(AutopilotInterplanetaryThrottle)
                    PlayerThrottle = round(AutopilotInterplanetaryThrottle,2)
                    apThrottleSet = true
                end
                local throttle = u.getThrottle()
                if AtmoSpeedAssist then throttle = PlayerThrottle end
                -- If we're within warmup/8 seconds of needing to brake, cut throttle to handle warmdowns
                -- Note that warmup/8 is kindof an arbitrary guess.  But it shouldn't matter that much.  

                -- We need the travel time, the one we compute elsewhere includes estimates on acceleration
                -- Also it doesn't account for velocity not being in the correct direction, this should
                local timeUntilBrake = 99999 -- Default in case accel and velocity are both 0 
                local accel = -(vec3(c.getWorldAcceleration()):dot(constructVelocity:normalize()))
                local velAlongTarget = uclamp(constructVelocity:dot((targetCoords - worldPos):normalize()),0,velMag)
                if velAlongTarget > 0 or accel > 0 then -- (otherwise divide by 0 errors)
                    timeUntilBrake = Kinematic.computeTravelTime(velAlongTarget, accel, AutopilotDistance-brakeDistance)
                end
                if (coreVelocity:len() >= MaxGameVelocity or (throttle == 0 and apThrottleSet) or warmup/4 > timeUntilBrake) then
                    AutopilotAccelerating = false
                    if AutopilotStatus ~= "Cruising" then
                        play("apCru","AP")
                        AutopilotStatus = "Cruising"
                    end
                    AutopilotCruising = true
                    AP.cmdThrottle(0)
                    --apThrottleSet = false -- We already did it, if they cancelled let them throttle up again
                end
                -- Check if accel needs to stop for braking
                --if brakeForceRequired >= LastMaxBrake then
                local apDist = AutopilotDistance
                --if autopilotTargetPlanet.name == "Space" then
                --    apDist = apDist - AutopilotSpaceDistance
                --end

                if apDist <= brakeDistance or (PreventPvP and pvpDist <= brakeDistance+10000 and notPvPZone) then
                    if (PreventPvP and pvpDist <= brakeDistance+10000 and notPvPZone) then
                            if pvpDist < lastPvPDist and pvpDist > 2000 then
                                AP.ToggleAutopilot()
                                msgText = "Autopilot cancelled to prevent crossing PvP Line" 
                                BrakeIsOn=true
                                lastPvPDist = pvpDist
                            else
                                lastPvPDist = pvpDist
                                return
                            end
                    end
                    AutopilotAccelerating = false
                    if AutopilotStatus ~= "Braking" then
                        play("apBrk","AP")
                        AutopilotStatus = "Braking"
                    end
                    AutopilotBraking = true
                    AP.cmdThrottle(0)
                    apThrottleSet = false
                end
            elseif AutopilotBraking then
                if AutopilotStatus ~= "Orbiting to Target" then
                    BrakeIsOn = true
                    brakeInput = 1
                end
                if TurnBurn then
                    AP.cmdThrottle(1,true) -- This stays 100 to not mess up our calculations
                end
                -- Check if an orbit has been established and cut brakes and disable autopilot if so
                -- We'll try <0.9 instead of <1 so that we don't end up in a barely-orbit where touching the controls will make it an escape orbit
                -- Though we could probably keep going until it starts getting more eccentric, so we'd maybe have a circular orbit
                local _, endSpeed = Kep(autopilotTargetPlanet):escapeAndOrbitalSpeed((worldPos-planet.center):len()-planet.radius)
                

                local targetVec--, targetAltitude, --horizontalDistance
                if CustomTarget then
                    targetVec = CustomTarget.position - worldPos
                    --targetAltitude = planet:getAltitude(CustomTarget.position)
                    --horizontalDistance = msqrt(targetVec:len()^2-(coreAltitude-targetAltitude)^2)
                end
                if (CustomTarget and CustomTarget.planetname == "Space" and velMag < 50) then
                    if #apRoute>0 then
                        BrakeIsOn = false
                        AP.ToggleAutopilot()
                        AP.ToggleAutopilot()
                        return
                    end
                    finishAutopilot("Autopilot complete, arrived at space location")
                    BrakeIsOn = true
                    brakeInput = 1
                    -- We only aim for endSpeed even if going straight in, because it gives us a smoother transition to alignment
                elseif (CustomTarget and CustomTarget.planetname ~= "Space") and velMag <= endSpeed and (orbit.apoapsis == nil or orbit.periapsis == nil or orbit.apoapsis.altitude <= 0 or orbit.periapsis.altitude <= 0) then
                    -- They aren't in orbit, that's a problem if we wanted to do anything other than reenter.  Reenter regardless.                  
                    finishAutopilot("Autopilot complete, commencing reentry")
                    --BrakeIsOn = true
                    --BrakeIsOn = false -- Leave brakes on to be safe while we align prograde
                    AutopilotTargetCoords = CustomTarget.position -- For setting the waypoint
                    --ProgradeIsOn = true  
                    spaceLand = true
                    AP.showWayPoint(autopilotTargetPlanet, AutopilotTargetCoords)
                elseif ((CustomTarget and CustomTarget.planetname ~= "Space") or CustomTarget == nil) and orbit.periapsis ~= nil and orbit.periapsis.altitude > 0 and orbit.eccentricity < 1 or AutopilotStatus == "Circularizing" then
                    if AutopilotStatus ~= "Circularizing" then
                        play("apCir", "AP")
                        AutopilotStatus = "Circularizing"
                    end
                    if velMag <= endSpeed then 
                        if CustomTarget then
                            if constructVelocity:normalize():dot(targetVec:normalize()) > 0.4 then -- Triggers when we get close to passing it
                                if AutopilotStatus ~= "Orbiting to Target" then
                                    play("apOrb","OB")
                                    AutopilotStatus = "Orbiting to Target"
                                end
                                if not WaypointSet then
                                    BrakeIsOn = false -- We have to set this at least once
                                    AP.showWayPoint(autopilotTargetPlanet, CustomTarget.position)
                                    WaypointSet = true
                                end
                            else 
                                finishAutopilot("Autopilot complete, proceeding with reentry")
                                AutopilotTargetCoords = CustomTarget.position -- For setting the waypoint
                                --ProgradeIsOn = true
                                spaceLand = true
                                AP.showWayPoint(autopilotTargetPlanet, CustomTarget.position)
                                WaypointSet = false -- Don't need it anymore
                            end
                        else
                            finishAutopilot("Autopilot completed, setting orbit", true)
                            brakeInput = 0
                        end
                    end
                elseif AutopilotStatus == "Circularizing" then
                    finishAutopilot("Autopilot complete, fixing Orbit", true)
                end
            elseif AutopilotCruising then
                --if brakeForceRequired >= LastMaxBrake then
                --if brakeForceRequired >= LastMaxBrake then
                local apDist = AutopilotDistance
                --if autopilotTargetPlanet.name == "Space" then
                --    apDist = apDist - AutopilotSpaceDistance
                --end

                if apDist <= brakeDistance or (PreventPvP and pvpDist <= brakeDistance+10000 and notPvPZone) then
                    if (PreventPvP and pvpDist <= brakeDistance+10000 and notPvPZone) then
                        if pvpDist < lastPvPDist and pvpDist > 2000 then 
                            AP.ToggleAutopilot()
                            msgText = "Autopilot cancelled to prevent crossing PvP Line" 
                            BrakeIsOn=true
                            lastPvPDist = pvpDist
                        else
                            lastPvPDist = pvpDist
                            return
                        end
                    end
                    AutopilotAccelerating = false
                    if AutopilotStatus ~= "Braking" then
                        play("apBrk","AP")
                        AutopilotStatus = "Braking"
                    end
                    AutopilotBraking = true
                end
                local throttle = u.getThrottle()
                if AtmoSpeedAssist then throttle = PlayerThrottle end
                if throttle > 0 then
                    AutopilotAccelerating = true
                    if AutopilotStatus ~= "Accelerating" then
                        AutopilotStatus = "Accelerating"
                        play("apAcc","AP")
                    end
                    AutopilotCruising = false
                end
            else
                -- It's engaged but hasn't started accelerating yet.
                if aligned then
                    -- Re-align to 200km from our aligned right                    
                    if not AutopilotRealigned and CustomTarget == nil or (not AutopilotRealigned and CustomTarget and CustomTarget.planetname ~= "Space") then
                        if not spaceLand then
                            AutopilotTargetCoords = vec3(autopilotTargetPlanet.center) +
                                                        ((AutopilotTargetOrbit + autopilotTargetPlanet.radius) *
                                                            constructRight)
                            AutopilotShipUp = constructUp
                            AutopilotShipRight = constructRight
                        end
                        AutopilotRealigned = true
                    elseif aligned and not AutopilotPaused then
                            AutopilotAccelerating = true
                            if AutopilotStatus ~= "Accelerating" then
                                AutopilotStatus = "Accelerating"
                                play("apAcc","AP")
                            end
                            -- Set throttle to max
                            if not apThrottleSet then
                                AP.cmdThrottle(AutopilotInterplanetaryThrottle, true)
                                PlayerThrottle = round(AutopilotInterplanetaryThrottle,2)
                                apThrottleSet = true
                                BrakeIsOn = false
                            end
                    end
                end
                -- If it's not aligned yet, don't try to burn yet.
            end
            -- If we accidentally hit atmo while autopiloting to a custom target, cancel it and go straight to pulling up
        elseif Autopilot and (CustomTarget ~= nil and CustomTarget.planetname ~= "Space" and atmosDensity > 0) then
            msgText = "Autopilot complete, starting reentry"
            play("apCom", "AP")
            AutopilotTargetCoords = CustomTarget.position -- For setting the waypoint
            BrakeIsOn = false -- Leaving these on makes it screw up alignment...?
            AutopilotBraking = false
            Autopilot = false
            TargetSet = false
            AutopilotStatus = "Aligning" -- Disable autopilot and reset
            brakeInput = 0
            AP.cmdThrottle(0)
            apThrottleSet = false
            ProgradeIsOn = true
            spaceLand = true
            AP.showWayPoint(autopilotTargetPlanet, CustomTarget.position)
        end

        if followMode then
            -- User is assumed to be outside the construct
            autoRoll = true -- Let Nav handle that while we're here
            local targetPitch = 0
            -- Keep brake engaged at all times unless: 
            -- Ship is aligned with the target on yaw (roll and pitch are locked to 0)
            -- and ship's speed is below like 5-10m/s
            local pos = worldPos + vec3(u.getMasterPlayerRelativePosition()) -- Is this related to c forward or nah?
            local distancePos = (pos - worldPos)
            -- local distance = distancePos:len()
            -- distance needs to be calculated using only construct forward and right
            local distanceForward = vec3(distancePos):project_on(constructForward):len()
            local distanceRight = vec3(distancePos):project_on(constructRight):len()
            local distance = msqrt(distanceForward * distanceForward + distanceRight * distanceRight)
            AlignToWorldVector(distancePos:normalize())
            local targetDistance = 40
            -- local onShip = false
            -- if distanceDown < 1 then 
            --    onShip = true
            -- end
            local nearby = (distance < targetDistance)
            local maxSpeed = 100 -- Over 300kph max, but, it scales down as it approaches
            local targetSpeed = uclamp((distance - targetDistance) / 2, 10, maxSpeed)
            pitchInput2 = 0
            local aligned = (mabs(yawInput2) < 0.1)
            if (aligned and velMag < targetSpeed and not nearby) then -- or (not BrakeIsOn and onShip) then
                -- if not onShip then -- Don't mess with brake if they're on ship
                BrakeIsOn = false
                -- end
                targetPitch = -20
            else
                -- if not onShip then
                BrakeIsOn = true
                -- end
                targetPitch = 0
            end
            
            local autoPitchThreshold = 0
            -- Copied from autoroll let's hope this is how a PID works... 
            if mabs(targetPitch - adjustedPitch) > autoPitchThreshold then
                if (pitchPID == nil) then
                    pitchPID = pid.new(2 * 0.01, 0, 2 * 0.1) -- magic number tweaked to have a default factor in the 1-10 range
                end
                pitchPID:inject(targetPitch - adjustedPitch)
                local autoPitchInput = pitchPID:get()

                pitchInput2 = autoPitchInput
            end
        end

        if AltitudeHold or BrakeLanding or Reentry or VectorToTarget or LockPitch ~= nil then
            -- We want current brake value, not max
            local curBrake = LastMaxBrakeInAtmo
            if curBrake then
                curBrake = curBrake * uclamp(velMag/100,0.1,1) * atmosDensity
            else
                curBrake = LastMaxBrake
            end
            if atmosDensity < 0.01 then
                curBrake = LastMaxBrake -- Assume space brakes
            end

            local hSpd = constructForward:project_on_plane(worldVertical):normalize():dot(constructVelocity)
            local airFrictionVec = vec3(c.getWorldAirFrictionAcceleration())
            --local airFriction = msqrt(airFrictionVec:len() - airFrictionVec:project_on(up):len()) * coreMass
            local airFriction = airFrictionVec:len()*coreMass -- Actually it probably increases over duration as we drop in atmo... 
            -- Assume it will halve over our duration, if not sqrt.  We'll try sqrt because it's underestimating atm
            -- First calculate stopping to 100 - that all happens with full brake power

            -- So, hSpd.  We don't need to stop only hSpd.  But hSpd plus some percentage related to hSpd/velMag
            -- Or rather, find out what percentage of our speed is hSpd
            -- And figure out how much we need to bleed the overall speed to get hSpd to 0
            -- Well that begs the question, how do brakes even work.  Do they apply their force separately in each axis?
            -- I think so, in which case hSpd should just work on its own... 
            -- And probably, like engines, the speed that determines effectiveness is along the axis as well

            if hSpd > 100 then 
                brakeDistance, brakeTime = Kinematic.computeDistanceAndTime(hSpd, 100, coreMass, 0, 0,
                                                curBrake) --  + airFriction
                -- Then add in stopping from 100 to 0 at what averages to half brake power.  Assume no friction for this
                -- But half isn't right, this is overestimating how much force we have.  And more time is spent in the slowest, worst speeds
                -- I will arbitrarily try 1/3, 1/4, etc to see if those help.  
                -- Kinda did but it's not the problem.  The problem is using velMag and not horizontal velocity
                -- Though some of it will have to go into velMag...?  Let's try just hSpd
                -- So, hSpd is very good.  But, it takes a long time to finish and lots of altitude gets lost
                -- Even at x1 instead of 1.1 or etc, it thinks it has less brakes than it really does.  
                -- Which must be this /2.  Let's try going without that once we're slowed down
                -- That went poorly, it has less than 1x curBrake.  Let's try *0.75
                -- Better but still not right.  0.66?
                -- Still too high.  0.55?  That works pretty damn well.  
                local lastDist, brakeTime2 = Kinematic.computeDistanceAndTime(100, 0, coreMass, 0, 0, curBrake*0.55)
                brakeDistance = brakeDistance + lastDist
            else -- Just calculate it regularly assuming the value will be halved while we do it, assuming no friction
                brakeDistance, brakeTime = Kinematic.computeDistanceAndTime(hSpd, 0, coreMass, 0, 0, curBrake*0.55)
            end
            -- HoldAltitude is the alt we want to hold at

            -- Dampen this.

            -- Consider: 100m below target, but 30m/s vspeed.  We should pitch down.  
            -- Or 100m above and -30m/s vspeed.  So (Hold-Core) - vspd
            -- Scenario 1: Hold-c = -100.  Scen2: Hold-c = 100
            -- 1: 100-30 = 70     2: -100--30 = -70

            local altDiff = (HoldAltitude - coreAltitude) - vSpd -- Maybe a multiplier for vSpd here...
            -- This may be better to smooth evenly regardless of HoldAltitude.  Let's say, 2km scaling?  Should be very smooth for atmo
            -- Even better if we smooth based on their velocity
            local minmax = 200+velMag -- Previously 500+
            if Reentry or spaceLand then minMax = 2000+velMag end -- Smoother reentries
            -- Smooth the takeoffs with a velMag multiplier that scales up to 100m/s
            local velMultiplier = 1
            if AutoTakeoff then velMultiplier = uclamp(velMag/100,0.1,1) end
            local targetPitch = (utils.smoothstep(altDiff, -minmax, minmax) - 0.5) * 2 * MaxPitch * velMultiplier

                        -- atmosDensity == 0 and
            if not Reentry and not spaceLand and not VectorToTarget and constructForward:dot(constructVelocity:normalize()) < 0.99 then
                -- Widen it up and go much harder based on atmo level if we're exiting atmo and velocity is keeping up with the nose
                -- I.e. we have a lot of power and need to really get out of atmo with that power instead of feeding it to speed
                -- Scaled in a way that no change up to 10% atmo, then from 10% to 0% scales to *20 and *2
                targetPitch = (utils.smoothstep(altDiff, -minmax*uclamp(20 - 19*atmosDensity*10,1,20), minmax*uclamp(20 - 19*atmosDensity*10,1,20)) - 0.5) * 2 * MaxPitch * uclamp(2 - atmosDensity*10,1,2) * velMultiplier
                --if coreAltitude > HoldAltitude and targetPitch == -85 then
                --    BrakeIsOn = true
                --else
                --    BrakeIsOn = false
                --end
            end

            if not AltitudeHold then
                targetPitch = 0
            end
            if LockPitch ~= nil then 
                if nearPlanet and not IntoOrbit then 
                    targetPitch = LockPitch 
                else
                    LockPitch = nil
                end
            end
            autoRoll = true

            local oldInput = pitchInput2 
            
            if Reentry then

                local ReentrySpeed = mfloor(adjustedAtmoSpeedLimit)

                local brakeDistancer, brakeTimer = Kinematic.computeDistanceAndTime(velMag, ReentrySpeed/3.6, coreMass, 0, 0, LastMaxBrake - planet.gravity*9.8*coreMass)
                brakeDistancer = brakeDistancer == -1 and 5000 or brakeDistancer
                local distanceToTarget = coreAltitude - (planet.noAtmosphericDensityAltitude + brakeDistancer)
                local freeFallHeight = coreAltitude > (planet.noAtmosphericDensityAltitude + brakeDistancer*1.35)
                if freeFallHeight then
                    targetPitch = ReEntryPitch
                    if velMag <= ReentrySpeed/3.6 and velMag > (ReentrySpeed/3.6)-10 and mabs(constructVelocity:normalize():dot(constructForward)) > 0.9 and not throttleMode then
                        WasInCruise = false
                        AP.cmdThrottle(1)
                    end
                elseif throttleMode and not freeFallHeight and not inAtmo then 
                    AP.cmdCruise(ReentrySpeed, true) 
                end
                if throttleMode then
                    if velMag > ReentrySpeed/3.6 and not freeFallHeight then
                        BrakeIsOn = true
                    else
                        BrakeIsOn = false
                    end
                else
                    BrakeIsOn = false
                end
                if vSpd > 0 then BrakeIsOn = true end
                if not reentryMode then
                    targetPitch = -80
                    if atmosDensity > 0.02 then
                        msgText = "PARACHUTE DEPLOYED"
                        Reentry = false
                        BrakeLanding = true
                        targetPitch = 0
                        autoRoll = autoRollPreference
                    end
                elseif planet.noAtmosphericDensityAltitude > 0 and freeFallHeight then -- 5km is good

                    autoRoll = true -- It shouldn't actually do it, except while aligning
                elseif not freeFallHeight then
                    if not inAtmo and (throttleMode or navCom:getTargetSpeed(axisCommandId.longitudinal) ~= ReentrySpeed) then 
                        AP.cmdCruise(ReentrySpeed)
                    end
                    if velMag < ((ReentrySpeed/3.6)+1) then
                        BrakeIsOn = false
                        reentryMode = false
                        Reentry = false
                        autoRoll = true 
                    end
                end
            end

            if velMag > minAutopilotSpeed and not spaceLaunch and not VectorToTarget and not BrakeLanding and ForceAlignment then -- When do we even need this, just alt hold? lol
                AlignToWorldVector(vec3(constructVelocity))
            end
            if ReversalIsOn or ((VectorToTarget or spaceLaunch) and AutopilotTargetIndex > 0 and atmosDensity > 0.01) then
                local targetVec
                if ReversalIsOn then
                    if type(ReversalIsOn) == "table" then
                        targetVec = ReversalIsOn
                    elseif ReversalIsOn < 3 and ReversalIsOn > 0 then
                       targetVec = -worldVertical:cross(constructVelocity)*5000
                    elseif ReversalIsOn >= 3 then
                        targetVec = worldVertical:cross(constructVelocity)*5000
                    elseif ReversalIsOn < 0 then
                        targetVec = constructVelocity*25000
                    end
                elseif CustomTarget ~= nil then
                    targetVec = CustomTarget.position - worldPos
                else
                    targetVec = autopilotTargetPlanet.center - worldPos
                end

                local targetYaw = math.deg(signedRotationAngle(worldVertical:normalize(),constructVelocity,targetVec))*2
                local rollRad = math.rad(mabs(adjustedRoll))
                if velMag > minRollVelocity and atmosDensity > 0.01 then
                    local rollminmax = 1000+velMag -- Roll should taper off within 1km instead of 100m because it's aggressive
                    -- And should also very aggressively use vspd so it can counteract high rates of ascent/descent
                    -- Otherwise this matches the formula to calculate targetPitch
                    local rollAltitudeLimiter = (utils.smoothstep(altDiff-vSpd*10, -rollminmax, rollminmax) - 0.5) * 2 * MaxPitch
                    local maxRoll = uclamp(90-rollAltitudeLimiter,0,180) -- Reverse roll to fix altitude seems good (max 180 instead of max 90)
                    targetRoll = uclamp(targetYaw*2, -maxRoll, maxRoll)
                    local origTargetYaw = targetYaw
                    -- 4x weight to pitch consideration because yaw is often very weak compared and the pid needs help?
                    targetYaw = uclamp(uclamp(targetYaw,-YawStallAngle*0.80,YawStallAngle*0.80)*math.cos(rollRad) + 4*(adjustedPitch-targetPitch)*math.sin(math.rad(adjustedRoll)),-YawStallAngle*0.80,YawStallAngle*0.80) -- We don't want any yaw if we're rolled
                    -- While this already should only pitch based on current roll, it still pitches early, resulting in altitude increase before the roll kicks in
                    -- I should adjust the first part so that when rollRad is relatively far from targetRoll, it is lower
                    local rollMatchMult = 1
                    if targetRoll ~= 0 then
                        rollMatchMult = mabs(rollRad/targetRoll) -- Should scale from 0 to 1... 
                    -- Such that if target is 90 and roll is 0, we have 0%.  If it's 90 and roll is 80, we have 8/9 
                    end
                    -- But if we're going say from 90 to 0, that's bad.  
                    -- We need to definitely subtract. 
                    -- Then basically on a scale from 0 to 90 is fine enough, a little arbitrary
                    rollMatchMult = (90-uclamp(mabs(targetRoll-adjustedRoll),0,90))/90
                    -- So if we're 90 degrees apart, it does 0%, if we're 10 degrees apart it does 8/9
                    -- We should really probably also apply that to altitude pitching... but I won't, not unless I see something needing it
                    -- Also it could use some scaling otherwise tho, it doesn't pitch enough.  Taking off the min/max 0.8 to see if that helps... 
                    -- Dont think it did.  Let's do a static scale
                    -- Yeah that went pretty crazy in a bad way.  Which is weird.  It started bouncing between high and low pitch while rolled
                    -- Like the rollRad or something is dependent on velocity vector.  It also immediately rolled upside down... 
                    local rollPitch = targetPitch
                    if mabs(adjustedRoll) > 90 then rollPitch = -rollPitch end
                    targetPitch = rollMatchMult*uclamp(uclamp(rollPitch*math.cos(rollRad),-PitchStallAngle*0.8,PitchStallAngle*0.8) + mabs(uclamp(mabs(origTargetYaw)*math.sin(rollRad),-PitchStallAngle*0.80,PitchStallAngle*0.80)),-PitchStallAngle*0.80,PitchStallAngle*0.80) -- Always yaw positive 
                    -- And also it seems pitch might be backwards when we roll upside down...

                    -- But things were working great with just the rollMatchMult and vSpd*10
                    
                else
                    targetRoll = 0
                    targetYaw = uclamp(targetYaw,-YawStallAngle*0.80,YawStallAngle*0.80)
                end


                local yawDiff = currentYaw-targetYaw

                if ReversalIsOn and mabs(yawDiff) <= 0.0001 and
                                    ((type(ReversalIsOn) == "table") or 
                                     (type(ReversalIsOn) ~= "table" and ReversalIsOn < 0 and mabs(adjustedRoll) < 1)) then
                    if ReversalIsOn == -2 then AP.ToggleAltitudeHold() end
                    ReversalIsOn = nil
                    play("180Off", "BR")
                    return
                end

                if not stalling and velMag > minRollVelocity and atmosDensity > 0.01 then
                    if (yawPID == nil) then
                        yawPID = pid.new(2 * 0.01, 0, 2 * 0.1) -- magic number tweaked to have a default factor in the 1-10 range
                    end
                    yawPID:inject(yawDiff)
                    local autoYawInput = uclamp(yawPID:get(),-1,1) -- Keep it reasonable so player can override
                    yawInput2 = yawInput2 + autoYawInput
                elseif (inAtmo and abvGndDet > -1 or velMag < minRollVelocity) then

                    AlignToWorldVector(targetVec) -- Point to the target if on the ground and 'stalled'
                elseif stalling and atmosDensity > 0.01 then
                    -- Do this if we're yaw stalling
                    if (currentYaw < -YawStallAngle or currentYaw > YawStallAngle) and atmosDensity > 0.01 then
                        AlignToWorldVector(constructVelocity) -- Otherwise try to pull out of the stall, and let it pitch into it
                    end
                    -- Only do this if we're stalled for pitch
                    if (currentPitch < -PitchStallAngle or currentPitch > PitchStallAngle) and atmosDensity > 0.01 then
                        targetPitch = uclamp(adjustedPitch-currentPitch,adjustedPitch - PitchStallAngle*0.80, adjustedPitch + PitchStallAngle*0.80) -- Just try to get within un-stalling range to not bounce too much
                    end
                end
                
                if CustomTarget ~= nil and not spaceLaunch then
                    --local distanceToTarget = targetVec:project_on(velocity):len() -- Probably not strictly accurate with curvature but it should work
                    -- Well, maybe not.  Really we have a triangle.  Of course.  
                    -- We know C, our distance to target.  We know the height we'll be above the target (should be the same as our current height)
                    -- We just don't know the last leg
                    -- a2 + b2 = c2.  c2 - b2 = a2
                    local targetAltitude = planet:getAltitude(CustomTarget.position)
                    --local olddistanceToTarget = msqrt(targetVec:len()^2-(coreAltitude-targetAltitude)^2)
                    local distanceToTarget = targetVec:project_on_plane(worldVertical):len()

                    --local targetPosAtAltitude = CustomTarget.position + worldVertical*(coreAltitude - targetAltitude) - planet.center
                    --local worldPosPlanetary = worldPos - planet.center
                    --local distanceToTarget = (planet.radius+coreAltitude) * math.atan(worldPosPlanetary:cross(targetPosAtAltitude):len(), worldPosPlanetary:dot(targetPosAtAltitude))

                    --local oldhSpd = constructVelocity:len() - mabs(vSpd)
                    -- New hSpd has been moved to above where brakeDistance happens
                    --p(oldhSpd .. " old vs " .. hSpd .. " new.  Distance old: " .. olddistanceToTarget .. ", new: " .. distanceToTarget)
                
                    --StrongBrakes = ((planet.gravity * 9.80665 * coreMass) < LastMaxBrakeInAtmo)
                    StrongBrakes = true -- We don't care about this or glide landing anymore and idk where all it gets used
                    
                    -- Fudge it with the distance we'll travel in a tick - or half that and the next tick accounts for the other? idk

                    -- Just fudge it arbitrarily by 5% so that we get some feathering for better accuracy
                    -- Make it think it will take longer to brake than it will
                    if (not spaceLaunch and not Reentry and distanceToTarget <= brakeDistance and -- + (velMag*deltaTick)/2
                            (constructVelocity:project_on_plane(worldVertical):normalize():dot(targetVec:project_on_plane(worldVertical):normalize()) > 0.99  or VectorStatus == "Finalizing Approach")) then 
                        VectorStatus = "Finalizing Approach" 
                        if #apRoute>0 then
                            AP.ToggleAutopilot()
                            AP.ToggleAutopilot()
                            return
                        end
                        AP.cmdThrottle(0) -- Kill throttle in case they weren't in cruise
                        if AltitudeHold then
                            -- if not OrbitAchieved then
                                AP.ToggleAltitudeHold() -- Don't need this anymore
                            -- end
                            VectorToTarget = true -- But keep this on
                        end
                        BrakeIsOn = true
                    elseif not AutoTakeoff then
                        BrakeIsOn = false
                    end
                    if (VectorStatus == "Finalizing Approach" and (hSpd < 0.1 or distanceToTarget < 0.1 or (LastDistanceToTarget ~= nil and LastDistanceToTarget < distanceToTarget))) then
                        if not antigravOn then  
                            play("bklOn","BL")
                            BrakeLanding = true 
                        end
                        VectorToTarget = false
                        VectorStatus = "Proceeding to Waypoint"
                        collisionAlertStatus = false
                    end
                    LastDistanceToTarget = distanceToTarget
                end
            elseif VectorToTarget and atmosDensity == 0 and HoldAltitude > planet.noAtmosphericDensityAltitude and not (spaceLaunch or Reentry) then
                if CustomTarget ~= nil and autopilotTargetPlanet.name == planet.name then
                    local targetVec = CustomTarget.position - worldPos
                    local targetAltitude = planet:getAltitude(CustomTarget.position)
                    local distanceToTarget = msqrt(targetVec:len()^2-(coreAltitude-targetAltitude)^2)
                    local curBrake = LastMaxBrakeInAtmo
                    if curBrake then

                        brakeDistance, brakeTime = Kinematic.computeDistanceAndTime(velMag, 0, coreMass, 0, 0, curBrake/2)
                        StrongBrakes = true
                        if distanceToTarget <= brakeDistance + (velMag*deltaTick)/2 and constructVelocity:project_on_plane(worldVertical):normalize():dot(targetVec:project_on_plane(worldVertical):normalize()) > 0.99 then 
                            if planet.hasAtmosphere then
                                BrakeIsOn = false
                                ProgradeIsOn = false
                                reentryMode = true
                                spaceLand = false   
                                finalLand = true
                                Autopilot = false
                                -- VectorToTarget = true
                                AP.BeginReentry()
                            end
                        end
                        LastDistanceToTarget = distanceToTarget
                    end
                end
            end

            -- Altitude hold and AutoTakeoff orbiting
            if atmosDensity == 0 and (AltitudeHold and HoldAltitude > planet.noAtmosphericDensityAltitude) and not (spaceLaunch or IntoOrbit or Reentry ) then
                if not OrbitAchieved and not IntoOrbit then
                    OrbitTargetOrbit = HoldAltitude -- If AP/VectorToTarget, AP already set this.  
                    OrbitTargetSet = true
                    if VectorToTarget then orbitalParams.VectorToTarget = true end
                    AP.ToggleIntoOrbit() -- Should turn off alt hold
                    VectorToTarget = false -- WTF this gets stuck on? 
                    orbitAligned = true
                end
            end

            if stalling and atmosDensity > 0.01 and abvGndDet == -1 and velMag > minRollVelocity and VectorStatus ~= "Finalizing Approach" then
                AlignToWorldVector(constructVelocity) -- Otherwise try to pull out of the stall, and let it pitch into it
                targetPitch = uclamp(adjustedPitch-currentPitch,adjustedPitch - PitchStallAngle*0.80, adjustedPitch + PitchStallAngle*0.80) -- Just try to get within un-stalling range to not bounce too much
            end


            pitchInput2 = oldInput
            local groundDistance = -1

            if BrakeLanding then
                targetPitch = 0

                local skipLandingRate = false
                local distanceToStop = 30 
                if maxKinematicUp ~= nil and maxKinematicUp > 0 then

                    -- Funny enough, LastMaxBrakeInAtmo has stuff done to it to convert to a flat value
                    -- But we need the instant one back, to know how good we are at braking at this exact moment
                    local atmos = uclamp(atmosDensity,0.4,2) -- Assume at least 40% atmo when they land, to keep things fast in low atmo
                    local curBrake = LastMaxBrakeInAtmo * uclamp(velMag/100,0.1,1) * atmos
                    local totalNewtons = maxKinematicUp * atmos + curBrake - gravity -- Ignore air friction for leeway, KinematicUp and Brake are already in newtons
                    local weakBreakNewtons = curBrake/2 - gravity

                    local speedAfterBraking = velMag - msqrt((mabs(weakBreakNewtons/2)*20)/(0.5*coreMass))*utils.sign(weakBreakNewtons)
                    if speedAfterBraking < 0 then  
                        speedAfterBraking = 0 -- Just in case it gives us negative values
                    end
                    -- So then see if hovers can finish the job in the remaining distance

                    local brakeStopDistance
                    if velMag > 100 then
                        local brakeStopDistance1, _ = Kinematic.computeDistanceAndTime(velMag, 100, coreMass, 0, 0, curBrake)
                        local brakeStopDistance2, _ = Kinematic.computeDistanceAndTime(100, 0, coreMass, 0, 0, msqrt(curBrake))
                        brakeStopDistance = brakeStopDistance1+brakeStopDistance2
                    else
                        brakeStopDistance = Kinematic.computeDistanceAndTime(velMag, 0, coreMass, 0, 0, msqrt(curBrake))
                    end
                    if brakeStopDistance < 20 then
                        BrakeIsOn = false -- We can stop in less than 20m from just brakes, we don't need to do anything
                        -- This gets overridden later if we don't know the altitude or don't want to calculate
                    else
                        local stopDistance = 0
                        if speedAfterBraking > 100 then
                            local stopDistance1, _ = Kinematic.computeDistanceAndTime(speedAfterBraking, 100, coreMass, 0, 0, totalNewtons) 
                            local stopDistance2, _ = Kinematic.computeDistanceAndTime(100, 0, coreMass, 0, 0, maxKinematicUp * atmos + msqrt(curBrake) - gravity) -- Low brake power for the last 100kph
                            stopDistance = stopDistance1 + stopDistance2
                        else
                            stopDistance, _ = Kinematic.computeDistanceAndTime(speedAfterBraking, 0, coreMass, 0, 0, maxKinematicUp * atmos + msqrt(curBrake) - gravity) 
                        end
                        --if LandingGearGroundHeight == 0 then
                        stopDistance = (stopDistance+15+(velMag*deltaTick))*1.1 -- Add leeway for large ships with forcefields or landing gear, and for lag
                        -- And just bad math I guess
                        local knownAltitude = (CustomTarget ~= nil and planet:getAltitude(CustomTarget.position) > 0 and CustomTarget.safe)
                        
                        if knownAltitude then
                            local targetAltitude = planet:getAltitude(CustomTarget.position)
                            local distanceToGround = coreAltitude - targetAltitude - 100 -- Try to aim for like 100m above the ground, give it lots of time
                            -- We don't have to squeeze out the little bits of performance
                            local targetVec = CustomTarget.position - worldPos
                            local horizontalDistance = msqrt(targetVec:len()^2-(coreAltitude-targetAltitude)^2)

                            if horizontalDistance > 100 then
                                -- We are too far off, don't trust our altitude data
                                knownAltitude = false
                            elseif distanceToGround <= stopDistance or stopDistance == -1 then
                                BrakeIsOn = true
                                skipLandingRate = true
                            else
                                BrakeIsOn = false
                                skipLandingRate = true
                            end
                        end
                        
                        if not knownAltitude and CalculateBrakeLandingSpeed then
                            if stopDistance >= distanceToStop then -- 10% padding
                                BrakeIsOn = true
                            else
                                BrakeIsOn = false
                            end
                            skipLandingRate = true
                        end
                    end
                end
                if not throttleMode then
                    AP.cmdThrottle(0)
                end
                navCom:setTargetGroundAltitude(500)
                navCom:activateGroundEngineAltitudeStabilization(500)
                stablized = true

                groundDistance = abvGndDet
                if groundDistance > -1 then 
                        autoRoll = autoRollPreference                
                        if velMag < 1 or constructVelocity:normalize():dot(worldVertical) < 0 then -- Or if they start going back up
                            BrakeLanding = false
                            AltitudeHold = false
                            GearExtended = true
                            if hasGear then
                                Nav.control.extendLandingGears()
                                play("grOut","LG",1)
                            end
                            navCom:setTargetGroundAltitude(LandingGearGroundHeight)
                            upAmount = 0
                            BrakeIsOn = true
                        else
                            BrakeIsOn = true
                        end
                elseif StrongBrakes and (constructVelocity:normalize():dot(-up) < 0.999) then
                    BrakeIsOn = true
                elseif vSpd < -brakeLandingRate and not skipLandingRate then
                    BrakeIsOn = true
                elseif not skipLandingRate then
                    BrakeIsOn = false
                end
            end
            if AutoTakeoff or spaceLaunch then
                local intersectBody, nearSide, farSide
                if AutopilotTargetCoords ~= nil then
                    intersectBody, nearSide, farSide = galaxyReference:getPlanetarySystem(0):castIntersections(worldPos, (AutopilotTargetCoords-worldPos):normalize(), function(body) return (body.radius+body.noAtmosphericDensityAltitude) end)
                end
                if antigravOn then
                    if coreAltitude >= (HoldAltitude-50) then
                        AutoTakeoff = false
                        if not Autopilot and not VectorToTarget then
                            BrakeIsOn = true
                            AP.cmdThrottle(0)
                        end
                    else
                        HoldAltitude = antigrav.getBaseAltitude()
                    end
                elseif mabs(targetPitch) < 15 and (coreAltitude/HoldAltitude) > 0.75 then
                    AutoTakeoff = false -- No longer in ascent
                    if not spaceLaunch then 
                        if throttleMode and not AtmoSpeedAssist then
                            Nav.control.cancelCurrentControlMasterMode()
                        end
                    elseif spaceLaunch and velMag < minAutopilotSpeed then
                        Autopilot = true
                        spaceLaunch = false
                        AltitudeHold = false
                        AutoTakeoff = false
                        AP.cmdThrottle(0)
                    elseif spaceLaunch then
                        AP.cmdThrottle(0)
                        BrakeIsOn = true
                    end --coreAltitude > 75000
                elseif spaceLaunch and atmosDensity == 0 and autopilotTargetPlanet ~= nil and (intersectBody == nil or intersectBody.name == autopilotTargetPlanet.name) then
                    Autopilot = true
                    spaceLaunch = false
                    AltitudeHold = false
                    AutoTakeoff = false
                    if not throttleMode then
                        AP.cmdThrottle(0)
                    end
                    AutopilotAccelerating = true -- Skip alignment and don't warm down the engines
                end
            end
            -- Copied from autoroll let's hope this is how a PID works... 
            -- Don't pitch if there is significant roll, or if there is stall
            local onGround = abvGndDet > -1
            local pitchToUse = adjustedPitch

            if (VectorToTarget or spaceLaunch or ReversalIsOn) and not onGround and velMag > minRollVelocity and atmosDensity > 0.01 then
                local rollRad = math.rad(mabs(adjustedRoll))
                pitchToUse = adjustedPitch*mabs(math.cos(rollRad))+currentPitch*math.sin(rollRad)
            end
            -- TODO: These clamps need to be related to roll and YawStallAngle, we may be dealing with yaw?
            local pitchDiff = uclamp(targetPitch-pitchToUse, -PitchStallAngle*0.80, PitchStallAngle*0.80)
            if atmosDensity < 0.01 and VectorToTarget then
                pitchDiff = uclamp(targetPitch-pitchToUse, -85, MaxPitch) -- I guess
            elseif atmosDensity < 0.01 then
                pitchDiff = uclamp(targetPitch-pitchToUse, -MaxPitch, MaxPitch) -- I guess
            end
            if (((mabs(adjustedRoll) < 5 or VectorToTarget or ReversalIsOn)) or BrakeLanding or onGround or AltitudeHold) then
                if (pitchPID == nil) then -- Changed from 8 to 5 to help reduce problems?
                    pitchPID = pid.new(5 * 0.01, 0, 5 * 0.1) -- magic number tweaked to have a default factor in the 1-10 range
                end
                pitchPID:inject(pitchDiff)
                local autoPitchInput = pitchPID:get()
                pitchInput2 = pitchInput2 + autoPitchInput
            end
        end

        if antigrav ~= nil and (antigrav and not ExternalAGG and coreAltitude < 200000) then
                if AntigravTargetAltitude == nil or AntigravTargetAltitude < 1000 then AntigravTargetAltitude = 1000 end
                if desiredBaseAltitude ~= AntigravTargetAltitude then
                    desiredBaseAltitude = AntigravTargetAltitude
                    antigrav.setBaseAltitude(desiredBaseAltitude)
                end
        end
    end

    function ap.ToggleIntoOrbit() -- Toggle IntoOrbit mode on and off
        OrbitAchieved = false
        orbitPitch = nil
        orbitRoll = nil
        OrbitTicks = 0
        if atmosDensity == 0 then
            if IntoOrbit then
                play("orOff", "AP")
                IntoOrbit = false
                orbitAligned = false
                OrbitTargetPlanet = nil
                autoRoll = autoRollPreference
                if AltitudeHold then AltitudeHold = false AutoTakeoff = false end
                orbitalParams.VectorToTarget = false
                orbitalParams.AutopilotAlign = false
                OrbitTargetSet = false
            elseif nearPlanet then
                play("orOn", "AP")
                IntoOrbit = true
                autoRoll = true
                if OrbitTargetPlanet == nil then
                    OrbitTargetPlanet = planet
                end
                if AltitudeHold then AltitudeHold = false AutoTakeoff = false end
            else
                msgText = "Unable to engage auto-orbit, not near a planet"
            end
        else
            -- If this got called while in atmo, make sure it's all false
            IntoOrbit = false
            orbitAligned = false
            OrbitTargetPlanet = nil
            autoRoll = autoRollPreference
            if AltitudeHold then AltitudeHold = false end
            orbitalParams.VectorToTarget = false
            orbitalParams.AutopilotAlign = false
            OrbitTargetSet = false
        end
    end

    function ap.ToggleVerticalTakeoff() -- Toggle vertical takeoff mode on and off
        AltitudeHold = false
        if VertTakeOff then
            StrongBrakes = true -- We don't care about this anymore
            Reentry = false
            AutoTakeoff = false
            BrakeLanding = true
            autoRoll = true
            upAmount = 0
            if inAtmo and abvGndDet == -1 then
                BrakeLanding = false
                AltitudeHold = true
                upAmount = 0
                Nav:setEngineForceCommand('thrust analog vertical fueled ', vec3(), 1)
                AP.cmdCruise(mfloor(adjustedAtmoSpeedLimit))
            end
        else
            OrbitAchieved = false
            GearExtended = false
            Nav.control.retractLandingGears()
            navCom:setTargetGroundAltitude(TargetHoverHeight) 
            BrakeIsOn = true
        end
        VertTakeOff = not VertTakeOff
    end

    function ap.checkLOS(vector)
        local intersectBody, farSide, nearSide = galaxyReference:getPlanetarySystem(0):castIntersections(worldPos, vector,
            function(body) if body.noAtmosphericDensityAltitude > 0 then return (body.radius+body.noAtmosphericDensityAltitude) else return (body.radius+body.surfaceMaxAltitude*1.5) end end)
        local atmoDistance = farSide
        if nearSide ~= nil and farSide ~= nil then
            atmoDistance = math.min(nearSide,farSide)
        end
        if atmoDistance ~= nil then return intersectBody, atmoDistance else return nil, nil end
    end

    function ap.ToggleAutopilot() -- Toggle autopilot mode on and off

        local function ToggleVectorToTarget(SpaceTarget)
            -- This is a feature to vector toward the target destination in atmo or otherwise on-planet
            -- Uses altitude hold.  
            collisionAlertStatus = false
            VectorToTarget = not VectorToTarget
            if VectorToTarget then
                TurnBurn = false
                if not AltitudeHold and not SpaceTarget then
                    AP.ToggleAltitudeHold()
                end
            end
            VectorStatus = "Proceeding to Waypoint"
        end
        local routeOrbit = false
        if (time - apDoubleClick) < 1.5 and atmosDensity > 0 then
            if not SpaceEngines then
                msgText = "No space engines detected, Orbital Hop not supported"
                return
            end
            if planet.hasAtmosphere then
                if atmosDensity > 0 then
                    HoldAltitude = planet.noAtmosphericDensityAltitude + LowOrbitHeight
                    play("orH","OH")
                end
                apDoubleClick = -1
                if Autopilot or VectorToTarget or IntoOrbit then 
                    return 
                end
            end
        else
            apDoubleClick = time
        end
        TargetSet = false -- No matter what
        -- Toggle Autopilot, as long as the target isn't None
        if (AutopilotTargetIndex > 0 or #apRoute>0) and not Autopilot and not VectorToTarget and not spaceLaunch and not IntoOrbit then
            if 0.5 * Nav:maxForceForward() / c.g() < coreMass then  msgText = "WARNING: Heavy Loads may affect autopilot performance." msgTimer=5 end
            if #apRoute>0 and not finalLand then 
                AutopilotTargetIndex = apRoute[1]
                ATLAS.UpdateAutopilotTarget()
                table.remove(apRoute,1)
                msgText = "Route Autopilot in Progress"
                local targetVec = CustomTarget.position - worldPos
                local distanceToTarget = targetVec:project_on_plane(worldVertical):len()
                if distanceToTarget > 50000 and CustomTarget.planetname == planet.name then 
                    routeOrbit=true
                end
            end
            ATLAS.UpdateAutopilotTarget() -- Make sure we're updated
            AP.showWayPoint(autopilotTargetPlanet, AutopilotTargetCoords)

            if CustomTarget ~= nil then
                LockPitch = nil
                SpaceTarget = (CustomTarget.planetname == "Space")
                if SpaceTarget then
                    play("apSpc", "AP")
                    if atmosDensity ~= 0 then 
                        spaceLaunch = true
                        AP.ToggleAltitudeHold()
                    else
                        Autopilot = true
                    end
                elseif planet.name  == CustomTarget.planetname then
                    StrongBrakes = true
                    if atmosDensity > 0 then
                        if not VectorToTarget then
                            play("vtt", "AP")
                            ToggleVectorToTarget(SpaceTarget)
                            if routeOrbit then
                                HoldAltitude = planet.noAtmosphericDensityAltitude + LowOrbitHeight
                            end
                        end
                    else
                        play("apOn", "AP")
                        if not (autopilotTargetPlanet.name == planet.name and coreAltitude < (AutopilotTargetOrbit*1.5) ) then
                            OrbitAchieved = false
                            Autopilot = true
                        elseif not inAtmo then
                            if IntoOrbit then AP.ToggleIntoOrbit() end -- Reset all appropriate vars
                            OrbitTargetOrbit = planet.noAtmosphericDensityAltitude + LowOrbitHeight
                            OrbitTargetSet = true
                            orbitalParams.AutopilotAlign = true
                            orbitalParams.VectorToTarget = true
                            orbitAligned = false
                            if not IntoOrbit then AP.ToggleIntoOrbit() end
                        end
                    end
                else
                    play("apP", "AP")
                    RetrogradeIsOn = false
                    ProgradeIsOn = false
                    if atmosDensity ~= 0 then 
                        spaceLaunch = true
                        AP.ToggleAltitudeHold() 
                    else
                        Autopilot = true
                    end
                end
            elseif atmosDensity == 0 then -- Planetary autopilot
                if CustomTarget == nil and (autopilotTargetPlanet.name == planet.name and nearPlanet) and not IntoOrbit then
                    WaypointSet = false
                    OrbitAchieved = false
                    orbitAligned = false
                    AP.ToggleIntoOrbit() -- this works much better here
                else
                    play("apP","AP")
                    Autopilot = true
                    RetrogradeIsOn = false
                    ProgradeIsOn = false
                    AutopilotRealigned = false
                    followMode = false
                    AltitudeHold = false
                    BrakeLanding = false
                    Reentry = false
                    AutoTakeoff = false
                    apThrottleSet = false
                    LockPitch = nil
                    WaypointSet = false
                end
            else
                play("apP", "AP")
                spaceLaunch = true
                AP.ToggleAltitudeHold()
            end
        else
            play("apOff", "AP")
            AP.ResetAutopilots(1)
        end
    end

    function ap.routeWP(getRoute, clear, loadit)
        if loadit then 
            if loadit == 1 then 
                apRoute = {}
                apRoute = addTable(apRoute,saveRoute)
                if #apRoute>0 then 
                    msgText = "Route Loaded" 
                else
                    msgText = "No Saved Route found on Databank"
                end
            return apRoute 
            else
                saveRoute = {} 
                saveRoute = addTable(saveRoute, apRoute) msgText = "Route Saved" SaveDataBank() return 
            end
        end
        if getRoute then return apRoute end
        if clear then 
            apRoute = {}
            msgText = "Current Route Cleared"
        else
            apRoute[#apRoute+1]=AutopilotTargetIndex
            msgText = "Added "..CustomTarget.name.." to route. "
            p("Added "..CustomTarget.name.." to route. Total Route: "..json.encode(apRoute))
        end
        return apRoute
    end

    function ap.cmdThrottle(value, dontSwitch) -- sets the throttle value to value, also switches to throttle mode (vice cruise) unless dontSwitch passed
        if navCom:getAxisCommandType(0) ~= axisCommandType.byThrottle and not dontSwitch then
            Nav.control.cancelCurrentControlMasterMode()
        end
        navCom:setThrottleCommand(axisCommandId.longitudinal, value)
        PlayerThrottle = uclamp(round(value*100,0)/100, -1, 1)
        setCruiseSpeed = nil
    end

    function ap.cmdCruise(value, dontSwitch) -- sets the cruise target speed to value, also switches to cruise mode (vice throttle) unless dontSwitch passed
        if navCom:getAxisCommandType(0) ~= axisCommandType.byTargetSpeed and not dontSwitch then
            Nav.control.cancelCurrentControlMasterMode()
        end
        navCom:setTargetSpeedCommand(axisCommandId.longitudinal, value)
        setCruiseSpeed = value
    end

    function ap.ToggleLockPitch()
        if LockPitch == nil then
            play("lkPOn","LP")
            if not holdingShift then LockPitch = adjustedPitch
            else LockPitch = LockPitchTarget end
            AutoTakeoff = false
            AltitudeHold = false
            BrakeLanding = false
        else
            play("lkPOff","LP")
            LockPitch = nil
        end
    end
    
    function ap.ToggleAltitudeHold()  -- Toggle Altitude Hold mode on and off
        if (time - ahDoubleClick) < 1.5 then
            if planet.hasAtmosphere  then
                if atmosDensity > 0 then

                    HoldAltitude = planet.spaceEngineMinAltitude - 0.01*planet.noAtmosphericDensityAltitude
                    play("11","EP")
                else
                    if nearPlanet then
                        HoldAltitude = planet.noAtmosphericDensityAltitude + LowOrbitHeight
                        OrbitTargetOrbit = HoldAltitude
                        OrbitTargetSet = true
                        if not IntoOrbit then AP.ToggleIntoOrbit() end
                        orbitAligned = true
                    end
                end
                ahDoubleClick = -1
                if AltitudeHold or IntoOrbit or VertTakeOff then 
                    return 
                end
            end
        else
            ahDoubleClick = time
        end
        if nearPlanet and atmosDensity == 0 then
            OrbitTargetOrbit = coreAltitude
            OrbitTargetSet = true
            orbitAligned = true
            AP.ToggleIntoOrbit()
            if IntoOrbit then
                ahDoubleClick = time
            else
                ahDoubleClick = 0
            end
            return 
        end        
        AltitudeHold = not AltitudeHold
        BrakeLanding = false
        Reentry = false
        if AltitudeHold then
            Autopilot = false
            ProgradeIsOn = false
            RetrogradeIsOn = false
            followMode = false
            autoRoll = true
            LockPitch = nil
            OrbitAchieved = false
            if abvGndDet ~= -1 and velMag < 20 then
                play("lfs", "LS")
                AutoTakeoff = true
                if ahDoubleClick > -1 then HoldAltitude = coreAltitude + AutoTakeoffAltitude end
                GearExtended = false
                Nav.control.retractLandingGears()
                BrakeIsOn = true
                navCom:setTargetGroundAltitude(TargetHoverHeight)
                if VertTakeOffEngine and UpVertAtmoEngine then 
                    AP.ToggleVerticalTakeoff()
                end
            else
                play("altOn","AH")
                AutoTakeoff = false
                if ahDoubleClick > -1 then
                    if nearPlanet then
                        HoldAltitude = coreAltitude
                    end
                end
                if VertTakeOff then AP.ToggleVerticalTakeoff() end
            end
            if spaceLaunch then HoldAltitude = 100000 end
        else
            play("altOff","AH")
            if IntoOrbit then AP.ToggleIntoOrbit() end
            if VertTakeOff then 
                AP.ToggleVerticalTakeoff() 
            end
            autoRoll = autoRollPreference
            AutoTakeoff = false
            VectorToTarget = false
            ahDoubleClick = 0
        end
    end

    function ap.ResetAutopilots(ap)
        if ap then 
            spaceLaunch = false
            Autopilot = false
            AutopilotRealigned = false
            apThrottleSet = false
            HoldAltitude = coreAltitude
            TargetSet = false
        end
        VectorToTarget = false
        AutoTakeoff = false
        Reentry = false
        -- We won't abort interplanetary because that would fuck everyone.
        ProgradeIsOn = false -- No reason to brake while facing prograde, but retrograde yes.
        BrakeLanding = false
        AutoLanding = false
        ReversalIsOn = nil
        if not antigravOn then
            AltitudeHold = false -- And stop alt hold
            LockPitch = nil
        end
        if VertTakeOff then
            AP.ToggleVerticalTakeoff()
        end
        if IntoOrbit then
            AP.ToggleIntoOrbit()
        end
        autoRoll = autoRollPreference
        spaceLand = false
        finalLand = false
        upAmount = 0
    end

    function ap.BrakeToggle() -- Toggle brakes on and off
        -- Toggle brakes
        BrakeIsOn = not BrakeIsOn
        if BrakeLanding then
            BrakeLanding = false
            autoRoll = autoRollPreference
        end
        if BrakeIsOn then
            play("bkOn","B",1)
            -- If they turn on brakes, disable a few things
            AP.ResetAutopilots()
        else
            play("bkOff","B",1)
        end
    end

    function ap.BeginReentry() -- Begins re-entry process
        if Reentry then
            msgText = "Re-Entry cancelled"
            play("reOff", "RE")
            Reentry = false
            autoRoll = autoRollPreference
            AltitudeHold = false
        elseif not planet.hasAtmosphere then
            msgText = "Re-Entry requirements not met: you must start out of atmosphere\n and within a planets gravity well over a planet with atmosphere"
            msgTimer = 5
        elseif not reentryMode then-- Parachute ReEntry
            Reentry = true
            if navCom:getAxisCommandType(0) ~= controlMasterModeId.cruise then
                Nav.control.cancelCurrentControlMasterMode()
            end                
            autoRoll = true
            BrakeIsOn = false
            msgText = "Beginning Parachute Re-Entry - Strap In.  Target speed: " .. adjustedAtmoSpeedLimit
            play("par", "RE")
        else --Glide Reentry
            Reentry = true
            AltitudeHold = true
            autoRoll = true
            BrakeIsOn = false
            HoldAltitude = planet.surfaceMaxAltitude + ReEntryHeight
            if HoldAltitude > planet.spaceEngineMinAltitude then HoldAltitude = planet.spaceEngineMinAltitude - 0.01*planet.noAtmosphericDensityAltitude end
            local text = getDistanceDisplayString(HoldAltitude)
            msgText = "Beginning Re-entry.  Target speed: " .. adjustedAtmoSpeedLimit .. " Target Altitude: " .. text 
            play("glide","RE")
            AP.cmdCruise(mfloor(adjustedAtmoSpeedLimit))
        end
        AutoTakeoff = false -- This got left on somewhere.. 
    end

    function ap.ToggleAntigrav() -- Toggles antigrav on and off
        if antigrav and not ExternalAGG then
            if antigravOn then
                play("aggOff","AG")
                antigrav.deactivate()
                antigrav.hide()
            else
                if AntigravTargetAltitude == nil then AntigravTargetAltitude = coreAltitude end
                if AntigravTargetAltitude < 1000 then
                    AntigravTargetAltitude = 1000
                end
                play("aggOn","AG")
                antigrav.activate()
                antigrav.show()
            end
        end
    end

    function ap.changeSpd(down)
        local mult=1
        if down then mult = -1 end
        if not holdingShift then
            if AtmoSpeedAssist and not AltIsOn and mousePause then
                local currentPlayerThrot = PlayerThrottle
                PlayerThrottle = round(uclamp(PlayerThrottle + mult*speedChangeLarge/100, -1, 1),2)
                if PlayerThrottle >= 0 and currentPlayerThrot < 0 then 
                    PlayerThrottle = 0 
                    mousePause = false
                end
            elseif AltIsOn then
                if atmosDensity > 0 or Reentry then
                    adjustedAtmoSpeedLimit = uclamp(adjustedAtmoSpeedLimit + mult*speedChangeLarge,0,AtmoSpeedLimit)
                elseif Autopilot then
                    MaxGameVelocity = uclamp(MaxGameVelocity + mult*speedChangeLarge/3.6*100,0, 8333.00)
                end
            else
                navCom:updateCommandFromActionStart(axisCommandId.longitudinal, mult*speedChangeLarge)
            end
        else
            if Autopilot or VectorToTarget or spaceLaunch or IntoOrbit then
                apScrollIndex = apScrollIndex+1*mult*-1
                if apScrollIndex > #AtlasOrdered then apScrollIndex = 1 end
                if apScrollIndex < 1 then apScrollIndex = #AtlasOrdered end
            else
                if not down then mult = 1 else mult = nil end
                ATLAS.adjustAutopilotTargetIndex(mult)
            end
        end
    end

    abvGndDet = AboveGroundLevel()

    -- UNCOMMENT BELOW LINE TO ACTIVATE A CUSTOM OVERRIDE FILE TO OVERRIDE SPECIFIC FUNCTIONS
    --for k,v in pairs(require("autoconf/custom/archhud/custom/customapclass")) do ap[k] = v end 

    return ap
end