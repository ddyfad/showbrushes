# showbrushes

This plugin is a [Show Triggers](https://github.com/blankbhop/improved-showtriggers) fork for SourceMod. Its former name was super showtriggers. It shows triggers and clip brushes. It adds a selection mode that uses the crosshair. A player can show all triggers or clips of a type from a menu. A player can also look at one brush, pick it, confirm the selection, and then show or hide only the picked brushes.

## Features

- The plugin shows `trigger_multiple`, `trigger_push`, `trigger_teleport` and `trigger_teleport_relative` brushes for each player. It removes `EF_NODRAW` from the brush and filters the brush for each player in a `SDKHook_SetTransmit` hook.
- The plugin colors each trigger by its type. Push triggers are green. Teleports are red. A `trigger_multiple` is orange for `gravity 40` outputs, teal for `gravity -` outputs, and green for `basevelocity` outputs. The plugin reads the outputs from the entity lump of the map with the SourceMod `EntityLump` natives. It matches each output to an entity by `hammerid`.
- The plugin reads the map file itself. Maps with LZMA compressed lumps work. The plugin decodes the compressed lumps in SourcePawn on map start. This takes a fraction of a second for the lumps it needs.
- Triggers with only `nodraw` textures have no faces in the BSP. The engine cannot draw them. For these triggers the plugin reads the brush planes from the map file and builds the polygons again. On map start it writes a studio model to `models/showbrushes/<map>_<hash>.mdl`, `.vvd` and `.dx90.vtx`. It then spawns one `prop_dynamic_override` for each trigger. The prop shows the mesh of the trigger with the same `SetTransmit` rules and colors as a brush.
- The plugin shows the clip brushes of the world in the same way. It reads the world brushes and the brushes of solid `func_brush` and `func_wall` entities from the map file and sorts them into six types: player clip, NPC clip, clip for both, invisible, nodraw, and ladder. The type comes from the brush contents and from the tool material of each side. A `func_brush` or `func_wall` with `rendermode 10` or `renderamt 0` counts as invisible with any texture. The plugin writes the clip brushes to `models/showbrushes/<map>_<hash>_clips<n>.mdl`. Each model holds one body for each type and one body for each brush. A large map gets more than one clip model. The plugin spawns one prop for each type. It spawns a prop for a single brush only while a player aims at it or has it in a selection.
- Each clip type shows the tool texture of Hammer. The materials are `materials/showbrushes/playerclip.vmt`, `npcclip.vmt`, `clip.vmt`, `invisible.vmt` and `nodraw.vmt`. They use the `tools/tools*` textures that ship with the game. The ladder type uses `ladder.vmt` with the invisible ladder texture.
- The plugin sends the model files and the vmt files to each client over the game connection with `INetChannel::SendFile`. It shows the progress in the chat. No fastdl is necessary. The plugin precaches the models without preload. Thus a client loads a model only when the plugin sends it a prop. The plugin does not send props to a client until the transfer is complete. The plugin sends the files only to a client that turns a trigger type or a clip type on while the map has nodraw triggers or clip brushes.
- The engine puts the game connection of a player in a background file mode. In this mode it sends one fragment of 256 bytes for each packet. The plugin turns this mode off during a transfer and on again when the transfer is complete.
- The plugin records each completed transfer by SteamID in `addons/sourcemod/data/showbrushes_delivered.txt`. When a recorded client joins the map again, the plugin asks the client for the vmt and mdl files with `INetChannel::RequestFile`. This requires `cl_allowupload 1` on the client. The plugin sends the files again only if the client does not have them or does not answer in 10 seconds. The plugin writes the reason for each repeated transfer to the SourceMod log.
- In selection mode (`!select`) the plugin shows every trigger and every clip. The brush under the crosshair is cyan. Picked brushes are yellow. The plugin caches all `trigger_*` entities on map start. To find the aimed brush, it traces a ray from the eyes and stops the ray at the first world hit. It then clips the ray against the brush model of each trigger with `TR_ClipRayToEntity` and against the planes of each clip brush. The plugin picks the brush the player stands in only when the ray hits no other brush.
- After `!confirm`, `!st` and `!sc` show or hide only the picked brushes. `!reset` returns to the normal mode with trigger and clip types.
- The `Clips` submenu has a `Style` entry. The `Textures` style shows the clip models. The `Beams` style draws the edges of each clip brush with beams, like the classic show clips plugins. In the `Beams` style the plugin does not send the clip models to the player. The plugin sends the beams every 2 seconds, nearest brushes first, with a limit of 480 beams for each player. It spreads them over several frames so the engine does not drop them.
- The settings menu has a `Triggers` submenu and a `Clips` submenu with the types. Both have an `Opacity` entry that cycles through 25, 50, 75 and 100 percent. The `Clips` submenu also has the `Style` entry and a `Beam width` entry with thin, normal and thick beams. The menu has a `Selection` submenu with the same actions as the chat commands: selection mode, pick, confirm, clear, and reset. The `Help` entry prints the command list.
- The plugin saves the menu settings of each player in a client preferences cookie: the trigger types, the clip types, the clip style, the beam width and the opacities. It restores them when the player joins. A player who left with clips turned on gets the models on the next join.
- The plugin saves each confirmed selection for the player and the map. It stores the trigger `hammerid` values and the clip brush indexes in the `sb_selections` table of the SourceMod `storage-local` SQLite database. When the player joins that map again, the plugin loads the selection and shows the brushes. `!reset` deletes the saved selection. The `Profile` entry of the selection submenu loads your saved selection. It can also copy the saved selection of a different player for the current map. A copy becomes your saved selection only when you `!confirm` it.

## Commands

| Command | Description |
| --- | --- |
| `sm_showtriggers`, `sm_st` | Show or hide the configured trigger types. After a confirmed selection this applies to the picked brushes. |
| `sm_showclips`, `sm_sc` | Show or hide clips. In normal mode this applies to player clips. After a confirmed selection this applies to the picked brushes. |
| `sm_showbrushessettings`, `sm_sbsettings`, `sm_sbs` | Open the settings menu with the trigger types, the clip types and the selection submenu. |
| `sm_sts` | Open the trigger types submenu. |
| `sm_scs` | Open the clip types submenu. |
| `sm_sbhelp` | Show the command list. |
| `sm_select` | Turn the selection mode on or off. |
| `sm_pick` | Add or remove the trigger or clip under the crosshair. |
| `sm_identifytrigger`, `sm_it` | Print debug info for the trigger under the crosshair. Also in the Selection submenu. |
| `sm_confirm` | Confirm the selection. `sm_st` and `sm_sc` then apply to the picked brushes. |
| `sm_clear` | Remove all brushes from the selection. |
| `sm_reset` | Remove the selection and leave the selection mode. |

## Requirements

- SourceMod 1.12 with SDKHooks and SDKTools. The `EntityLump` natives are part of 1.12.
- The vmt files in `materials/showbrushes/` in the game directory.
- `addons/sourcemod/gamedata/showbrushes.games.txt`. It contains the netchannel vtable slots and struct offsets. The Linux values are verified against the CS:S build 10897846 client and dedicated server binaries. The Windows values are derived and not verified.
- `sv_pure` at -1, 0 or 1. With `sv_pure 1` the clients need these lines in `cfg/pure_server_whitelist.txt`. The plugin adds them on load when they are missing. It only adds lines. It never removes or changes other rules. The new rules apply after the next map change. Until then the plugin holds the model transfers and tells the players and the admins. With `sv_pure 2` the clients do not load custom files at all. The plugin does not change `sv_pure`. It writes a notice to the log and to the admins, and the `Beams` clip style still works.

  ```
  whitelist
  {
  	models\showbrushes\...      any
  	materials\showbrushes\...   any
  }
  ```
- Clients must keep `sv_allowupload` at its default value of 1. Otherwise the engine discards the transferred files.

## Forced server settings

The speed of a transfer depends on the update rate and the rate of the client. The default `cl_updaterate` of CS:S is 20. With that rate a transfer of a few megabytes takes minutes. The plugin raises these server settings when the configs are executed:

| Setting | Value | Reason |
| --- | --- | --- |
| `sv_minrate` | 128000 | The rate must allow one full packet of fragments for each update. |
| `sv_minupdaterate` | The tick rate of the server, at most 100 | Each update carries one packet of fragments. |
| `sv_maxupdaterate` | The tick rate of the server, at most 100 | Only raised when the current value is lower. A value of 0 is not changed. |

The plugin only raises the values. It never lowers them. The plugin writes each change to the SourceMod log. These settings apply to all players and to all traffic of the server, not only to the transfers. Remove the plugin if you do not want that.

## Building

```sh
spcomp addons/sourcemod/scripting/showbrushes.sp
```

## Provenance

The original source of the super showtriggers plugin was lost. This source is a reconstruction from the compiled `supershowtriggers.smx`. The smx was built with SourcePawn 1.12.0.7194 on 2025-04-16 from a file with the name `cstsaver.sp`. The reconstruction uses the embedded debug information and the [improved-showtriggers](https://github.com/blankbhop/improved-showtriggers) plugin, which is the base of this plugin. A build with the same compiler gives a byte-identical `.code` section and identical `.dbg.lines` and `.dbg.locals` tables. The `.data` section differs only in the embedded compile timestamp. Function names, variable names and line numbers match the original. Later commits add features on top of the reconstructed source. In the reconstructed revision only the `memsize` field of the `.data` header cannot be reconstructed. The 1.12 compiler derives this field from a hash map with pointer keys. Thus the field varies between compiler builds for the same source.
