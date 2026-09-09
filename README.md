# super showtriggers

This plugin is a [Show Triggers](https://github.com/blankbhop/improved-showtriggers) fork for SourceMod. It adds a selection mode that uses the crosshair. A player can show all triggers of a type from a menu. A player can also look at one trigger, pick it, confirm the selection, and then show or hide only the picked triggers.

## Features

- The plugin shows `trigger_multiple`, `trigger_push`, `trigger_teleport` and `trigger_teleport_relative` brushes for each player. It removes `EF_NODRAW` from the brush and filters the brush for each player in a `SDKHook_SetTransmit` hook.
- The plugin colors each trigger by its type. Push triggers are green. Teleports are red. A `trigger_multiple` is orange for `gravity 40` outputs, teal for `gravity -` outputs, and green for `basevelocity` outputs. The plugin reads the outputs from the entity lump of the map with the SourceMod `EntityLump` natives. It matches each output to an entity by `hammerid`.
- Triggers with only `nodraw` textures have no faces in the BSP. The engine cannot draw them. For these triggers the plugin reads the brush planes from the map file and builds the polygons again. On map start it writes a studio model to `models/supershowtriggers/<map>_<hash>.mdl`, `.vvd` and `.dx90.vtx`. It then spawns one `prop_dynamic_override` for each trigger. The prop shows the mesh of the trigger with the same `SetTransmit` rules and colors as a brush.
- The plugin sends the model files and `materials/supershowtriggers/trigger2.vmt` to each client over the game connection with `INetChannel::SendFile`. It shows the progress in the chat. No fastdl is necessary. The plugin precaches the model without preload. Thus a client loads the model only when the plugin sends it a stand-in prop. The plugin does not send stand-in props to a client until the transfer is complete. The plugin sends the files only to a client that turns `/st` on while the map has nodraw triggers.
- The plugin records each completed transfer by SteamID in `addons/sourcemod/data/supershowtriggers_delivered.txt`. When a recorded client joins the map again, the plugin asks the client for the vmt and mdl files with `INetChannel::RequestFile`. This requires `cl_allowupload 1` on the client. The plugin sends the files again only if the client does not have them or does not answer in 10 seconds. The plugin writes the reason for each repeated transfer to the SourceMod log.
- In selection mode (`!select`) the plugin shows every trigger. The trigger under the crosshair is cyan. Picked triggers are yellow. The plugin caches all `trigger_*` entities on map start. To find the aimed trigger, it traces a ray from the eyes and stops the ray at the first world hit. It then clips the ray against the brush model of each trigger with `TR_ClipRayToEntity`. The plugin picks the trigger the player stands in only when the ray hits no other trigger.
- After `!confirm`, `!st` shows or hides only the picked triggers. `!reset` returns to the normal mode with trigger types.
- The settings menu has a `Selection...` submenu with the same actions: selection mode, pick, confirm, clear, and reset. Selection does not require chat commands.
- The plugin saves each confirmed selection for the player and the map. It stores the trigger `hammerid` values in the `st_selections` table of the SourceMod `storage-local` SQLite database. When the player joins that map again, the plugin loads the selection and shows the triggers. `!reset` deletes the saved selection. The `Profile` entry of the selection submenu loads your saved selection. It can also copy the saved selection of a different player for the current map. A copy becomes your saved selection only when you `!confirm` it.

## Commands

| Command | Description |
| --- | --- |
| `sm_showtriggers`, `sm_st` | Show or hide triggers. In normal mode this applies to `trigger_teleport`. After a confirmed selection this applies to the picked triggers. |
| `sm_showtriggerssettings`, `sm_stsettings`, `sm_sts` | Open the settings menu with the trigger types and the selection submenu. |
| `sm_sthelp` | Show the command list. |
| `sm_select` | Turn the selection mode on or off. |
| `sm_pick` | Add or remove the trigger under the crosshair. |
| `sm_confirm` | Confirm the selection. `sm_st` then applies to the picked triggers. |
| `sm_clear` | Remove all triggers from the selection. |
| `sm_reset` | Remove the selection and leave the selection mode. |

## Requirements

- SourceMod 1.12 with SDKHooks and SDKTools. The `EntityLump` natives are part of 1.12.
- `materials/supershowtriggers/trigger2.vmt` in the game directory.
- `addons/sourcemod/gamedata/supershowtriggers.games.txt`. It contains the netchannel vtable slots and struct offsets. The Linux values are verified against the CS:S build 10897846 client and dedicated server binaries. The Windows values are derived and not verified.
- `sv_pure 1` with these lines in `cfg/pure_server_whitelist.txt`. Without them the clients do not load the transferred files. With `sv_pure 2` the clients do not load custom files at all.

  ```
  whitelist
  {
  	models\supershowtriggers\...      any
  	materials\supershowtriggers\...   any
  }
  ```
- Clients must keep `sv_allowupload` at its default value of 1. Otherwise the engine discards the transferred files.

## Building

```sh
spcomp addons/sourcemod/scripting/supershowtriggers.sp
```

## Provenance

The original source of this plugin was lost. This source is a reconstruction from the compiled `supershowtriggers.smx`. The smx was built with SourcePawn 1.12.0.7194 on 2025-04-16 from a file with the name `cstsaver.sp`. The reconstruction uses the embedded debug information and the [improved-showtriggers](https://github.com/blankbhop/improved-showtriggers) plugin, which is the base of this plugin. A build with the same compiler gives a byte-identical `.code` section and identical `.dbg.lines` and `.dbg.locals` tables. The `.data` section differs only in the embedded compile timestamp. Function names, variable names and line numbers match the original. Later commits add features on top of the reconstructed source. In the reconstructed revision only the `memsize` field of the `.data` header cannot be reconstructed. The 1.12 compiler derives this field from a hash map with pointer keys. Thus the field varies between compiler builds for the same source.
