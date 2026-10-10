-- Phoenix Race Manager - mod entry point.
--
-- BeamNG.drive does NOT auto-load GE extensions shipped inside a mod zip;
-- this modScript runs when the zip is mounted (singleplayer mods folder, or
-- pushed by a BeamMP server on join) and registers the client bridge so its
-- BeamMP event handlers and onUpdate hook are active even before the UI app
-- is opened.
--
-- setExtensionUnloadMode is the whole job: the mod manager loads every
-- 'manual' extension once the mod scripts have run. NEVER queueExtensionToLoad
-- first: BeamMP replaces it with a shim that shows every joining player a red
-- "deprecated" toast and then only calls setExtensionUnloadMode anyway. The
-- other two branches are for builds without setExtensionUnloadMode.
if setExtensionUnloadMode then
  setExtensionUnloadMode('raceManager', 'manual')
elseif queueExtensionToLoad then
  queueExtensionToLoad('raceManager')
elseif extensions and extensions.load then
  extensions.load('raceManager')
end
