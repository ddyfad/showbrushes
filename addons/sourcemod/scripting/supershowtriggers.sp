#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <entitylump>

#define PLUGIN_NAME "super showtriggers"
#define PLUGIN_AUTHOR "gangy & tommy"
#define PLUGIN_DESCRIPTION "Toggle brush visibility with selection mode"
#define PLUGIN_VERSION "1"
#define PLUGIN_URL "https://github.com/dowoge/supershowtriggers"

#define EF_NODRAW 32

// Chat colors
#define WHITE "\x07FFFFFF"
#define GREEN "\x0700FF00"
#define RED "\x07FF0000"
#define GOLD "\x07FFD700"

public Plugin myinfo =
{
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
}

#define SELECTION_MENU            -3
#define ENABLE_ALL                -2
#define DISABLE_ALL               -1
#define TRIGGER_MULTIPLE           0
#define TRIGGER_PUSH               1
#define TRIGGER_TELEPORT           2
#define TRIGGER_TELEPORT_RELATIVE  3
#define MAX_TYPES                  4

static const char g_NAMES[][] =
{
	"trigger_multiple",
	"trigger_push",
	"trigger_teleport",
	"trigger_teleport_relative"
};

// Which brush types does the player have enabled?
bool g_bTypeEnabled[MAXPLAYERS+1][MAX_TYPES];
// Offset for brush effects
int g_iOffsetMFEffects = -1;

// Main menu
Menu g_Menu;
Menu g_SelectionMenu;

// Selection mode
bool g_bSelectMode[MAXPLAYERS+1];
bool g_bUseSelectionMode[MAXPLAYERS+1];
ArrayList g_SelectedTriggers[MAXPLAYERS+1];
int g_iHighlightedTrigger[MAXPLAYERS+1] = {-1, ...};

// Cache of all triggers on the map
ArrayList g_AllTriggersOnMap;

enum
{
	MULTIPLE_PLAIN,
	MULTIPLE_GRAVITY_40,
	MULTIPLE_GRAVITY_NEG,
	MULTIPLE_BASEVELOCITY
};
int g_iMultipleKind[2048+1];


public void OnPluginStart()
{
	g_iOffsetMFEffects = FindSendPropInfo("CBaseEntity", "m_fEffects");
	if (g_iOffsetMFEffects == -1)
	{
		SetFailState("Could not find CBaseEntity:m_fEffects");
	}

	CreateConVar("sm_showtriggers_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD).SetString(PLUGIN_VERSION);

	RegConsoleCmd("sm_showtriggerssettings", cmdShowTriggersSettings, "Toggle trigger settings menu");
	RegConsoleCmd("sm_stsettings", cmdShowTriggersSettings, "Toggle trigger settings menu");
	RegConsoleCmd("sm_sts", cmdShowTriggersSettings, "Toggle trigger settings menu");
	RegConsoleCmd("sm_showtriggers", cmdShowTriggers, "Toggles brush visibility");
	RegConsoleCmd("sm_st", cmdShowTriggers, "Toggles brush visibility");
	RegConsoleCmd("sm_sthelp", cmdShowTriggersHelp, "Show help for trigger selection");

	// Selection commands
	RegConsoleCmd("sm_select", cmdToggleSelectMode, "Toggle aim selection mode");
	RegConsoleCmd("sm_pick", cmdPickTrigger, "Pick the trigger you're looking at");
	RegConsoleCmd("sm_confirm", cmdConfirmSelection, "Confirm trigger selection");
	RegConsoleCmd("sm_reset", cmdResetSelection, "Reset trigger selection");
	RegConsoleCmd("sm_clear", cmdClearSelection, "Clear current selection");

	Menu menu = new Menu(menuHandler_Main, MenuAction_DrawItem|MenuAction_DisplayItem);
	menu.SetTitle("Toggle Visibility");
	menu.AddItem("-2", "Enable All Triggers");
	menu.AddItem("-1", "Disable All Triggers\n\n");
	for (int i = 0; i < MAX_TYPES; i++)
	{
		menu.AddItem(IntToStringEx(i), g_NAMES[i]);
	}
	menu.AddItem("-3", "Selection");
	g_Menu = menu;

	Menu selection = new Menu(menuHandler_Selection, MenuAction_DrawItem|MenuAction_DisplayItem);
	selection.SetTitle("Trigger Selection");
	selection.ExitBackButton = true;
	selection.AddItem("select", "Selection mode");
	selection.AddItem("pick", "Pick aimed trigger");
	selection.AddItem("confirm", "Confirm selection");
	selection.AddItem("clear", "Clear selection");
	selection.AddItem("reset", "Reset selection");
	g_SelectionMenu = selection;

	// Trigger cache
	g_AllTriggersOnMap = new ArrayList();

	for (int i = 1; i <= MaxClients; i++)
	{
		g_SelectedTriggers[i] = new ArrayList();
		g_iHighlightedTrigger[i] = -1;
	}

	// Cache triggers (late load)
	CreateTimer(1.0, Timer_CacheAllTriggers, _, TIMER_FLAG_NO_MAPCHANGE);

	// Update aim targets for players in selection mode
	CreateTimer(0.1, Timer_UpdateAimTargets, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	// Cache all triggers when the map starts
	CreateTimer(1.0, Timer_CacheAllTriggers, _, TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Cache all trigger entities on the map
 */
public Action Timer_CacheAllTriggers(Handle timer)
{
	// Clear the existing cache
	g_AllTriggersOnMap.Clear();

	StringMap kinds = ReadMultipleKindsFromLump();

	// Find all trigger entities
	char className[32], hammerId[16];
	int count = 0;

	for (int ent = MaxClients + 1; ent <= 2048; ent++)
	{
		g_iMultipleKind[ent] = MULTIPLE_PLAIN;

		if (!IsValidEntity(ent))
			continue;

		GetEntityClassname(ent, className, sizeof(className));
		if (StrContains(className, "trigger_") == 0)
		{
			g_AllTriggersOnMap.Push(ent);
			count++;
		}

		if (StrEqual(className, "trigger_multiple"))
		{
			IntToString(GetEntProp(ent, Prop_Data, "m_iHammerID"), hammerId, sizeof hammerId);
			kinds.GetValue(hammerId, g_iMultipleKind[ent]);
		}
	}

	delete kinds;
	PrintToServer("Cached %d triggers on the map", count);

	return Plugin_Continue;
}

StringMap ReadMultipleKindsFromLump()
{
	StringMap kinds = new StringMap();
	char buffer[256], hammerId[16], parts[5][128];
	// Output value: "target,input,parameter,delay,once" (\x1B-separated outside CSS)
	char separator[2] = ",";
	if (GetEngineVersion() != Engine_CSS)
		separator = "\x1B";

	int length = EntityLump.Length();
	for (int i = 0; i < length; i++)
	{
		EntityLumpEntry entry = EntityLump.Get(i);
		entry.GetNextKey("classname", buffer, sizeof buffer);
		if (!StrEqual(buffer, "trigger_multiple"))
		{
			delete entry;
			continue;
		}

		int kind = MULTIPLE_PLAIN;
		int pos = -1;
		while (kind == MULTIPLE_PLAIN && (pos = entry.GetNextKey("OnStartTouch", buffer, sizeof buffer, pos)) != -1)
		{
			ExplodeString(buffer, separator, parts, sizeof parts, sizeof parts[]);
			if (StrEqual(parts[2], "gravity 40"))
				kind = MULTIPLE_GRAVITY_40;
		}
		pos = -1;
		while (kind == MULTIPLE_PLAIN && (pos = entry.GetNextKey("OnEndTouch", buffer, sizeof buffer, pos)) != -1)
		{
			ExplodeString(buffer, separator, parts, sizeof parts, sizeof parts[]);
			if (StrContains(parts[2], "gravity -") != -1)
				kind = MULTIPLE_GRAVITY_NEG;
			else if (StrContains(parts[2], "basevelocity") != -1)
				kind = MULTIPLE_BASEVELOCITY;
		}

		entry.GetNextKey("hammerid", hammerId, sizeof hammerId);
		kinds.SetValue(hammerId, kind);
		delete entry;
	}

	return kinds;
}

public void OnClientConnected(int client)
{
	// Initialize client data
	g_bUseSelectionMode[client] = false;
	g_bSelectMode[client] = false;
	g_iHighlightedTrigger[client] = -1;

	if (g_SelectedTriggers[client] != null)
	{
		delete g_SelectedTriggers[client];
	}
	g_SelectedTriggers[client] = new ArrayList();

	// Reset trigger types
	for (int i = 0; i < MAX_TYPES; i++)
	{
		g_bTypeEnabled[client][i] = false;
	}
}

public Action Timer_UpdateAimTargets(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !g_bSelectMode[client])
			continue;

		// Keep selected triggers highlighted
		int count = g_SelectedTriggers[client].Length;
		for (int i = 0; i < count; i++)
		{
			int entity = g_SelectedTriggers[client].Get(i);
			if (IsValidEntity(entity))
			{
				SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
				SetEntityRenderColor(entity, 255, 255, 0, 200);
			}
		}

		// Find what the player is aiming at
		int aimTarget = FindTriggerAtCrosshair(client);

		// Reset the previous highlight if it changed and it's not selected
		if (g_iHighlightedTrigger[client] != -1
			&& g_iHighlightedTrigger[client] != aimTarget
			&& IsValidEntity(g_iHighlightedTrigger[client])
			&& g_SelectedTriggers[client].FindValue(g_iHighlightedTrigger[client]) == -1)
		{
			ResetTriggerColor(g_iHighlightedTrigger[client]);
		}

		// Update the highlighted trigger
		g_iHighlightedTrigger[client] = aimTarget;

		// Highlight the new target if it's not already selected
		if (aimTarget != -1
			&& IsValidEntity(aimTarget)
			&& g_SelectedTriggers[client].FindValue(aimTarget) == -1)
		{
			SetEntityRenderMode(aimTarget, RENDER_TRANSCOLOR);
			SetEntityRenderColor(aimTarget, 0, 255, 255, 200);
		}
	}

	return Plugin_Continue;
}

/**
 * Find the trigger entity the client is looking at (or -1)
 */
int FindTriggerAtCrosshair(int client)
{
	if (!IsValidClient(client))
		return -1;

	float eyePos[3], eyeAngles[3], endPos[3];

	// Get the player's eye position and angles
	GetClientEyePosition(client, eyePos);
	GetClientEyeAngles(client, eyeAngles);

	// Calculate the direction vector
	float direction[3];
	GetAngleVectors(eyeAngles, direction, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(direction, direction);

	// Calculate the end position of the ray
	for (int i = 0; i < 3; i++)
	{
		endPos[i] = eyePos[i] + direction[i] * 1000.0;
	}

	// Find the closest trigger
	int closestTrigger = -1;
	float closestDist = 99999.0;

	int count = g_AllTriggersOnMap.Length;
	for (int i = 0; i < count; i++)
	{
		int entity = g_AllTriggersOnMap.Get(i);
		if (!IsValidEntity(entity))
			continue;

		// Get the trigger bounds
		float triggerOrigin[3], triggerMins[3], triggerMaxs[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", triggerOrigin);
		GetEntPropVector(entity, Prop_Data, "m_vecMins", triggerMins);
		GetEntPropVector(entity, Prop_Data, "m_vecMaxs", triggerMaxs);

		// Check if the ray intersects the trigger's bounding box
		float intersection[3];
		if (RayIntersectsBox(eyePos, endPos, triggerOrigin, triggerMins, triggerMaxs, intersection))
		{
			// Distance to the intersection point
			float dist = GetVectorDistance(eyePos, intersection);

			// Keep the closest one
			if (dist < closestDist)
			{
				closestTrigger = entity;
				closestDist = dist;
			}
		}
	}

	return closestTrigger;
}

/**
 * Check if a ray intersects an axis-aligned bounding box (slab method)
 *
 * @param rayStart        Start of the ray
 * @param rayEnd          End of the ray
 * @param boxOrigin       Origin of the box
 * @param boxMins         Mins of the box (relative to the origin)
 * @param boxMaxs         Maxs of the box (relative to the origin)
 * @param intersection    Output: the intersection point
 * @return                True if the ray intersects the box
 */
bool RayIntersectsBox(const float rayStart[3], const float rayEnd[3],
	const float boxOrigin[3], const float boxMins[3], const float boxMaxs[3],
	float intersection[3])
{
	// Convert the box to world coordinates
	float worldMins[3], worldMaxs[3];
	for (int i = 0; i < 3; i++)
	{
		worldMins[i] = boxOrigin[i] + boxMins[i];
		worldMaxs[i] = boxOrigin[i] + boxMaxs[i];
	}

	// Ray direction and length
	float rayDir[3], rayLength;
	SubtractVectors(rayEnd, rayStart, rayDir);
	rayLength = NormalizeVector(rayDir, rayDir);

	// Slab method
	float tMin = 0.0;
	float tMax = rayLength;

	// Check each axis
	for (int i = 0; i < 3; i++)
	{
		if (FloatAbs(rayDir[i]) < 0.00001)
		{
			// Ray is parallel to the slab, check if the origin is inside it
			if (rayStart[i] < worldMins[i] || rayStart[i] > worldMaxs[i])
				return false;
		}
		else
		{
			// Intersection distances with the near and far planes of the slab
			float invD = 1.0 / rayDir[i];
			float t1 = (worldMins[i] - rayStart[i]) * invD;
			float t2 = (worldMaxs[i] - rayStart[i]) * invD;

			// Swap if needed
			if (t1 > t2)
			{
				float temp = t1;
				t1 = t2;
				t2 = temp;
			}

			// Narrow the interval
			if (t1 > tMin) tMin = t1;
			if (t2 < tMax) tMax = t2;

			// Early exit
			if (tMin > tMax)
				return false;
		}
	}

	// Check that the intersection is within the ray length
	if (tMin > rayLength)
		return false;

	// Calculate the intersection point
	for (int i = 0; i < 3; i++)
	{
		intersection[i] = rayStart[i] + rayDir[i] * tMin;
	}

	return true;
}

public Action cmdShowTriggersHelp(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	PrintToChat(client, "%sShow Triggers - Help", WHITE);
	PrintToChat(client, "%s!st - Toggle visibility of triggers", WHITE);
	PrintToChat(client, "%s!sts - Open settings menu to choose trigger types", WHITE);
	PrintToChat(client, "%s!select - Toggle aim selection mode", WHITE);
	PrintToChat(client, "%s!pick - Select the trigger you're looking at", WHITE);
	PrintToChat(client, "%s!clear - Clear current selection", WHITE);
	PrintToChat(client, "%s!confirm - Confirm your selection", WHITE);
	PrintToChat(client, "%s!reset - Reset your selection", WHITE);

	return Plugin_Handled;
}

public Action cmdClearSelection(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	if (!g_bSelectMode[client])
	{
		PrintToChat(client, "%sYou must be in selection mode! Use %s!select%s first.", WHITE, GREEN, WHITE);
		return Plugin_Handled;
	}

	int count = g_SelectedTriggers[client].Length;
	if (count == 0)
	{
		PrintToChat(client, "%sYou haven't selected any triggers yet.", WHITE);
		return Plugin_Handled;
	}

	// Reset the colors of all selected triggers
	for (int i = 0; i < count; i++)
	{
		int entity = g_SelectedTriggers[client].Get(i);
		if (IsValidEntity(entity))
		{
			ResetTriggerColor(entity);
		}
	}

	g_SelectedTriggers[client].Clear();

	PrintToChat(client, "%sSelection cleared. %s%d%s triggers removed.", WHITE, GOLD, count, WHITE);

	return Plugin_Handled;
}

public Action cmdPickTrigger(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	if (!g_bSelectMode[client])
	{
		PrintToChat(client, "%sYou must be in selection mode! Use %s!select%s first.", WHITE, GREEN, WHITE);
		return Plugin_Handled;
	}

	// Find the trigger the player is looking at
	int aimTarget = FindTriggerAtCrosshair(client);

	if (aimTarget == -1 || !IsValidEntity(aimTarget))
	{
		PrintToChat(client, "%sNo trigger found. Aim directly at a trigger.", WHITE);
		return Plugin_Handled;
	}

	// Get the trigger's classname
	char className[32];
	GetEntityClassname(aimTarget, className, sizeof(className));

	// Check if it's already selected
	int index = g_SelectedTriggers[client].FindValue(aimTarget);

	if (index == -1)
	{
		// Add to the selection
		g_SelectedTriggers[client].Push(aimTarget);

		// Highlight the selected trigger
		SetEntityRenderMode(aimTarget, RENDER_TRANSCOLOR);
		SetEntityRenderColor(aimTarget, 255, 255, 0, 200);

		PrintToChat(client, "%s%sAdded%s %s%s%s to selection (%s%d%s total)",
			WHITE, GREEN, WHITE,
			GOLD, className, WHITE,
			GOLD, g_SelectedTriggers[client].Length, WHITE);
	}
	else
	{
		// Remove from the selection
		g_SelectedTriggers[client].Erase(index);

		// Show it as the highlighted (unselected) trigger
		SetEntityRenderMode(aimTarget, RENDER_TRANSCOLOR);
		SetEntityRenderColor(aimTarget, 0, 255, 255, 200);

		PrintToChat(client, "%s%sRemoved%s %s%s%s from selection (%s%d%s total)",
			WHITE, RED, WHITE,
			GOLD, className, WHITE,
			GOLD, g_SelectedTriggers[client].Length, WHITE);
	}

	return Plugin_Handled;
}

public Action cmdShowTriggers(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	// Selection mode with a confirmed selection: toggle the selected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].Length > 0)
	{
		bool anyEnabled = false;
		for (int i = 0; i < MAX_TYPES; i++)
		{
			if (g_bTypeEnabled[client][i])
			{
				anyEnabled = true;
				break;
			}
		}

		if (!anyEnabled)
		{
			// Enable all types so the selected triggers are shown
			for (int i = 0; i < MAX_TYPES; i++)
			{
				g_bTypeEnabled[client][i] = true;
			}
			CheckBrushes(ShouldRender());
			PrintToChat(client, "%sShowing %s%d selected%s triggers: %sON",
				WHITE, GOLD, g_SelectedTriggers[client].Length, WHITE, GREEN);
		}
		else
		{
			// Disable all types
			for (int i = 0; i < MAX_TYPES; i++)
			{
				g_bTypeEnabled[client][i] = false;
			}
			CheckBrushes(ShouldRender());
			PrintToChat(client, "%sShowing selected triggers: %sOFF", WHITE, RED);
		}
	}
	// Normal mode: toggle trigger_teleport
	else
	{
		// Toggle trigger_teleport visibility
		if (!g_bTypeEnabled[client][TRIGGER_TELEPORT])
		{
			g_bTypeEnabled[client][TRIGGER_TELEPORT] = true;
			CheckBrushes(ShouldRender());
			PrintToChat(client, "%sShowtriggers toggled: %sON", WHITE, GREEN);

			PrintToChat(client, "%sConsider using %s!stsettings%s or %s!select%s for more options.",
				WHITE, GREEN, WHITE, GREEN, WHITE);
		}
		else
		{
			g_bTypeEnabled[client][TRIGGER_TELEPORT] = false;
			CheckBrushes(ShouldRender());
			PrintToChat(client, "%sShowtriggers toggled: %sOFF", WHITE, RED);
		}
	}


	return Plugin_Handled;
}

public Action cmdToggleSelectMode(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	g_bSelectMode[client] = !g_bSelectMode[client];

	if (g_bSelectMode[client])
	{
		// Enable all trigger types so the player can see every trigger
		for (int i = 0; i < MAX_TYPES; i++)
		{
			g_bTypeEnabled[client][i] = true;
		}

		CheckBrushes(ShouldRender());

		// Show instructions
		PrintToChat(client, "%sUse %s!pick%s to select a trigger, %s!confirm%s when you're done.",
			WHITE, GREEN, WHITE, GREEN, WHITE);
	}
	else
	{
		// Without a confirmed selection, hide everything again
		if (!g_bUseSelectionMode[client])
		{
			for (int i = 0; i < MAX_TYPES; i++)
			{
				g_bTypeEnabled[client][i] = false;
			}

			// Reset the colors of all triggers
			int count = g_AllTriggersOnMap.Length;
			for (int i = 0; i < count; i++)
			{
				int entity = g_AllTriggersOnMap.Get(i);
				if (IsValidEntity(entity))
				{
					ResetTriggerColor(entity);
				}
			}

			CheckBrushes(ShouldRender());
		}

		PrintToChat(client, "%sSelection mode: %sOFF", WHITE, RED);
	}


	return Plugin_Handled;
}

public Action cmdConfirmSelection(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	if (g_SelectedTriggers[client].Length == 0)
	{
		PrintToChat(client, "%sYou haven't selected any triggers. Use %s!select%s first.",
			WHITE, GREEN, WHITE);
		return Plugin_Handled;
	}

	g_bUseSelectionMode[client] = true;
	g_bSelectMode[client] = false;

	// Enable all trigger types for the selected triggers
	for (int i = 0; i < MAX_TYPES; i++)
	{
		g_bTypeEnabled[client][i] = true;
	}

	// Reset the colors of the selected triggers so they show their normal colors
	int count = g_SelectedTriggers[client].Length;
	for (int i = 0; i < count; i++)
	{
		int entity = g_SelectedTriggers[client].Get(i);
		if (IsValidEntity(entity))
		{
			ResetTriggerColor(entity);
		}
	}

	CheckBrushes(ShouldRender());

	PrintToChat(client, "%sSelection confirmed! %s%d triggers%s selected.",
		WHITE, GOLD, g_SelectedTriggers[client].Length, WHITE);
	PrintToChat(client, "%sUse %s!st%s to toggle them on/off.", WHITE, GREEN, WHITE);

	PrintToChat(client, "%sUse %s!reset%s to reset your selection.", WHITE, GREEN, WHITE);


	return Plugin_Handled;
}

public Action cmdResetSelection(int client, int args)
{
	if (!IsValidClient(client))
		return Plugin_Handled;

	// Clear the selection and reset the state
	g_SelectedTriggers[client].Clear();
	g_bUseSelectionMode[client] = false;
	g_bSelectMode[client] = false;

	// Disable all trigger types
	for (int i = 0; i < MAX_TYPES; i++)
	{
		g_bTypeEnabled[client][i] = false;
	}

	CheckBrushes(ShouldRender());

	PrintToChat(client, "%sSelection reset. Use %s!st%s or %s!sts%s to show triggers normally.",
		WHITE, GREEN, WHITE, GREEN, WHITE);

	return Plugin_Handled;
}

// Display trigger menu
public Action cmdShowTriggersSettings(int client, int args)
{
	if (IsValidClient(client))
	{
		if (client)
		{
			g_Menu.Display(client, MENU_TIME_FOREVER);
		}
	}

	return Plugin_Handled;
}

public int menuHandler_Main(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof info);

			int type = StringToInt(info);
			switch (type)
			{
				case ENABLE_ALL:
				{
					// Loop through all types and enable
					for (int i = 0; i < MAX_TYPES; i++)
					{
						g_bTypeEnabled[param1][i] = true;
					}
				}
				case DISABLE_ALL:
				{
					// Loop through all types and disable
					for (int i = 0; i < MAX_TYPES; i++)
					{
						g_bTypeEnabled[param1][i] = false;
					}
				}
				case SELECTION_MENU:
				{
					g_SelectionMenu.Display(param1, MENU_TIME_FOREVER);
					return 0;
				}
				default:
				{
					// Toggle selected type
					g_bTypeEnabled[param1][type] = !g_bTypeEnabled[param1][type];
				}
			}

			CheckBrushes(ShouldRender());

			menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
		}
		// Check *_ALL items to see if they should be disabled
		case MenuAction_DrawItem:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof info);
			switch (StringToInt(info))
			{
				case ENABLE_ALL:
				{
					for (int i = 0; i < MAX_TYPES; i++)
					{
						if (!g_bTypeEnabled[param1][i])
						{
							return ITEMDRAW_DEFAULT;
						}
					}

					return ITEMDRAW_DISABLED;
				}
				case DISABLE_ALL:
				{
					for (int i = 0; i < MAX_TYPES; i++)
					{
						if (g_bTypeEnabled[param1][i])
						{
							return ITEMDRAW_DEFAULT;
						}
					}

					return ITEMDRAW_DISABLED;
				}
			}

			return ITEMDRAW_DEFAULT;
		}
		// Check which items are enabled.
		case MenuAction_DisplayItem:
		{
			char info[8];
			char text[64];
			menu.GetItem(param2, info, sizeof info, _, text, sizeof text);

			int type = StringToInt(info);
			if (type >= 0)
			{
				if (g_bTypeEnabled[param1][type])
				{
					StrCat(text, sizeof text, ": [ON]");
					return RedrawMenuItem(text);
				}
				else
				{
					StrCat(text, sizeof text, ": [OFF]");
				}
			}
		}
	}

	return 0;
}

public int menuHandler_Selection(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof info);

			if (StrEqual(info, "select"))
				cmdToggleSelectMode(param1, 0);
			else if (StrEqual(info, "pick"))
				cmdPickTrigger(param1, 0);
			else if (StrEqual(info, "confirm"))
				cmdConfirmSelection(param1, 0);
			else if (StrEqual(info, "clear"))
				cmdClearSelection(param1, 0);
			else if (StrEqual(info, "reset"))
				cmdResetSelection(param1, 0);

			menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
		}
		case MenuAction_DrawItem:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof info);

			int count = g_SelectedTriggers[param1].Length;
			if (StrEqual(info, "pick") && !g_bSelectMode[param1])
			{
				return ITEMDRAW_DISABLED;
			}
			if ((StrEqual(info, "confirm") || StrEqual(info, "clear")) && (!g_bSelectMode[param1] || count == 0))
			{
				return ITEMDRAW_DISABLED;
			}
			if (StrEqual(info, "reset") && count == 0 && !g_bUseSelectionMode[param1])
			{
				return ITEMDRAW_DISABLED;
			}

			return ITEMDRAW_DEFAULT;
		}
		case MenuAction_DisplayItem:
		{
			char info[8];
			char text[64];
			menu.GetItem(param2, info, sizeof info, _, text, sizeof text);

			if (StrEqual(info, "select"))
			{
				Format(text, sizeof text, "Selection mode: [%s]", g_bSelectMode[param1] ? "ON" : "OFF");
				return RedrawMenuItem(text);
			}

			int count = g_SelectedTriggers[param1].Length;
			if (StrEqual(info, "confirm") && count > 0)
			{
				Format(text, sizeof text, "Confirm selection (%d)", count);
				return RedrawMenuItem(text);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				g_Menu.Display(param1, MENU_TIME_FOREVER);
			}
		}
	}

	return 0;
}

public void OnClientDisconnect(int client)
{
	for (int i = 0; i < MAX_TYPES; i++)
	{
		g_bTypeEnabled[client][i] = false;
	}

	g_bUseSelectionMode[client] = false;
	g_bSelectMode[client] = false;
	g_iHighlightedTrigger[client] = -1;

	if (g_SelectedTriggers[client] != null)
	{
		g_SelectedTriggers[client].Clear();
	}

	CheckBrushes(ShouldRender());
}

public void OnPluginEnd()
{
	CheckBrushes(false);

	// Clean up the ArrayLists
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_SelectedTriggers[i] != null)
		{
			delete g_SelectedTriggers[i];
		}
	}

	if (g_AllTriggersOnMap != null)
	{
		delete g_AllTriggersOnMap;
	}
}


// ======================== Normal Functions ========================

void CheckBrushes(bool transmit)
{
	static bool hooked = false;

	// If transmit state has not changed, do nothing
	if (hooked == transmit)
	{
		return;
	}

	hooked = !hooked;

	char className[32];
	for (int ent = MaxClients + 1; ent <= 2048; ent++)
	{
		if (!IsValidEntity(ent))
		{
			continue;
		}

		GetEntityClassname(ent, className, sizeof className);
		if (StrContains(className, "func_") != 0 && StrContains(className, "trigger_") != 0)
		{
			continue;
		}

		for (int i = 0; i < MAX_TYPES; i++)
		{
			if (!StrEqual(className, g_NAMES[i]))
			{
				continue;
			}

			SDKHookCB f = INVALID_FUNCTION;
			switch (i)
			{
				case TRIGGER_MULTIPLE:          f = hookST_triggerMultiple;
				case TRIGGER_PUSH:              f = hookST_triggerPush;
				case TRIGGER_TELEPORT:          f = hookST_triggerTeleport;
				case TRIGGER_TELEPORT_RELATIVE: f = hookST_triggerTeleportRelative;
				default: break;
			}

			if (hooked)
			{
				SetEntData(ent, g_iOffsetMFEffects, GetEntData(ent, g_iOffsetMFEffects) & ~EF_NODRAW);
				ChangeEdictState(ent, g_iOffsetMFEffects);
				SetEdictFlags(ent, GetEdictFlags(ent) & ~FL_EDICT_DONTSEND);
				SDKHook(ent, SDKHook_SetTransmit, f);
			}
			else
			{
				SetEntData(ent, g_iOffsetMFEffects, GetEntData(ent, g_iOffsetMFEffects) | EF_NODRAW);
				ChangeEdictState(ent, g_iOffsetMFEffects);
				SetEdictFlags(ent, GetEdictFlags(ent) | FL_EDICT_DONTSEND);
				SDKUnhook(ent, SDKHook_SetTransmit, f);
			}

			break;
		}
	}
}

char[] IntToStringEx(int value)
{
	char result[11];
	IntToString(value, result, sizeof result);
	return result;
}

bool ShouldRender()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			for (int i = 0; i < MAX_TYPES; i++)
			{
				if (g_bTypeEnabled[client][i])
				{
					return true;
				}
			}
		}
	}

	return false;
}

void ResetTriggerColor(int entity)
{
	char className[32];
	GetEntityClassname(entity, className, sizeof(className));

	if (StrEqual(className, "trigger_multiple"))
	{
		ColorTriggerMultiple(entity);
	}
	else if (StrEqual(className, "trigger_push"))
	{
		SetEntityRenderColor(entity, 0, 255, 0, 255);
	}
	else if (StrEqual(className, "trigger_teleport") || StrEqual(className, "trigger_teleport_relative"))
	{
		SetEntityRenderColor(entity, 255, 0, 0, 255);
	}
	else
	{
		SetEntityRenderColor(entity, 255, 255, 255, 255);
	}
}

void ColorTriggerMultiple(int entity)
{
	switch (g_iMultipleKind[entity])
	{
		case MULTIPLE_GRAVITY_40:   SetEntityRenderColor(entity, 255, 100, 0, 255);
		case MULTIPLE_GRAVITY_NEG:  SetEntityRenderColor(entity, 0, 255, 185, 255);
		case MULTIPLE_BASEVELOCITY: SetEntityRenderColor(entity, 0, 255, 0, 255);
		default:                    SetEntityRenderColor(entity, 255, 255, 255, 255);
	}
}

// ======================== SetTransmit Hooks ========================

public Action hookST_triggerMultiple(int entity, int client)
{
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_MULTIPLE])
		return Plugin_Handled;

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(entity) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == entity)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(entity) == -1)
		return Plugin_Handled;

	// Normal coloring
	ColorTriggerMultiple(entity);
	return Plugin_Continue;
}

public Action hookST_triggerPush(int entity, int client)
{
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_PUSH])
		return Plugin_Handled;

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(entity) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == entity)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(entity) == -1)
		return Plugin_Handled;

	// Normal coloring
	SetEntityRenderColor(entity, 0, 255, 0, 255);
	return Plugin_Continue;
}

public Action hookST_triggerTeleport(int entity, int client)
{
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_TELEPORT])
		return Plugin_Handled;

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(entity) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == entity)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(entity) == -1)
		return Plugin_Handled;

	// Normal coloring
	SetEntityRenderColor(entity, 255, 0, 0, 255);
	return Plugin_Continue;
}

public Action hookST_triggerTeleportRelative(int entity, int client)
{
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_TELEPORT_RELATIVE])
		return Plugin_Handled;

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(entity) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == entity)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(entity) == -1)
		return Plugin_Handled;

	// Normal coloring
	SetEntityRenderColor(entity, 255, 0, 0, 255);
	return Plugin_Continue;
}

stock bool IsValidClient(int client, bool nobots = true)
{
    if (client <= 0 || client > MaxClients || !IsClientConnected(client) || (nobots && IsFakeClient(client)))
    {
        return false;
    }
    return IsClientInGame(client);
}
