-- Race Manager - mod entry point.
--
-- BeamNG.drive does NOT auto-load GE extensions shipped inside a mod zip;
-- this modScript runs when the zip is mounted (singleplayer mods folder, or
-- pushed by a BeamMP server on join) and loads the client bridge so its
-- BeamMP event handlers and onUpdate hook are active even before the UI app
-- is opened.
if queueExtensionToLoad then
  queueExtensionToLoad('raceManager')
else
  load('raceManager')
end
if setExtensionUnloadMode then
  setExtensionUnloadMode('raceManager', 'manual')
end
