# super showtriggers

A [Show Triggers](https://github.com/blankbhop/improved-showtriggers) fork for SourceMod with an aim-based trigger selection mode. Besides toggling whole trigger classes from a menu, a player can look at individual triggers, pick them, confirm the selection and then toggle only those triggers on and off.

## Features

- Shows `trigger_multiple`, `trigger_push`, `trigger_teleport` and `trigger_teleport_relative` brushes per player by removing `EF_NODRAW` and filtering them in a `SDKHook_SetTransmit` hook.
- Colors triggers by type: push triggers green, teleports red, `trigger_multiple` orange for `gravity 40` outputs, teal for `gravity -` outputs and green for `basevelocity` outputs (output data is read from the map's entity lump via SourceMod's `EntityLump` natives and matched to entities by `hammerid`).
- Selection mode (`!select`): every trigger is shown, the trigger under the crosshair is highlighted cyan and picked triggers are yellow. The plugin caches all `trigger_*` entities on map start and finds the aimed trigger by intersecting the eye ray with each trigger's bounding box (slab test).
- After `!confirm`, `!st` only toggles the selected triggers. `!reset` returns to the normal per-type mode.
- The settings menu has a `Selection...` submenu with the same actions (toggle selection mode, pick, confirm, clear, reset), so selection works without chat commands.

## Commands

| Command | Description |
| --- | --- |
| `sm_showtriggers`, `sm_st` | Toggle trigger visibility (`trigger_teleport` in normal mode, the selected triggers after a confirmed selection). |
| `sm_showtriggerssettings`, `sm_stsettings`, `sm_sts` | Open the settings menu (trigger types and the selection submenu). |
| `sm_sthelp` | Print the command list. |
| `sm_select` | Toggle aim selection mode. |
| `sm_pick` | Add or remove the trigger under the crosshair. |
| `sm_confirm` | Confirm the selection and switch `sm_st` to selection mode. |
| `sm_clear` | Clear the current selection. |
| `sm_reset` | Reset the selection and leave selection mode. |

## Requirements

- SourceMod 1.12 with SDKHooks and SDKTools (the `EntityLump` natives ship with 1.12)

## Building

```sh
spcomp addons/sourcemod/scripting/supershowtriggers.sp
```

## Provenance

The original source of this plugin was lost. This source was reconstructed from the compiled `supershowtriggers.smx` (built with SourcePawn 1.12.0.7194 on 2025-04-16 from a file named `cstsaver.sp`) using its embedded debug information and the [improved-showtriggers](https://github.com/blankbhop/improved-showtriggers) plugin it was derived from. Recompiling it with the same compiler produces a byte-identical `.code` section, identical `.dbg.lines` and `.dbg.locals` tables, and a `.data` section that differs only in the embedded compile timestamp. Function names, variable names and line numbers match the original. Later commits add features on top of the reconstructed source. In the reconstructed revision the only unreconstructable difference is the `memsize` field of the `.data` header, which the 1.12 compiler derives from a pointer-keyed hash map and therefore varies between compiler builds even for identical source.
