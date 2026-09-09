#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <entitylump>
#include <dhooks>

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
Menu g_ProfileMenu;

Database g_DB;
StringMap g_TriggerByHammerId;
bool g_bTriggersCached;
bool g_bRestorePending[MAXPLAYERS+1];

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

int g_iProxyTrigger[2048+1] = {-1, ...};
int g_iProxyType[2048+1];
bool g_bHooked;
ArrayList g_FacelessModels;
char g_sModelPath[PLATFORM_MAX_PATH];

Handle g_hGetPlayerNetInfo;
Handle g_hSendFile;
Handle g_hGetStreamProgress;
Handle g_hGetMsgHandler;
Handle g_hRequestFile;
DynamicHook g_hFileReceived;
DynamicHook g_hFileDenied;
KeyValues g_Delivered;
char g_sDeliveredPath[PLATFORM_MAX_PATH];
char g_sModelBase[64];
char g_sPushFiles[4][PLATFORM_MAX_PATH];
int g_iPushSize[4];
int g_iPushTotal;
int g_iFileStreamCount;
int g_iFileStreamReceive;
bool g_bClientHasModel[MAXPLAYERS+1];
bool g_bModelBusy[MAXPLAYERS+1];
Address g_MsgHandler[MAXPLAYERS+1];
int g_iHandlerHooks[MAXPLAYERS+1][2];
int g_iVerifyPending[MAXPLAYERS+1];
int g_iVerifyTicks[MAXPLAYERS+1];
int g_iPushNext[MAXPLAYERS+1];

public void OnPluginStart()
{
	g_iOffsetMFEffects = FindSendPropInfo("CBaseEntity", "m_fEffects");
	if (g_iOffsetMFEffects == -1)
	{
		SetFailState("Could not find CBaseEntity:m_fEffects");
	}

	GameData gamedata = new GameData("supershowtriggers.games");
	if (gamedata == null)
	{
		SetFailState("Missing gamedata/supershowtriggers.games.txt");
	}

	StartPrepSDKCall(SDKCall_Engine);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "GetPlayerNetInfo");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetPlayerNetInfo = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "SendFile");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSendFile = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "GetStreamProgress");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef, VDECODE_FLAG_BYREF, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef, VDECODE_FLAG_BYREF, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hGetStreamProgress = EndPrepSDKCall();
	g_iFileStreamCount = GameConfGetOffset(gamedata, "FileStreamWaitingCount");
	g_iFileStreamReceive = GameConfGetOffset(gamedata, "FileStreamReceiveBuffer");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "GetMsgHandler");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hGetMsgHandler = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "RequestFile");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hRequestFile = EndPrepSDKCall();

	g_hFileReceived = DynamicHook.FromConf(gamedata, "FileReceived");
	g_hFileDenied = DynamicHook.FromConf(gamedata, "FileDenied");
	delete gamedata;

	if (g_hGetPlayerNetInfo == null || g_hSendFile == null || g_hGetStreamProgress == null || g_iFileStreamCount == -1 || g_iFileStreamReceive == -1
		|| g_hGetMsgHandler == null || g_hRequestFile == null || g_hFileReceived == null || g_hFileDenied == null)
	{
		SetFailState("Could not prepare the netchannel calls");
	}

	BuildPath(Path_SM, g_sDeliveredPath, sizeof g_sDeliveredPath, "data/supershowtriggers_delivered.txt");
	g_Delivered = new KeyValues("Delivered");
	g_Delivered.ImportFromFile(g_sDeliveredPath);

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
	selection.AddItem("profile", "Profile");
	g_SelectionMenu = selection;

	Menu profile = new Menu(menuHandler_Profile);
	profile.SetTitle("Selection Profile");
	profile.ExitBackButton = true;
	profile.AddItem("custom", "Custom (yours)");
	profile.AddItem("copy", "Copy from player");
	g_ProfileMenu = profile;

	g_TriggerByHammerId = new StringMap();
	Database.Connect(OnDatabaseConnected, "storage-local");

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
	g_bTriggersCached = false;
	for (int i = 0; i < sizeof g_iProxyTrigger; i++)
	{
		g_iProxyTrigger[i] = -1;
	}
	BuildFacelessTriggerModel();

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
	g_TriggerByHammerId.Clear();

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
			IntToString(GetEntProp(ent, Prop_Data, "m_iHammerID"), hammerId, sizeof hammerId);
			g_TriggerByHammerId.SetValue(hammerId, ent);
			count++;
		}

		if (StrEqual(className, "trigger_multiple"))
		{
			IntToString(GetEntProp(ent, Prop_Data, "m_iHammerID"), hammerId, sizeof hammerId);
			kinds.GetValue(hammerId, g_iMultipleKind[ent]);
		}

		for (int type = 0; type < MAX_TYPES; type++)
		{
			if (StrEqual(className, g_NAMES[type]))
			{
				SpawnProxyIfFaceless(ent, type);
			}
		}
	}

	delete kinds;
	PrintToServer("Cached %d triggers on the map", count);

	g_bTriggersCached = true;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_bRestorePending[client] && IsClientInGame(client))
		{
			g_bRestorePending[client] = false;
			LoadSelection(client, "", false);
		}
	}

	return Plugin_Continue;
}

StringMap ReadMultipleKindsFromLump()
{
	StringMap kinds = new StringMap();
	char buffer[256], hammerId[16], parts[5][128];
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

public void OnClientPutInServer(int client)
{
	g_bClientHasModel[client] = false;
	g_bModelBusy[client] = false;
	g_iVerifyPending[client] = 0;
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	if (g_bTriggersCached)
	{
		LoadSelection(client, "", false);
	}
	else
	{
		g_bRestorePending[client] = true;
	}
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
	GetClientEyePosition(client, eyePos);
	GetClientEyeAngles(client, eyeAngles);

	TR_TraceRay(eyePos, eyeAngles, MASK_SOLID_BRUSHONLY, RayType_Infinite);
	TR_GetEndPosition(endPos);

	int closestTrigger = -1, insideTrigger = -1;
	float closestFraction = 1.0;

	int count = g_AllTriggersOnMap.Length;
	for (int i = 0; i < count; i++)
	{
		int entity = g_AllTriggersOnMap.Get(i);
		if (!IsValidEntity(entity))
			continue;

		TR_ClipRayToEntity(eyePos, endPos, MASK_ALL, RayType_EndPoint, entity);
		if (!TR_DidHit())
			continue;

		if (TR_StartSolid())
		{
			insideTrigger = entity;
			continue;
		}

		float fraction = TR_GetFraction();
		if (fraction < closestFraction)
		{
			closestTrigger = entity;
			closestFraction = fraction;
		}
	}

	return closestTrigger != -1 ? closestTrigger : insideTrigger;
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
	SaveSelection(client);

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
	DeleteSelection(client);

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
			else if (StrEqual(info, "profile"))
			{
				g_ProfileMenu.Display(param1, MENU_TIME_FOREVER);
				return 0;
			}

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
	g_bRestorePending[client] = false;
	g_bClientHasModel[client] = false;
	g_bModelBusy[client] = false;
	g_iVerifyPending[client] = 0;
	for (int i = 0; i < 2; i++)
	{
		if (g_iHandlerHooks[client][i] != 0)
		{
			DynamicHook.RemoveHook(g_iHandlerHooks[client][i]);
			g_iHandlerHooks[client][i] = 0;
		}
	}
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

	for (int ent = MaxClients + 1; ent <= 2048; ent++)
	{
		if (g_iProxyTrigger[ent] != -1 && IsValidEntity(ent))
		{
			RemoveEntity(ent);
		}
	}

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
	// If transmit state has not changed, do nothing
	if (g_bHooked == transmit)
	{
		return;
	}

	g_bHooked = transmit;

	char className[32];
	for (int ent = MaxClients + 1; ent <= 2048; ent++)
	{
		if (!IsValidEntity(ent))
		{
			continue;
		}

		int type = -1;
		if (g_iProxyTrigger[ent] != -1)
		{
			type = g_iProxyType[ent];
		}
		else
		{
			GetEntityClassname(ent, className, sizeof className);
			if (StrContains(className, "func_") != 0 && StrContains(className, "trigger_") != 0)
			{
				continue;
			}

			for (int i = 0; i < MAX_TYPES; i++)
			{
				if (StrEqual(className, g_NAMES[i]))
				{
					type = i;
				}
			}
		}

		if (type != -1)
		{
			SetBrushVisible(ent, type, transmit);
		}
	}
}

void SetBrushVisible(int ent, int type, bool visible)
{
	SDKHookCB f = INVALID_FUNCTION;
	switch (type)
	{
		case TRIGGER_MULTIPLE:          f = hookST_triggerMultiple;
		case TRIGGER_PUSH:              f = hookST_triggerPush;
		case TRIGGER_TELEPORT:          f = hookST_triggerTeleport;
		case TRIGGER_TELEPORT_RELATIVE: f = hookST_triggerTeleportRelative;
	}

	if (visible)
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
}

int TriggerOf(int entity)
{
	return g_iProxyTrigger[entity] != -1 ? g_iProxyTrigger[entity] : entity;
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
	switch (g_iMultipleKind[TriggerOf(entity)])
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
	int trigger = TriggerOf(entity);
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_MULTIPLE])
		return Plugin_Handled;
	if (trigger != entity && !g_bClientHasModel[client])
	{
		EnsureClientModel(client);
		return Plugin_Handled;
	}

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(trigger) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == trigger)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(trigger) == -1)
		return Plugin_Handled;

	// Normal coloring
	ColorTriggerMultiple(entity);
	return Plugin_Continue;
}

public Action hookST_triggerPush(int entity, int client)
{
	int trigger = TriggerOf(entity);
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_PUSH])
		return Plugin_Handled;
	if (trigger != entity && !g_bClientHasModel[client])
	{
		EnsureClientModel(client);
		return Plugin_Handled;
	}

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(trigger) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == trigger)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(trigger) == -1)
		return Plugin_Handled;

	// Normal coloring
	SetEntityRenderColor(entity, 0, 255, 0, 255);
	return Plugin_Continue;
}

public Action hookST_triggerTeleport(int entity, int client)
{
	int trigger = TriggerOf(entity);
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_TELEPORT])
		return Plugin_Handled;
	if (trigger != entity && !g_bClientHasModel[client])
	{
		EnsureClientModel(client);
		return Plugin_Handled;
	}

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(trigger) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == trigger)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(trigger) == -1)
		return Plugin_Handled;

	// Normal coloring
	SetEntityRenderColor(entity, 255, 0, 0, 255);
	return Plugin_Continue;
}

public Action hookST_triggerTeleportRelative(int entity, int client)
{
	int trigger = TriggerOf(entity);
	// Not enabled for this client
	if (!g_bTypeEnabled[client][TRIGGER_TELEPORT_RELATIVE])
		return Plugin_Handled;
	if (trigger != entity && !g_bClientHasModel[client])
	{
		EnsureClientModel(client);
		return Plugin_Handled;
	}

	// Selected triggers are always shown yellow in selection mode
	if (g_bSelectMode[client] && g_SelectedTriggers[client].FindValue(trigger) != -1)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 255, 255, 0, 200);
		return Plugin_Continue;
	}

	// The highlighted trigger is shown cyan
	if (g_bSelectMode[client] && g_iHighlightedTrigger[client] == trigger)
	{
		SetEntityRenderMode(entity, RENDER_TRANSCOLOR);
		SetEntityRenderColor(entity, 0, 255, 255, 200);
		return Plugin_Continue;
	}

	// With a confirmed selection, hide the unselected triggers
	if (g_bUseSelectionMode[client] && g_SelectedTriggers[client].FindValue(trigger) == -1)
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

#define BSP_IDENT        0x50534256
#define MODEL_VERSION    "2"
#define LUMP_PLANES      1
#define LUMP_NODES       5
#define LUMP_LEAFS       10
#define LUMP_MODELS      14
#define LUMP_LEAFBRUSHES 17
#define LUMP_BRUSHES     18
#define LUMP_BRUSHSIDES  19

#define MAX_POLY_POINTS 128
#define MAX_BRUSH_SIDES 256
#define BOGUS_RANGE     32768.0
#define CLIP_EPSILON    0.01

ArrayList g_PolyVerts;
ArrayList g_Polys;
ArrayList g_ModelPolys;

float g_PolyA[MAX_POLY_POINTS][3];
float g_PolyB[MAX_POLY_POINTS][3];
int g_LumpScratch[1024];

void BuildFacelessTriggerModel()
{
	delete g_FacelessModels;
	g_FacelessModels = new ArrayList();
	g_sModelPath[0] = '\0';

	char map[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof map);
	Format(path, sizeof path, "maps/%s.bsp", map);

	File f = OpenFile(path, "rb", true, "GAME");
	if (f == null)
	{
		return;
	}

	int ident, version, lumpOfs[64], lumpLen[64], lumpVer[64], entry[4];
	ReadFileCell(f, ident, 4);
	ReadFileCell(f, version, 4);
	if (ident != BSP_IDENT)
	{
		delete f;
		return;
	}
	for (int i = 0; i < 64; i++)
	{
		ReadFile(f, entry, 4, 4);
		lumpOfs[i] = entry[0];
		lumpLen[i] = entry[1];
		lumpVer[i] = entry[2];
	}

	ArrayList models = ReadLump(f, lumpOfs[LUMP_MODELS], lumpLen[LUMP_MODELS], 12, 4);
	ArrayList planes = ReadLump(f, lumpOfs[LUMP_PLANES], lumpLen[LUMP_PLANES], 5, 4);
	ArrayList brushes = ReadLump(f, lumpOfs[LUMP_BRUSHES], lumpLen[LUMP_BRUSHES], 3, 4);
	ArrayList sides = ReadLump(f, lumpOfs[LUMP_BRUSHSIDES], lumpLen[LUMP_BRUSHSIDES], 4, 2);
	ArrayList nodes = ReadLump(f, lumpOfs[LUMP_NODES], lumpLen[LUMP_NODES], 8, 4);
	ArrayList leafs = ReadLump(f, lumpOfs[LUMP_LEAFS], lumpLen[LUMP_LEAFS], lumpVer[LUMP_LEAFS] == 0 ? 14 : 8, 4);
	ArrayList leafBrushes = ReadLump(f, lumpOfs[LUMP_LEAFBRUSHES], lumpLen[LUMP_LEAFBRUSHES], 1, 2);
	delete f;

	g_PolyVerts = new ArrayList(3);
	g_Polys = new ArrayList(2);
	g_ModelPolys = new ArrayList(2);

	if (models != null && planes != null && brushes != null && sides != null && nodes != null && leafs != null && leafBrushes != null)
	{
		char buffer[64];
		int model[12];
		int length = EntityLump.Length();
		for (int i = 0; i < length; i++)
		{
			EntityLumpEntry ent = EntityLump.Get(i);
			ent.GetNextKey("classname", buffer, sizeof buffer);
			bool wanted = false;
			for (int type = 0; type < MAX_TYPES; type++)
			{
				wanted = wanted || StrEqual(buffer, g_NAMES[type]);
			}
			ent.GetNextKey("model", buffer, sizeof buffer);
			delete ent;

			if (!wanted || buffer[0] != '*')
			{
				continue;
			}
			int modelIndex = StringToInt(buffer[1]);
			if (modelIndex <= 0 || modelIndex >= models.Length)
			{
				continue;
			}
			models.GetArray(modelIndex, model, sizeof model);
			if (model[11] != 0)
			{
				continue;
			}

			int firstPoly = g_Polys.Length;
			AddModelPolys(model[9], planes, brushes, sides, nodes, leafs, leafBrushes);
			if (g_Polys.Length > firstPoly)
			{
				int range[2];
				range[0] = firstPoly;
				range[1] = g_Polys.Length - firstPoly;
				g_ModelPolys.PushArray(range);
				g_FacelessModels.Push(modelIndex);
			}
		}
	}

	delete models;
	delete planes;
	delete brushes;
	delete sides;
	delete nodes;
	delete leafs;
	delete leafBrushes;

	if (g_FacelessModels.Length > 0)
	{
		ReplaceString(map, sizeof map, "/", "_");
		if (WriteTriggerModel(map))
		{
			PrecacheModel(g_sModelPath, false);
			SetPushFiles();
			PrintToServer("%d faceless trigger models in %s", g_FacelessModels.Length, g_sModelPath);
		}
	}

	delete g_PolyVerts;
	delete g_Polys;
	delete g_ModelPolys;
}

ArrayList ReadLump(File f, int ofs, int len, int cells, int cellSize)
{
	int count = len / (cells * cellSize);
	ArrayList list = new ArrayList(cells);
	FileSeek(f, ofs, SEEK_SET);

	int perBatch = sizeof g_LumpScratch / cells;
	while (count > 0)
	{
		int batch = count < perBatch ? count : perBatch;
		if (ReadFile(f, g_LumpScratch, batch * cells, cellSize) != batch * cells)
		{
			delete list;
			return null;
		}
		for (int i = 0; i < batch; i++)
		{
			list.PushArray(g_LumpScratch[i * cells], cells);
		}
		count -= batch;
	}
	return list;
}

void AddModelPolys(int headnode, ArrayList planes, ArrayList brushes, ArrayList sides, ArrayList nodes, ArrayList leafs, ArrayList leafBrushes)
{
	ArrayList stack = new ArrayList();
	ArrayList done = new ArrayList();
	stack.Push(headnode);

	int node[8], brush[3], side[4], planeNums[MAX_BRUSH_SIDES];
	while (stack.Length > 0)
	{
		int n = stack.Get(stack.Length - 1);
		stack.Erase(stack.Length - 1);

		if (n >= 0)
		{
			if (n >= nodes.Length)
			{
				continue;
			}
			nodes.GetArray(n, node, sizeof node);
			stack.Push(node[1]);
			stack.Push(node[2]);
			continue;
		}

		int leaf = -1 - n;
		if (leaf >= leafs.Length)
		{
			continue;
		}
		int packed = leafs.Get(leaf, 6);
		int first = packed & 0xFFFF;
		int num = (packed >>> 16) & 0xFFFF;

		for (int i = first; i < first + num && i < leafBrushes.Length; i++)
		{
			int b = leafBrushes.Get(i);
			if (b >= brushes.Length || done.FindValue(b) != -1)
			{
				continue;
			}
			done.Push(b);
			brushes.GetArray(b, brush, sizeof brush);

			int planeCount = 0;
			for (int s = brush[0]; s < brush[0] + brush[1] && s < sides.Length && planeCount < MAX_BRUSH_SIDES; s++)
			{
				sides.GetArray(s, side, sizeof side);
				if (side[3] == 0 && side[0] < planes.Length)
				{
					planeNums[planeCount++] = side[0];
				}
			}

			for (int p = 0; p < planeCount; p++)
			{
				int count = BuildFace(planes, planeNums, planeCount, p);
				if (count < 3)
				{
					continue;
				}
				int range[2];
				range[0] = g_PolyVerts.Length;
				range[1] = count;
				for (int v = 0; v < count; v++)
				{
					g_PolyVerts.PushArray(g_PolyA[v]);
				}
				g_Polys.PushArray(range);
			}
		}
	}

	delete stack;
	delete done;
}

int BuildFace(ArrayList planes, const int[] planeNums, int planeCount, int faceIndex)
{
	float plane[4];
	planes.GetArray(planeNums[faceIndex], plane, 4);

	float normal[3];
	normal[0] = plane[0];
	normal[1] = plane[1];
	normal[2] = plane[2];

	int count = BaseWinding(normal, plane[3]);

	for (int i = 0; i < planeCount && count >= 3; i++)
	{
		if (i == faceIndex)
			continue;

		float clip[4];
		planes.GetArray(planeNums[i], clip, 4);
		count = ChopWinding(count, clip);
	}

	return count;
}

int BaseWinding(const float normal[3], float dist)
{
	int major = 0;
	float best = -1.0;

	for (int i = 0; i < 3; i++)
	{
		float v = FloatAbs(normal[i]);
		if (v > best)
		{
			best = v;
			major = i;
		}
	}

	float up[3];
	if (major == 2)
		up[0] = 1.0;
	else
		up[2] = 1.0;

	float d = GetVectorDotProduct(up, normal);
	for (int i = 0; i < 3; i++)
		up[i] -= d * normal[i];
	NormalizeVector(up, up);

	float org[3];
	for (int i = 0; i < 3; i++)
		org[i] = normal[i] * dist;

	float right[3];
	GetVectorCrossProduct(up, normal, right);

	for (int i = 0; i < 3; i++)
	{
		up[i] *= BOGUS_RANGE;
		right[i] *= BOGUS_RANGE;
	}

	for (int i = 0; i < 3; i++)
	{
		g_PolyA[0][i] = org[i] + up[i] - right[i];
		g_PolyA[1][i] = org[i] + up[i] + right[i];
		g_PolyA[2][i] = org[i] - up[i] + right[i];
		g_PolyA[3][i] = org[i] - up[i] - right[i];
	}

	return 4;
}

int ChopWinding(int count, const float plane[4])
{
	float dists[MAX_POLY_POINTS];
	float normal[3];
	normal[0] = plane[0];
	normal[1] = plane[1];
	normal[2] = plane[2];

	for (int i = 0; i < count; i++)
		dists[i] = GetVectorDotProduct(g_PolyA[i], normal) - plane[3];

	int out = 0;

	for (int i = 0; i < count; i++)
	{
		int j = (i + 1) % count;

		if (dists[i] <= CLIP_EPSILON)
		{
			if (out >= MAX_POLY_POINTS)
				return 0;
			g_PolyB[out][0] = g_PolyA[i][0];
			g_PolyB[out][1] = g_PolyA[i][1];
			g_PolyB[out][2] = g_PolyA[i][2];
			out++;
		}

		bool crosses = (dists[i] > CLIP_EPSILON && dists[j] < -CLIP_EPSILON)
					|| (dists[i] < -CLIP_EPSILON && dists[j] > CLIP_EPSILON);

		if (!crosses)
			continue;

		if (out >= MAX_POLY_POINTS)
			return 0;

		float t = dists[i] / (dists[i] - dists[j]);
		for (int a = 0; a < 3; a++)
			g_PolyB[out][a] = g_PolyA[i][a] + t * (g_PolyA[j][a] - g_PolyA[i][a]);
		out++;
	}

	for (int i = 0; i < out; i++)
	{
		g_PolyA[i][0] = g_PolyB[i][0];
		g_PolyA[i][1] = g_PolyB[i][1];
		g_PolyA[i][2] = g_PolyB[i][2];
	}

	return out;
}

void SpawnProxyIfFaceless(int trigger, int type)
{
	if (g_sModelPath[0] == '\0')
	{
		return;
	}

	char modelName[16];
	GetEntPropString(trigger, Prop_Data, "m_ModelName", modelName, sizeof modelName);
	if (modelName[0] != '*')
	{
		return;
	}
	int body = g_FacelessModels.FindValue(StringToInt(modelName[1]));
	if (body == -1)
	{
		return;
	}

	int prop = CreateEntityByName("prop_dynamic_override");
	if (prop == -1)
	{
		return;
	}
	DispatchKeyValue(prop, "model", "models/error.mdl");
	DispatchKeyValue(prop, "solid", "0");
	DispatchKeyValue(prop, "disableshadows", "1");
	DispatchKeyValue(prop, "disablereceiveshadows", "1");

	float origin[3], mins[3], maxs[3];
	GetEntPropVector(trigger, Prop_Send, "m_vecOrigin", origin);
	TeleportEntity(prop, origin, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(prop);
	SetEntityModel(prop, g_sModelPath);
	SetEntProp(prop, Prop_Send, "m_nBody", body);

	GetEntPropVector(trigger, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(trigger, Prop_Data, "m_vecMaxs", maxs);
	SetEntPropVector(prop, Prop_Send, "m_vecMins", mins);
	SetEntPropVector(prop, Prop_Send, "m_vecMaxs", maxs);

	g_iProxyTrigger[prop] = trigger;
	g_iProxyType[prop] = type;
	SetBrushVisible(prop, type, g_bHooked);
}

bool WriteTriggerModel(const char[] map)
{
	int n = g_ModelPolys.Length;
	int[] numVerts = new int[n];
	int[] numTris = new int[n];
	int[] vertBase = new int[n];
	int[] indexBase = new int[n];
	int totalVerts, totalIndices;
	int checksum = StringToInt(MODEL_VERSION);
	float bmin[3] = {1.0e30, ...}, bmax[3] = {-1.0e30, ...}, point[3];
	int range[2], poly[2];

	for (int i = 0; i < n; i++)
	{
		vertBase[i] = totalVerts;
		indexBase[i] = totalIndices;
		g_ModelPolys.GetArray(i, range);
		for (int p = range[0]; p < range[0] + range[1]; p++)
		{
			g_Polys.GetArray(p, poly);
			numVerts[i] += poly[1];
			numTris[i] += poly[1] - 2;
			for (int v = poly[0]; v < poly[0] + poly[1]; v++)
			{
				g_PolyVerts.GetArray(v, point);
				for (int k = 0; k < 3; k++)
				{
					checksum = ((checksum << 1) | (checksum >>> 31)) ^ view_as<int>(point[k]);
					if (point[k] < bmin[k]) bmin[k] = point[k];
					if (point[k] > bmax[k]) bmax[k] = point[k];
				}
			}
		}
		totalVerts += numVerts[i];
		totalIndices += numTris[i] * 3;
	}
	if (totalVerts == 0 || totalVerts > 65535)
	{
		return false;
	}
	for (int k = 0; k < 3; k++)
	{
		bmin[k] -= 1.0;
		bmax[k] += 1.0;
	}

	char base[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH], mdlName[64];
	Format(base, sizeof base, "models/supershowtriggers/%s_%08x", map, checksum);
	Format(mdlName, sizeof mdlName, "supershowtriggers/%s_%08x.mdl", map, checksum);
	Format(path, sizeof path, "%s.dx90.vtx", base);
	Format(g_sModelBase, sizeof g_sModelBase, "%s_%08x", map, checksum);
	if (FileExists(path, true, "GAME"))
	{
		Format(g_sModelPath, sizeof g_sModelPath, "%s.mdl", base);
		return true;
	}
	CreateDirectory("models", FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_EXEC, true, "DEFAULT_WRITE_PATH");
	CreateDirectory("models/supershowtriggers", FPERM_U_READ|FPERM_U_WRITE|FPERM_U_EXEC|FPERM_G_READ|FPERM_G_EXEC|FPERM_O_READ|FPERM_O_EXEC, true, "DEFAULT_WRITE_PATH");

	int OFF_HDR2 = 408;
	int OFF_BONE = OFF_HDR2 + 256;
	int OFF_HITBOXSET = OFF_BONE + 216;
	int OFF_BBOX = OFF_HITBOXSET + 12;
	int OFF_BONETABLE = OFF_BBOX + 68;
	int OFF_ANIMDESC = OFF_BONETABLE + 4;
	int OFF_ANIMDATA = (OFF_ANIMDESC + 100 + 15) & ~15;
	int OFF_SEQDESC = OFF_ANIMDATA + 12;
	int OFF_SEQ_WEIGHTS = OFF_SEQDESC + 212;
	int OFF_SEQ_ANIMIDX = OFF_SEQ_WEIGHTS + 4;
	int OFF_BODYPART = OFF_SEQ_ANIMIDX + 4;
	int OFF_MODELS = OFF_BODYPART + 16;
	int OFF_MESHES = OFF_MODELS + 148 * n;
	int OFF_TEXTURE = OFF_MESHES + 116 * n;
	int OFF_CDTEXTURE = OFF_TEXTURE + 64;
	int OFF_SKIN = OFF_CDTEXTURE + 4;
	int OFF_STRINGS = OFF_SKIN + 4;

	static const char strings[][] = { "default", "static_prop", "@idle", "idle", "body" };
	static const char material[] = "trigger" ... MODEL_VERSION;
	int STR_NAME = OFF_STRINGS + 1;
	int STR_DEFAULT = STR_NAME + strlen(mdlName) + 1;
	int STR_STATICPROP = STR_DEFAULT + 8;
	int STR_IDLEANIM = STR_STATICPROP + 12;
	int STR_IDLE = STR_IDLEANIM + 6;
	int STR_BODY = STR_IDLE + 5;
	int STR_TRIGGER = STR_BODY + 5;
	int STR_CDTEXTURE = STR_TRIGGER + sizeof material;
	int MDL_LENGTH = (STR_CDTEXTURE + 19 + 3) & ~3;

	Format(path, sizeof path, "%s.mdl", base);
	File f = OpenFile(path, "wb", true, "DEFAULT_WRITE_PATH");
	if (f == null)
	{
		return false;
	}

	WriteInt(f, 0x54534449);
	WriteInt(f, 48);
	WriteInt(f, checksum);
	WritePaddedString(f, mdlName, 64);
	WriteInt(f, MDL_LENGTH);
	WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteFloat(f, 0.0);
	for (int k = 0; k < 3; k++) WriteFloat(f, (bmin[k] + bmax[k]) * 0.5);
	WriteVec(f, bmin); WriteVec(f, bmax);
	WriteVec(f, bmin); WriteVec(f, bmax);
	WriteInt(f, 1);
	WriteInt(f, 1); WriteInt(f, OFF_BONE);
	WriteInt(f, 0); WriteInt(f, OFF_HITBOXSET);
	WriteInt(f, 1); WriteInt(f, OFF_HITBOXSET);
	WriteInt(f, 1); WriteInt(f, OFF_ANIMDESC);
	WriteInt(f, 1); WriteInt(f, OFF_SEQDESC);
	WriteInt(f, 0); WriteInt(f, 0);
	WriteInt(f, 1); WriteInt(f, OFF_TEXTURE);
	WriteInt(f, 1); WriteInt(f, OFF_CDTEXTURE);
	WriteInt(f, 1); WriteInt(f, 1); WriteInt(f, OFF_SKIN);
	WriteInt(f, 1); WriteInt(f, OFF_BODYPART);
	WriteInt(f, 0); WriteInt(f, OFF_HITBOXSET);
	WriteInt(f, 0); WriteInt(f, OFF_BODYPART); WriteInt(f, OFF_BODYPART);
	for (int k = 0; k < 6; k++) { WriteInt(f, 0); WriteInt(f, OFF_MESHES); }
	WriteInt(f, STR_DEFAULT);
	WriteInt(f, OFF_STRINGS); WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, OFF_MESHES);
	WriteFloat(f, 1.0); WriteInt(f, 1);
	WriteInt(f, 0); WriteInt(f, OFF_TEXTURE);
	WriteInt(f, 0);
	WriteInt(f, OFF_STRINGS); WriteInt(f, 0); WriteInt(f, OFF_TEXTURE);
	WriteInt(f, 0);
	WriteInt(f, OFF_BONETABLE);
	WriteInt(f, 0); WriteInt(f, 0);
	WriteInt(f, 0);
	WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, OFF_MESHES);
	WriteFloat(f, 0.0);
	WriteInt(f, 0);
	WriteInt(f, OFF_HDR2);
	WriteInt(f, 0);

	WriteInt(f, 0); WriteInt(f, OFF_STRINGS);
	WriteInt(f, 0); WriteFloat(f, 0.0);
	WriteInt(f, 0); WriteInt(f, STR_NAME - OFF_HDR2);
	WriteInt(f, 0); WriteInt(f, 0);
	WriteZeros(f, 256 - 32);

	WriteInt(f, STR_STATICPROP - OFF_BONE); WriteInt(f, -1);
	for (int k = 0; k < 6; k++) WriteInt(f, -1);
	for (int k = 0; k < 3; k++) WriteFloat(f, 0.0);
	WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteFloat(f, 1.0);
	for (int k = 0; k < 3; k++) WriteFloat(f, 0.0);
	for (int k = 0; k < 6; k++) WriteFloat(f, 1.0 / 32.0);
	for (int k = 0; k < 12; k++) WriteFloat(f, (k == 0 || k == 5 || k == 10) ? 1.0 : 0.0);
	for (int k = 0; k < 4; k++) WriteFloat(f, 0.0);
	WriteInt(f, 0x500); WriteInt(f, 0); WriteInt(f, 0); WriteInt(f, 0);
	WriteInt(f, STR_DEFAULT - OFF_BONE); WriteInt(f, 1);
	WriteZeros(f, 32);

	WriteInt(f, STR_DEFAULT - OFF_HITBOXSET); WriteInt(f, 1); WriteInt(f, 12);
	WriteInt(f, 0); WriteInt(f, 0); WriteVec(f, bmin); WriteVec(f, bmax);
	WriteInt(f, OFF_STRINGS - OFF_BBOX);
	WriteZeros(f, 32);

	WriteInt(f, 0);

	WriteInt(f, -OFF_ANIMDESC); WriteInt(f, STR_IDLEANIM - OFF_ANIMDESC);
	WriteFloat(f, 30.0); WriteInt(f, 0); WriteInt(f, 1);
	WriteInt(f, 0); WriteInt(f, 0);
	WriteZeros(f, 24);
	WriteInt(f, 0); WriteInt(f, OFF_ANIMDATA - OFF_ANIMDESC);
	for (int k = 0; k < 7; k++) WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, 0); WriteFloat(f, 0.0);
	WriteZeros(f, OFF_ANIMDATA - (OFF_ANIMDESC + 100));

	WriteInt(f, 0x2000);
	WriteInt(f, 0x00100000); WriteInt(f, 0x40000200);

	WriteInt(f, -OFF_SEQDESC); WriteInt(f, STR_IDLE - OFF_SEQDESC); WriteInt(f, OFF_STRINGS - OFF_SEQDESC);
	WriteInt(f, 0); WriteInt(f, -1); WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, 212);
	WriteVec(f, bmin); WriteVec(f, bmax);
	WriteInt(f, 1); WriteInt(f, OFF_SEQ_ANIMIDX - OFF_SEQDESC); WriteInt(f, 0);
	WriteInt(f, 1); WriteInt(f, 1); WriteInt(f, -1); WriteInt(f, -1);
	for (int k = 0; k < 4; k++) WriteFloat(f, 0.0);
	WriteInt(f, 0);
	WriteFloat(f, 0.2); WriteFloat(f, 0.2);
	WriteInt(f, 0); WriteInt(f, 0); WriteInt(f, 0);
	WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteFloat(f, 0.0);
	WriteInt(f, 0); WriteInt(f, 0); WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, 212);
	WriteInt(f, OFF_SEQ_WEIGHTS - OFF_SEQDESC);
	WriteInt(f, 0);
	WriteInt(f, 0); WriteInt(f, OFF_SEQ_ANIMIDX - OFF_SEQDESC);
	WriteInt(f, OFF_BODYPART - OFF_SEQDESC); WriteInt(f, 0);
	WriteInt(f, 0);
	WriteZeros(f, 28);
	WriteFloat(f, 1.0);
	WriteInt(f, 0);

	WriteInt(f, STR_BODY - OFF_BODYPART); WriteInt(f, n); WriteInt(f, 1); WriteInt(f, 16);

	char modelName[64];
	for (int i = 0; i < n; i++)
	{
		int offModel = OFF_MODELS + 148 * i;
		Format(modelName, sizeof modelName, "trigger%d", i);
		WritePaddedString(f, modelName, 64);
		WriteInt(f, 0); WriteFloat(f, 0.0);
		WriteInt(f, 1); WriteInt(f, OFF_MESHES + 116 * i - offModel);
		WriteInt(f, numVerts[i]); WriteInt(f, vertBase[i] * 48); WriteInt(f, vertBase[i] * 16);
		WriteInt(f, 0); WriteInt(f, 0);
		WriteInt(f, 0); WriteInt(f, OFF_MESHES + 116 * (i + 1) - offModel);
		WriteZeros(f, 40);
	}

	for (int i = 0; i < n; i++)
	{
		WriteInt(f, 0); WriteInt(f, OFF_MODELS + 148 * i - (OFF_MESHES + 116 * i));
		WriteInt(f, numVerts[i]); WriteInt(f, 0);
		WriteInt(f, 0); WriteInt(f, 0); WriteInt(f, 0); WriteInt(f, 0);
		WriteInt(f, i);
		WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteFloat(f, 0.0);
		WriteInt(f, 0);
		for (int k = 0; k < 8; k++) WriteInt(f, numVerts[i]);
		WriteZeros(f, 32);
	}

	WriteInt(f, STR_TRIGGER - OFF_TEXTURE); WriteZeros(f, 60);
	WriteInt(f, STR_CDTEXTURE);
	WriteInt(f, 0);

	WriteFileCell(f, 0, 1);
	WriteFileString(f, mdlName, true);
	for (int k = 0; k < sizeof strings; k++)
	{
		WriteFileString(f, strings[k], true);
	}
	WriteFileString(f, material, true);
	WriteFileString(f, "supershowtriggers/", true);
	WriteZeros(f, MDL_LENGTH - (STR_CDTEXTURE + 19));
	delete f;

	Format(path, sizeof path, "%s.vvd", base);
	f = OpenFile(path, "wb", true, "DEFAULT_WRITE_PATH");
	if (f == null)
	{
		return false;
	}
	WriteInt(f, 0x56534449);
	WriteInt(f, 4); WriteInt(f, checksum); WriteInt(f, 1);
	for (int k = 0; k < 8; k++) WriteInt(f, totalVerts);
	WriteInt(f, 0); WriteInt(f, 64); WriteInt(f, 64); WriteInt(f, 64 + 48 * totalVerts);

	float normal[3], tangent[3];
	for (int pass = 0; pass < 2; pass++)
	{
		for (int p = 0; p < g_Polys.Length; p++)
		{
			g_Polys.GetArray(p, poly);
			PolygonNormal(poly[0], normal);
			for (int v = poly[0]; v < poly[0] + poly[1]; v++)
			{
				g_PolyVerts.GetArray(v, point);
				if (pass == 0)
				{
					WriteFloat(f, 1.0); WriteFloat(f, 0.0); WriteFloat(f, 0.0); WriteInt(f, 0x01000000);
					WriteVec(f, point);
					WriteVec(f, normal);
					WritePlanarUV(f, point, normal);
				}
				else
				{
					TangentFor(normal, tangent);
					WriteVec(f, tangent);
					WriteFloat(f, 1.0);
				}
			}
		}
	}
	delete f;

	int OFF_VTX_MODEL = 36 + 8;
	int OFF_VTX_LOD = OFF_VTX_MODEL + 8 * n;
	int OFF_VTX_MESH = OFF_VTX_LOD + 12 * n;
	int OFF_VTX_SG = OFF_VTX_MESH + 9 * n;
	int OFF_VTX_STRIP = OFF_VTX_SG + 25 * n;
	int OFF_VTX_VERTS = OFF_VTX_STRIP + 27 * n;
	int OFF_VTX_INDICES = OFF_VTX_VERTS + 9 * totalVerts;
	int OFF_VTX_BONECHANGES = OFF_VTX_INDICES + 2 * totalIndices;
	int OFF_VTX_MATREPLIST = OFF_VTX_BONECHANGES + 8 * n;

	Format(path, sizeof path, "%s.dx90.vtx", base);
	f = OpenFile(path, "wb", true, "DEFAULT_WRITE_PATH");
	if (f == null)
	{
		return false;
	}
	WriteInt(f, 7); WriteInt(f, 24); WriteShort(f, 53); WriteShort(f, 9); WriteInt(f, 3);
	WriteInt(f, checksum); WriteInt(f, 1); WriteInt(f, OFF_VTX_MATREPLIST);
	WriteInt(f, 1); WriteInt(f, 36);
	WriteInt(f, n); WriteInt(f, 8);
	for (int i = 0; i < n; i++)
	{
		WriteInt(f, 1); WriteInt(f, (OFF_VTX_LOD + 12 * i) - (OFF_VTX_MODEL + 8 * i));
	}
	for (int i = 0; i < n; i++)
	{
		WriteInt(f, 1); WriteInt(f, (OFF_VTX_MESH + 9 * i) - (OFF_VTX_LOD + 12 * i)); WriteFloat(f, 0.0);
	}
	for (int i = 0; i < n; i++)
	{
		WriteInt(f, 1); WriteInt(f, (OFF_VTX_SG + 25 * i) - (OFF_VTX_MESH + 9 * i)); WriteFileCell(f, 0, 1);
	}
	for (int i = 0; i < n; i++)
	{
		int offGroup = OFF_VTX_SG + 25 * i;
		WriteInt(f, numVerts[i]); WriteInt(f, (OFF_VTX_VERTS + 9 * vertBase[i]) - offGroup);
		WriteInt(f, numTris[i] * 3); WriteInt(f, (OFF_VTX_INDICES + 2 * indexBase[i]) - offGroup);
		WriteInt(f, 1); WriteInt(f, (OFF_VTX_STRIP + 27 * i) - offGroup); WriteFileCell(f, 2, 1);
	}
	for (int i = 0; i < n; i++)
	{
		int offStrip = OFF_VTX_STRIP + 27 * i;
		WriteInt(f, numTris[i] * 3); WriteInt(f, 0); WriteInt(f, numVerts[i]); WriteInt(f, 0);
		WriteShort(f, 1); WriteFileCell(f, 1, 1);
		WriteInt(f, 1); WriteInt(f, (OFF_VTX_BONECHANGES + 8 * i) - offStrip);
	}
	for (int i = 0; i < n; i++)
	{
		for (int k = 0; k < numVerts[i]; k++)
		{
			WriteFileCell(f, 0, 1); WriteFileCell(f, 1, 1); WriteFileCell(f, 2, 1); WriteFileCell(f, 1, 1);
			WriteShort(f, k);
			WriteFileCell(f, 0, 1); WriteFileCell(f, 0, 1); WriteFileCell(f, 0, 1);
		}
	}
	for (int i = 0; i < n; i++)
	{
		g_ModelPolys.GetArray(i, range);
		int first = 0;
		for (int p = range[0]; p < range[0] + range[1]; p++)
		{
			g_Polys.GetArray(p, poly);
			for (int k = 1; k < poly[1] - 1; k++)
			{
				WriteShort(f, first); WriteShort(f, first + k); WriteShort(f, first + k + 1);
			}
			first += poly[1];
		}
	}
	for (int i = 0; i < n; i++)
	{
		WriteInt(f, 0); WriteInt(f, 0);
	}
	WriteInt(f, 0); WriteInt(f, 0);
	delete f;

	Format(g_sModelPath, sizeof g_sModelPath, "%s.mdl", base);
	return true;
}

void PolygonNormal(int firstVert, float normal[3])
{
	float a[3], b[3], c[3], ab[3], ac[3];
	g_PolyVerts.GetArray(firstVert, a);
	g_PolyVerts.GetArray(firstVert + 1, b);
	g_PolyVerts.GetArray(firstVert + 2, c);
	SubtractVectors(b, a, ab);
	SubtractVectors(c, a, ac);
	GetVectorCrossProduct(ab, ac, normal);
	if (GetVectorLength(normal) < 0.000001)
	{
		normal[0] = 0.0; normal[1] = 0.0; normal[2] = 1.0;
		return;
	}
	NormalizeVector(normal, normal);
}

void TangentFor(const float normal[3], float tangent[3])
{
	float axis[3];
	if (FloatAbs(normal[2]) < 0.9) axis[2] = 1.0;
	else axis[0] = 1.0;
	GetVectorCrossProduct(axis, normal, tangent);
	NormalizeVector(tangent, tangent);
}

void WritePlanarUV(File f, const float point[3], const float normal[3])
{
	float ax = FloatAbs(normal[0]), ay = FloatAbs(normal[1]), az = FloatAbs(normal[2]);
	if (az >= ax && az >= ay)
	{
		WriteFloat(f, point[0] / 16.0); WriteFloat(f, point[1] / 16.0);
	}
	else if (ay >= ax)
	{
		WriteFloat(f, point[0] / 16.0); WriteFloat(f, point[2] / 16.0);
	}
	else
	{
		WriteFloat(f, point[1] / 16.0); WriteFloat(f, point[2] / 16.0);
	}
}

void WriteVec(File f, const float v[3])
{
	WriteFloat(f, v[0]); WriteFloat(f, v[1]); WriteFloat(f, v[2]);
}

void WriteInt(File f, int value)
{
	WriteFileCell(f, value, 4);
}

void WriteShort(File f, int value)
{
	WriteFileCell(f, value & 0xFFFF, 2);
}

void WriteFloat(File f, float value)
{
	WriteFileCell(f, view_as<int>(value), 4);
}

void WriteZeros(File f, int bytes)
{
	for (int i = 0; i < bytes; i++)
	{
		WriteFileCell(f, 0, 1);
	}
}

void WritePaddedString(File f, const char[] str, int length)
{
	int len = strlen(str);
	if (len > length - 1)
	{
		len = length - 1;
	}
	for (int i = 0; i < len; i++)
	{
		WriteFileCell(f, str[i], 1);
	}
	WriteZeros(f, length - len);
}

void SetPushFiles()
{
	strcopy(g_sPushFiles[0], PLATFORM_MAX_PATH, "materials/supershowtriggers/trigger" ... MODEL_VERSION ... ".vmt");
	for (int i = 1; i < 4; i++)
	{
		strcopy(g_sPushFiles[i], PLATFORM_MAX_PATH, g_sModelPath);
	}
	ReplaceString(g_sPushFiles[2], PLATFORM_MAX_PATH, ".mdl", ".vvd");
	ReplaceString(g_sPushFiles[3], PLATFORM_MAX_PATH, ".mdl", ".dx90.vtx");

	g_iPushTotal = 0;
	for (int i = 0; i < 4; i++)
	{
		g_iPushSize[i] = FileSize(g_sPushFiles[i], true, "GAME");
		g_iPushTotal += g_iPushSize[i];
	}
}

int PushFileIndex(const char[] name)
{
	char path[PLATFORM_MAX_PATH];
	strcopy(path, sizeof path, name);
	ReplaceString(path, sizeof path, "\\", "/");
	for (int i = 0; i < 4; i++)
	{
		if (StrEqual(path, g_sPushFiles[i], false))
		{
			return i;
		}
	}
	return -1;
}

int ClientOfHandler(Address handler)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_iHandlerHooks[client][0] != 0 && g_MsgHandler[client] == handler)
		{
			return client;
		}
	}
	return 0;
}

void EnsureClientModel(int client)
{
	if (g_bModelBusy[client] || IsFakeClient(client))
	{
		return;
	}
	g_bModelBusy[client] = true;
	QueryClientConVar(client, "sv_allowupload", OnAllowUploadQueried);
}

public void OnAllowUploadQueried(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	if (!IsClientInGame(client))
	{
		return;
	}
	if (result == ConVarQuery_Okay && StringToInt(cvarValue) == 0)
	{
		PrintToChat(client, "%sNodraw triggers need %ssv_allowupload 1%s in your console and a reconnect.", WHITE, GOLD, WHITE);
		return;
	}

	char steamId[32];
	g_Delivered.Rewind();
	if (GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId)
		&& g_Delivered.JumpToKey(steamId) && g_Delivered.GetNum(g_sModelBase) > 0)
	{
		VerifyModel(client);
	}
	else
	{
		LogMessage("%N has no record of %s, pushing", client, g_sModelBase);
		PushModel(client);
	}
}

void VerifyModel(int client)
{
	Address netchan = SDKCall(g_hGetPlayerNetInfo, client);
	if (netchan == Address_Null)
	{
		g_bModelBusy[client] = false;
		return;
	}

	if (g_iHandlerHooks[client][0] == 0)
	{
		g_MsgHandler[client] = SDKCall(g_hGetMsgHandler, netchan);
		g_iHandlerHooks[client][0] = g_hFileReceived.HookRaw(Hook_Post, g_MsgHandler[client], OnFileReceived);
		g_iHandlerHooks[client][1] = g_hFileDenied.HookRaw(Hook_Post, g_MsgHandler[client], OnFileDenied);
	}

	g_iVerifyPending[client] = 2;
	g_iVerifyTicks[client] = 0;
	for (int i = 0; i < 2; i++)
	{
		DeleteFile(g_sPushFiles[i], true, "download");
		SDKCall(g_hRequestFile, netchan, g_sPushFiles[i]);
	}
	CreateTimer(0.1, Timer_VerifyPoll, GetClientUserId(client), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_VerifyPoll(Handle timer, int userId)
{
	int client = GetClientOfUserId(userId);
	if (client == 0 || !IsClientInGame(client) || g_iVerifyPending[client] == 0)
	{
		return Plugin_Stop;
	}

	Address netchan = SDKCall(g_hGetPlayerNetInfo, client);
	if (netchan != Address_Null && LoadFromAddress(netchan + view_as<Address>(g_iFileStreamReceive), NumberType_Int32) != 0)
	{
		g_iVerifyPending[client] = 0;
		g_bClientHasModel[client] = true;
		g_bModelBusy[client] = false;
		return Plugin_Stop;
	}

	if (++g_iVerifyTicks[client] < 100)
	{
		return Plugin_Continue;
	}
	g_iVerifyPending[client] = 0;
	LogMessage("%N did not answer the request for %s, pushing", client, g_sModelBase);
	PushModel(client);
	return Plugin_Stop;
}

public MRESReturn OnFileReceived(Address handler, DHookParam params)
{
	int client = ClientOfHandler(handler);
	if (client == 0 || g_iVerifyPending[client] == 0)
	{
		return MRES_Ignored;
	}
	char name[PLATFORM_MAX_PATH];
	params.GetString(1, name, sizeof name);
	if (PushFileIndex(name) == -1)
	{
		return MRES_Ignored;
	}

	DeleteFile(name, true, "download");
	if (--g_iVerifyPending[client] == 0)
	{
		g_bClientHasModel[client] = true;
		g_bModelBusy[client] = false;
	}
	return MRES_Ignored;
}

public MRESReturn OnFileDenied(Address handler, DHookParam params)
{
	int client = ClientOfHandler(handler);
	if (client == 0 || g_iVerifyPending[client] == 0)
	{
		return MRES_Ignored;
	}
	char name[PLATFORM_MAX_PATH];
	params.GetString(1, name, sizeof name);
	if (PushFileIndex(name) == -1)
	{
		return MRES_Ignored;
	}

	g_iVerifyPending[client] = 0;
	LogMessage("%N denied %s, pushing", client, name);
	PushModel(client);
	return MRES_Ignored;
}

void PushModel(int client)
{
	Address netchan = SDKCall(g_hGetPlayerNetInfo, client);
	if (netchan == Address_Null)
	{
		g_bModelBusy[client] = false;
		return;
	}

	bool sent = true;
	for (int i = 0; i < 4; i++)
	{
		if (!SDKCall(g_hSendFile, netchan, g_sPushFiles[i], i + 1))
		{
			LogError("SendFile of %s to %N failed", g_sPushFiles[i], client);
			sent = false;
		}
	}
	if (!sent)
	{
		return;
	}

	g_iPushNext[client] = 10;
	PrintToChat(client, "%sDownloading nodraw trigger models (%s%.1f MB%s), they show up once done.",
		WHITE, GOLD, g_iPushTotal / 1048576.0, WHITE);
	CreateTimer(1.0, Timer_CheckDelivery, GetClientUserId(client), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckDelivery(Handle timer, int userId)
{
	int client = GetClientOfUserId(userId);
	if (client == 0 || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	Address netchan = SDKCall(g_hGetPlayerNetInfo, client);
	if (netchan == Address_Null)
	{
		return Plugin_Continue;
	}

	int remaining = LoadFromAddress(netchan + view_as<Address>(g_iFileStreamCount), NumberType_Int32);
	if (remaining > 0)
	{
		int current = 4 - remaining;
		int done = 0;
		for (int i = 0; i < current; i++)
		{
			done += g_iPushSize[i];
		}
		int received, total;
		if (current >= 0 && SDKCall(g_hGetStreamProgress, netchan, 0, received, total))
		{
			done += received < g_iPushSize[current] ? received : g_iPushSize[current];
		}
		int percent = done * 100 / g_iPushTotal;
		if (percent >= g_iPushNext[client] && percent < 100)
		{
			PrintToChat(client, "%sNodraw trigger models: %s%d%%", WHITE, GOLD, percent);
			while (g_iPushNext[client] <= percent)
			{
				g_iPushNext[client] += 10;
			}
		}
		return Plugin_Continue;
	}

	g_bClientHasModel[client] = true;
	g_bModelBusy[client] = false;
	PrintToChat(client, "%sNodraw trigger models: %sdone", WHITE, GREEN);

	char steamId[32];
	if (GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId))
	{
		g_Delivered.Rewind();
		g_Delivered.JumpToKey(steamId, true);
		g_Delivered.SetNum(g_sModelBase, 1);
		g_Delivered.Rewind();
		g_Delivered.ExportToFile(g_sDeliveredPath);
	}
	return Plugin_Stop;
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("Selection database unavailable: %s", error);
		return;
	}
	g_DB = db;
	g_DB.Query(OnQueryDone, "CREATE TABLE IF NOT EXISTS st_selections ("
		... "steamid VARCHAR(32) NOT NULL, map VARCHAR(128) NOT NULL, name VARCHAR(64) NOT NULL, "
		... "hammerids TEXT NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY (steamid, map))");
}

public void OnQueryDone(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		LogError("Selection query failed: %s", error);
	}
}

void SaveSelection(int client)
{
	char steamId[32];
	if (g_DB == null || !GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId))
	{
		return;
	}

	int count = g_SelectedTriggers[client].Length;
	char[] ids = new char[count * 12 + 1];
	ids[0] = '\0';
	for (int i = 0; i < count; i++)
	{
		int entity = g_SelectedTriggers[client].Get(i);
		if (IsValidEntity(entity))
		{
			Format(ids, count * 12 + 1, "%s%s%d", ids, ids[0] ? "," : "", GetEntProp(entity, Prop_Data, "m_iHammerID"));
		}
	}

	char name[MAX_NAME_LENGTH], map[PLATFORM_MAX_PATH];
	GetClientName(client, name, sizeof name);
	GetCurrentMap(map, sizeof map);
	int length = strlen(ids) + 512;
	char[] query = new char[length];
	g_DB.Format(query, length, "REPLACE INTO st_selections (steamid, map, name, hammerids, updated) VALUES ('%s', '%s', '%s', '%s', %d)",
		steamId, map, name, ids, GetTime());
	g_DB.Query(OnQueryDone, query);
}

void DeleteSelection(int client)
{
	char steamId[32], map[PLATFORM_MAX_PATH], query[256];
	if (g_DB == null || !GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId))
	{
		return;
	}
	GetCurrentMap(map, sizeof map);
	g_DB.Format(query, sizeof query, "DELETE FROM st_selections WHERE steamid = '%s' AND map = '%s'", steamId, map);
	g_DB.Query(OnQueryDone, query);
}

void LoadSelection(int client, const char[] ownerId, bool announce)
{
	char steamId[32], map[PLATFORM_MAX_PATH], query[256];
	if (g_DB == null)
	{
		return;
	}
	if (ownerId[0])
	{
		strcopy(steamId, sizeof steamId, ownerId);
	}
	else if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId))
	{
		return;
	}
	GetCurrentMap(map, sizeof map);
	g_DB.Format(query, sizeof query, "SELECT name, hammerids FROM st_selections WHERE steamid = '%s' AND map = '%s'", steamId, map);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(client));
	pack.WriteCell(ownerId[0] != '\0');
	pack.WriteCell(announce);
	g_DB.Query(OnSelectionLoaded, query, pack);
}

public void OnSelectionLoaded(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	bool copied = pack.ReadCell();
	bool announce = pack.ReadCell();
	delete pack;

	if (results == null)
	{
		LogError("Selection query failed: %s", error);
		return;
	}
	if (client == 0 || !IsClientInGame(client))
	{
		return;
	}
	if (!results.FetchRow())
	{
		if (announce)
		{
			PrintToChat(client, "%sNo saved selection for this map. Confirm a selection to save it.", WHITE);
		}
		return;
	}

	char name[MAX_NAME_LENGTH], ids[4096];
	results.FetchString(0, name, sizeof name);
	results.FetchString(1, ids, sizeof ids);
	ApplySelection(client, ids, copied ? name : "");
}

int ResolveHammerIds(const char[] ids, ArrayList entities)
{
	int count = 0, entity, start = 0;
	char id[16];
	while (start != -1)
	{
		int next = SplitString(ids[start], ",", id, sizeof id);
		if (next == -1)
		{
			strcopy(id, sizeof id, ids[start]);
			start = -1;
		}
		else
		{
			start += next;
		}
		if (id[0] && g_TriggerByHammerId.GetValue(id, entity) && IsValidEntity(entity))
		{
			if (entities != null)
			{
				entities.Push(entity);
			}
			count++;
		}
	}
	return count;
}

void ApplySelection(int client, const char[] ids, const char[] owner)
{
	g_SelectedTriggers[client].Clear();
	int count = ResolveHammerIds(ids, g_SelectedTriggers[client]);
	if (count == 0)
	{
		PrintToChat(client, "%sThat selection has no triggers on this map.", WHITE);
		return;
	}

	g_bUseSelectionMode[client] = true;
	g_bSelectMode[client] = false;
	for (int i = 0; i < MAX_TYPES; i++)
	{
		g_bTypeEnabled[client][i] = true;
	}
	CheckBrushes(ShouldRender());

	if (owner[0])
	{
		PrintToChat(client, "%sCopied %s%s%s's selection: %s%d%s triggers. Use %s!confirm%s to keep it as yours.",
			WHITE, GOLD, owner, WHITE, GOLD, count, WHITE, GREEN, WHITE);
	}
	else
	{
		PrintToChat(client, "%sLoaded your saved selection: %s%d%s triggers.", WHITE, GOLD, count, WHITE);
	}
}

public int menuHandler_Profile(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof info);
			if (StrEqual(info, "custom"))
			{
				LoadSelection(param1, "", true);
				menu.DisplayAt(param1, menu.Selection, MENU_TIME_FOREVER);
			}
			else
			{
				ShowProfileList(param1);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				g_SelectionMenu.Display(param1, MENU_TIME_FOREVER);
			}
		}
	}
	return 0;
}

void ShowProfileList(int client)
{
	char steamId[32], map[PLATFORM_MAX_PATH], query[256];
	if (g_DB == null || !GetClientAuthId(client, AuthId_Steam2, steamId, sizeof steamId))
	{
		return;
	}
	GetCurrentMap(map, sizeof map);
	g_DB.Format(query, sizeof query, "SELECT steamid, name, hammerids FROM st_selections WHERE map = '%s' AND steamid <> '%s' ORDER BY updated DESC",
		map, steamId);
	g_DB.Query(OnProfileListLoaded, query, GetClientUserId(client));
}

public void OnProfileListLoaded(Database db, DBResultSet results, const char[] error, any userId)
{
	int client = GetClientOfUserId(userId);
	if (results == null)
	{
		LogError("Selection query failed: %s", error);
		return;
	}
	if (client == 0 || !IsClientInGame(client))
	{
		return;
	}

	Menu menu = new Menu(menuHandler_ProfileList);
	menu.SetTitle("Copy from player");
	menu.ExitBackButton = true;

	char steamId[32], name[MAX_NAME_LENGTH], ids[4096], text[MAX_NAME_LENGTH + 16];
	while (results.FetchRow())
	{
		results.FetchString(0, steamId, sizeof steamId);
		results.FetchString(1, name, sizeof name);
		results.FetchString(2, ids, sizeof ids);
		int count = ResolveHammerIds(ids, null);
		if (count > 0)
		{
			Format(text, sizeof text, "%s (%d)", name, count);
			menu.AddItem(steamId, text);
		}
	}

	if (menu.ItemCount == 0)
	{
		delete menu;
		PrintToChat(client, "%sNobody has saved a selection on this map yet.", WHITE);
		g_ProfileMenu.Display(client, MENU_TIME_FOREVER);
		return;
	}
	menu.Display(client, MENU_TIME_FOREVER);
}

public int menuHandler_ProfileList(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char steamId[32];
			menu.GetItem(param2, steamId, sizeof steamId);
			LoadSelection(param1, steamId, true);
			g_ProfileMenu.Display(param1, MENU_TIME_FOREVER);
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				g_ProfileMenu.Display(param1, MENU_TIME_FOREVER);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}
