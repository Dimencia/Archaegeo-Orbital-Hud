require 'src.slots'
modular = true
VERSION_NUMBER = 1.7061
script = {}-- wrappable container for all the code. Different than normal DU Lua in that things are not seperated out.

local modular = pcall(require, "autoconf/custom/archhud/Modules/globals")
if not modular then system.print("Failed to load modular globals, using .conf") goto encode end
modular = pcall(require, "autoconf/custom/archhud/Modules/hudclass")
if not modular then system.print("Failed to load modular hudclass, using .conf") goto encode end
modular = pcall(require, "autoconf/custom/archhud/Modules/apclass")
if not modular then system.print("Failed to load modular apclass, using .conf") goto encode end
modular = pcall(require, "autoconf/custom/archhud/Modules/radarclass")
if not modular then system.print("Failed to load modular radarclass, using .conf") goto encode end
modular = pcall(require, "autoconf/custom/archhud/Modules/controlclass")
if not modular then system.print("Failed to load modular controlclass, using .conf") goto encode end
success,startup = xpcall(require, function(err) system.print(err) modular = false return false end, "autoconf/custom/archhud/Modules/startup")
if success then
    startup(_G)
end
if not modular then system.print("Failed to load modular startup, using .conf") goto encode end
goto start

::encode::
require("Modules/encodedglobals")
require("Modules/encodedhudclass")
require("Modules/encodedapclass")
require("Modules/encodedradarclass")
require("Modules/encodedcontrolclass")
require("Modules/encodedstartup")
::start::
script.onStart()
