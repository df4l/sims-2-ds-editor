# Identified functions (Ghidra)

Program: `arm9.bin` (decompressed), base 0x02000000. Overlays: slot at 0x02149B40 (not imported yet).
Blocks added: `ITCM` 0x01FF8000 (0x6460, from arm9+0x139220), `DTCM` 0x027E0000 (0x20E0, from arm9+0x13F680), autoload.

| Address | Name | Role | Status |
|---|---|---|---|
| 0x0204460c | FS_OpenRomBin | FS init + open "rom.bin" into the global FSFile at 0x027E007C | confirmed |
| 0x0204439c | Arc_GetEntrySize | size of entry idx (offsets[idx+1]-offsets[idx]) | confirmed |
| 0x02043d38 | Arc_ReadEntryRaw | reads entry idx without decompression | confirmed |
| 0x02043ea0 | Arc_LoadEntry | (idx, ?, compressed, &out): cache, read, optional decompression | confirmed (param 2 unknown) |
| 0x02042adc | Cmp_Decompress | dispatch on type byte (raw/LZ77/Huff/RLE/EA6, delta 0x80) | confirmed |
| 0x01FF8000 | Cmp_DecompressType6 | EA custom LZ codec (ITCM, ASM) | confirmed, reimplemented in tools/s2cmp.py |
| 0x020ff8fc | FS_OpenFile | NitroSDK | inferred from usage |
| 0x020ff758 | FS_SeekFile | NitroSDK (file, off, whence) | inferred from usage |
| 0x020ff7c4 | FS_ReadFile | NitroSDK (file, buf, len) | inferred from usage |
| 0x020465f8 | Unk_020465f8_Alloc | allocation (size, ?, align) | assumed |
| 0x0204649c | Unk_0204649c_Free | free | assumed |

## Phase 2 renames (applied 2026-10-05, with plate comments)

| Address | Name | Role | Status |
|---|---|---|---|
| 0x0204456c | Arc_LoadRaw | Arc_LoadEntry(idx, 0, 0) -> ptr (0 on failure) | confirmed |
| 0x02044538 | Arc_LoadDecompressed | Arc_LoadEntry(idx, 0, 1) -> ptr | confirmed |
| 0x020445a0 | Arc_LoadDecompressedArea1 | Arc_LoadEntry(idx, 1, 1) -> ptr | confirmed |
| 0x020445d8 | Arc_LoadRawArea1 | Arc_LoadEntry(idx, 1, 0) -> ptr | confirmed |
| 0x020bc4b8 | Unk_020bc4b8_ResRefLoad | {ptr, u16 size (4-aligned), u16 idx, u8 loaded} via Arc_LoadRaw | assumed |
| 0x020bc528 | Unk_020bc528_ResRefInit | same, initialises the ref first, skips the "none" index | assumed |
| 0x02050014 | Gfx_LoadSpriteToObj | {u16 tiles_idx, u16 def_idx} -> OBJ VRAM 0x06400000, per frame w*h/2 bytes | confirmed |
| 0x0200f1cc | Unk_0200f1cc_LoadBgSet | 4 u16 indices (+0/+4 decompressed, +2/+6 raw) -> FUN_020bbcf0 / FUN_020bbde8 | assumed |
| 0x0206719c | Unk_0206719c_StreamEntry | Arc_ReadEntryRaw of a computed index into VRAM | assumed |

## Phase 3 renames (applied 2026-10-05)

| Address | Name | Role | Status |
|---|---|---|---|
| 0x02084894 | Map_LoadLocation | loads a location (obj+4 = id 0..32): BSP, scene models + anims, nav, music | confirmed |
| 0x020852f8 | Map_FreeLocation | location object destructor | confirmed |
| 0x02084cf8 | Map_PlayLocationMusic | music from rec+6+2k | assumed (sound) |
| 0x020844c4 | Unk_020844c4_LocField12 | uses rec+0x12 | partial |
| 0x02088200 | Map_GetLocModelRec | &rec+0x14+8k | confirmed |
| 0x02088218 | Map_GetLocField12 | rec+0x12 | confirmed |
| 0x0208822c | Map_GetLocSpecialModel | rec+0x10 | confirmed |
| 0x02088240 | Map_GetLocModelCount | rec+0xE | confirmed |
| 0x02088254 | Map_GetLocMusic | rec+6+2k | confirmed |
| 0x0208826c | Map_GetLocNavEntry | rec+4 | confirmed |
| 0x02088280 | Map_GetLocBspEntry | rec+0 | confirmed |
| 0x020d9bb4 | Map_LoadBsp | Arc_LoadDecompressedArea1(idx) | confirmed |
| 0x02053128 | Map_LoadNav | parses the rec+4 file (name = placeholder) | confirmed (layout) |
| 0x020528c0 | Map_ParseNavBlock | one variant block of the nav file | confirmed (layout) |
| 0x0201180c | Unk_0201180c_InitLocModel | model object from {anim list, BMD0, count} | partial |

Data: location record pointer table at 0x021332E0 (33 x u32), records 0x02122328..0x021227A0.

## Phase 3 renames, part 2 (2026-10-05, emulator session)

| Address | Name | Role | Status |
|---|---|---|---|
| 0x02088048 | Map_EnterLocation | (world, id): world+0xF4 = id, world+0xFC = new location object, spawns player | confirmed |
| 0x02085548 | Map_CreateLocationObject | ctor: obj+4 = id, clears model slots, calls Map_LoadLocation | confirmed |
| 0x02076f00 | State2_LocationEnter | enter() of game state 2 (args: mode, location id, entry point) | confirmed |
| 0x02046c24 | Game_CreateState | factory: state id 0..0x31 -> state object {vtable, id, arg0..2} | confirmed |
| 0x02047bf0 | Game_UpdateStateMachine | per frame: runs pending requests G+0xDF0+0x20*slot (0x32 = none) | confirmed |
| 0x02048108 | Game_RequestState | (G, state, slot, a0, a1, a2) -> G+0xDF0+0x20*slot | confirmed |
| 0x02048128 | Game_RequestStateOtherSlot | same, on the other slot | confirmed |
| 0x0204ed28 | Unk_0204ed28_IsSlotFading | word at 0x0213D920+0x20*slot != 0 | assumed |

Data: 0x0213E580 -> world struct; 0x02139FA4 -> game object G; vtable of state 2 at 0x02132850.

## Phase 3 renames, part 3 (2026-10-05, layout file)

| Address | Name | Role | Status |
|---|---|---|---|
| 0x020525f0 | Nav_SpawnGroup | spawns group k-1 of a layout block via ctor table 0x0211E7E0[type] | confirmed |
| 0x020525a4 | Nav_DespawnGroupItem | flags the actor of a group item for deletion | confirmed |
| 0x02052800 | Nav_RunScript | runs a layout script (renamed again in part 4) | confirmed |
| 0x02052cd0 | Nav_FindEntryPoint | entry point record by id (byte +0xC) | confirmed |
| 0x020845bc | Map_PlaceAtEntryPoint | actor pos/rot from an entry point | confirmed |
| 0x02053e38 | Nav_AddWaypoint | item type 9 -> world+0x6C list | confirmed |
| 0x0203a700 | Nav_SpawnEntity | item constructor, switch on type (function created here) | confirmed |
| 0x0200b448 | Actor_InitNpc | NPC ctor, model table 0x02118310 | confirmed |
| 0x02014c30 | Actor_InitProp | prop ctor, model table 0x0211CD2C | confirmed |
| 0x02010cb4 | Actor_InitObject | interactive object ctor, model table 0x0211CC3C | confirmed |
| 0x020523fc | Nav_ParseGroup | parses one group of a block | confirmed |
| 0x02052720 | Nav_ParseScripts | parses the script table of a block | confirmed |

Map_LoadNav (0x02053128) keeps its name; the file it parses is now called "layout" in the docs.

## Phase 3 renames, part 4 (2026-10-05, layout scripts / doors / triggers)

| Address | Name | Role | Status |
|---|---|---|---|
| 0x0204299c | Nav_DispatchScriptOp | script VM dispatch, handler table 0x0211E4F0 (ops 0..0x51) | confirmed |
| 0x02052800 | Nav_RunScript | (was Unk_02052800_RunLayoutScript) runs script k-1 of a block | confirmed |
| 0x020420a4 | NavOp16_SpawnGroupRunScript | op 0x16 (group, script) | confirmed |
| 0x020420e0 | NavOp15_SpawnGroupIfFlag | op 0x15 (flag, group, script, else group, else script) | confirmed |
| 0x02042890 | NavOp01_ActorCommand | op 1 (group, item/0xFF player, action, value) | confirmed |
| 0x02042794 | NavOp02_GroupCommand | op 2 (group, action, value) | confirmed |
| 0x0209b74c | Nav_FireTriggerBox | trigger box entered -> spawn group + run script | confirmed |
| 0x0209b7bc | Nav_SetTriggerBoxEvent | box+0x1C/1D/1E from item type 3 | confirmed |
| 0x0209b9d8 | Nav_SetDoorBoxTarget | box+0x19 = dest location, +0x1A = entry point (item type 4) | confirmed |
| 0x02015770 | Unk_02015770_EventWatcherUpdate | item type 8 update (story flag / countdown) | partial |
| 0x02064644 | Game_TestStoryFlag | bit test, bitset at +0x4814 | confirmed |
| 0x0208485c | Map_SpawnLayoutGroup | location obj -> Nav_SpawnGroup (selected block) | confirmed |
| 0x02084874 | Map_RunLayoutScript | location obj -> Nav_RunScript (selected block) | confirmed |

## Phase 3 renames, part 5 (2026-10-05, script opcodes, text, conversations)

Overlays are now imported as overlay blocks `ov00`..`ov18` (all at 0x02149B40, BLZ-decompressed copies in
build/overlays/). State → overlay table: u32 at 0x0211E64C (state 0xE → ov15, 0x21 → ov11, -1 = none).
All 82 script handlers (table 0x0211E4F0) exist as functions; the ones below are renamed `NavOpXX_*`
(the others keep FUN_ names, their meaning is in tools/layscript.py OPS).

| Address | Name | Role | Status |
|---|---|---|---|
| 0x02045194 | Txt_SetBank | bank pointers: data, tree (+4), offset table (+u32[0]) | confirmed |
| 0x0204505c | Txt_DecodeString | Huffman decoder (root 0x100, LSB-first) | confirmed |
| 0x02052258 | Txt_GetString | text id -> buffer 0x0213DFC8 | confirmed |
| 0x02052298 | Txt_LoadLanguage | firmware language -> bank entry (table 0x0211E7D4) | confirmed |
| 0x0206466c | Game_SetStoryFlag | bitset +0x4814 | confirmed |
| 0x02052c08 | Nav_DirToAngle | dir 0..4 -> angle | confirmed |
| 0x0205251c | Nav_DeleteSpawnedGroup | op 0x0A | confirmed |
| 0x02082cf0 | Npc_SetTalkConversation | 30-slot NPC -> conversation table | confirmed |
| 0x02083dc8 / 0x02083d1c / 0x02083d60 | Inv_AddItem / Inv_FindItem / Inv_RemoveSlot | 6-slot inventory | confirmed |
| 0x02077824 / 0x02077678 | Goal_Start / Goal_Complete | goal record [G]+0x2F78 | partial |
| 0x02077a48 / 0x02077a2c | Goal_IsStarted / Goal_IsDone | bits 1 / 2 | confirmed |
| 0x020733f0 / 0x020734a0 / 0x02073580 / 0x02073444 | Coll_GetScore / Coll_SetOwned / Coll_SetSeen / Coll_LinkStoryFlag | **location** state [G]+0x41F8 (not a collection: see part 6) | confirmed |
| 0x0205871c | Ui_ShowMessageBox | popup with 2 text ids | confirmed |
| 0x020d544c / 0x020d5368 / 0x020d59bc | Snd_PlayMusic / Snd_PlayMusic2 / Snd_PlaySfx | channel 0 / channel 1 music (track 0..0x29), sound effect | confirmed (code) |
| 0x020ba100 / 0x020b9e8c / 0x020b9c24 / 0x02076b60 | Cam_LookAtActor / Cam_Shake / Cam_FromLayoutPoint / Cam_CloseUpActor | camera object 0x02139FB4 | confirmed |
| 0x020778ac | Goal_IsNextGoalReady | op 0x42: next goal of the mission may start (delay table 0x0211FB68) | confirmed |
| 0x020523dc | Nav_GetGroupActor | (group slot g, item i 1-based) -> actor (ops with g, i) | confirmed |
| 0x02015770 | Nav_EventWatcherUpdate | type-8 watcher: 1 flag, 2 countdown (op 0x09, ticks), 3 ? | confirmed |
| ov15::0214a694 | State0E_Conversation_ctor | conversation state | confirmed |
| ov15::02149cd0 | State0E_ShowNextLine | one line per call, end -> group/script/flag | confirmed |
| ov11::02149f94 | State21_ctor | special conversations 3, 0x23, 0xA6 | partial |
| 0x0204297c … 0x0203fdec | NavOp00_DespawnItem … NavOp4E_ActorHoldProp | 40 script handlers | see layscript.OPS |

Data: 0x0211F16C conversations (216 × 8), 0x0211E8C0 messages, 0x021229AC opcode arg sizes, text NPC names
at 0x143 + id, camera object at 0x02139FB4.

## Part 4 — Collision (BSP), 2026-10-06

Prefix `Clsn_` (collision) — `Coll_` is already taken by the location-state functions (first named "collection").

| Address | Name | Role | Status |
|---|---|---|---|
| 0x01ffc558 (ITCM) | Clsn_TraceBoxBsp | swept AABB trace through the location BSP: (holder, box[6], motion[3], out{hit node, ?, frac}) | confirmed (code + emulator) |
| 0x01ffc54c (ITCM) | Clsn_TraceBoxBsp_veneer | ldr/bx veneer (was not a function) | confirmed |
| 0x01ffc4fc (ITCM) | Math_DotFx32 | fx32 dot product | confirmed |
| 0x020877e4 | Actor_MoveWithCollision | gravity (vy −0x300, −0x800 in loc 19) + Clsn_MoveBox against world+0xFC→+0x38 | confirmed (drop test) |
| 0x020dad50 | Clsn_MoveBox | grounded flag (+0x14 of the mover) → Grounded / Air | confirmed |
| 0x020d9d04 | Clsn_MoveBoxGrounded | slide + step-up (arg 9 = step height) + ground snap | assumed |
| 0x020dac20 | Clsn_MoveBoxAir | slide, keeps the highest contact as ground | assumed |
| 0x020da1a4 | Clsn_SlideBox | up to 3 traces, clips motion against 1–2 planes | assumed |
| 0x020daa24 | Clsn_TraceWorld | min(Clsn_TraceActors, Clsn_TraceBoxBsp); copies the hit node normal + d as is (no side flip) | confirmed |
| 0x020da808 | Clsn_TraceActors | trace against other actors' boxes | assumed |
| 0x020da758 | Clsn_ClipMotion | p − n·dot(p, n) | assumed |
| 0x020d9a4c / 0x020d9b00 | Box_Translate / Box_FromCentreHalf | box[6] = {xmin,xmax,ymin,ymax,zmin,zmax} helpers | confirmed |

BSP holder (location obj+0x38, built by Map_LoadBsp): `{u16 entry, pad, bsp*, s32 offset[3] (0)}`.

## Part 5 — Actor tasks, NPC moods (2026-10-06)

Actors run a tree of **tasks** at actor+0xE0 (nodes of 0x14 bytes {task, next, prev, child, parent}); a task has
its id at +0x10 (u16) and an "active" byte at +0x15. NPCs get task 5 at spawn (FUN_0200ad3c).

| Address | Name | Role | Status |
|---|---|---|---|
| 0x01ff9ad0 (ITCM) | Task_Create | task factory, switch on id 1..0x4B (size + ctor per id) | confirmed |
| 0x01ffaf28 (ITCM) | Task_Find | (task tree, id, owner) -> task or 0 | confirmed (emulator) |
| 0x02018804 | Task_Add | add a task next to the running ones (FUN_020117d8 = actor wrapper) | confirmed |
| 0x02018888 | Task_AddExclusive | clears the active byte of the other tasks, then adds (FUN_020117e8 = actor wrapper) | confirmed (emulator: task 10 inactive under 0x18) |
| 0x0201e358 | Task05_NpcDefaultCtor | NPC default task: per NPC id a sub-task, most NPCs task 0xC -> task 10 (roaming) | confirmed |
| 0x0201a5b4 | Task0A_RoamUpdate | roaming: idle rand(100)+15 frames, new point, 1/200 NPC-NPC social | confirmed (emulator) |
| 0x02027e50 / 0x02028050 | Task18_Start / Task18_Update | script-driven NPC task: mode 1 walk to point then run script, 2 task 0x30, 3 loop mood idle | confirmed (mode 1/3) |
| 0x0200aac4 | Npc_GetMoodAnim | (actor, k) -> anim id: mood m != 0 -> 0xDD + 4m + k (k 0 walk, 1-3 idles); else 3 / 0 | confirmed (emulator) |
| 0x020828ac | Npc_SetMood | NPC record +0x1A = mood, restarts the behaviour | confirmed |
| 0x0204198c | NavOp1C_SetNpcMood | (was NavOp1C_NpcState) | confirmed |
| 0x020418b4 | NavOp1D_ActorResumeAi | (was NavOp1D_ActorStop) removes task 0x18, re-adds task 5 if missing | confirmed |
| 0x02041808 | NavOp1E_ActorHoldIdle | (was NavOp1E_ActorWander) Task_AddExclusive(0x18, mode 3) | confirmed |
| 0x02040d0c | NavOp36_SetNpcStatus | NPC record +0x10 = value (values: part 6) | confirmed |

NPC record = [0x0213E434] + 0x21DC + 0x2C * id: +0x10 status (op 0x36), +0x14 bit 0 met, +0x18 u16 id,
+0x1A mood, +0x24 actor.

## Part 6 — Remaining script opcodes: locations, doors, phone, hotel (2026-10-06)

The "collection" functions work on the **33 locations**: table 0x0211F9EC = {u16 price, u8 hotel score, u8 parent
location (33 = none)}, bitsets [G]+0x41F8+0x218 = location open (doors check it), +0x210 = offered for construction
(assumed). Text name of location n = 0x43 + n.

| Address | Name | Role | Status |
|---|---|---|---|
| 0x0207355c | Coll_IsOwned | (state, location) -> open bit (+0x218) | confirmed |
| 0x02064f18 | Game_InitNewGame | new game: money 2000, opens 14 locations, offers 15 rooms, ... | confirmed (RAM matches) |
| 0x020643fc | Door_TryEnter | door +0x19 = destination; closed location -> sound 0xCC, no warp | confirmed (emulator) |
| 0x02041080 | NavOp2D_IfLocationOpen | op 0x2D | confirmed (emulator) |
| 0x020405d8 / 0x020405a8 / 0x02040554 | NavOp47_LocationOffer / NavOp48_LocationLinkFlag / NavOp4A_LocationOpen | ops 0x47 / 0x48 / 0x4A | 0x47 role assumed |
| 0x0204114c | NavOp2B_IfHotelScore | (was NavOp2B_IfCollectionScore) | confirmed |
| 0x0203fef8 / 0x02010c28 | NavOp4D_DoorOpen / Actor_DoorOpen | door actor state +0x211, animation 135 | confirmed (code + data) |
| 0x020413b0 | NavOp25_NpcAskMoney | "Pay ($n)" menu entry 7 + script when paid (FUN_02082a94, 3 slots) | confirmed (code + texts) |
| 0x020407e0 | NavOp41_NpcWantItem | item wanted by an NPC + script (FUN_0208297c, 2 slots) | confirmed (code + texts) |
| 0x02040820 | NavOp40_ShopUnlockItem | item id -> 2-slot list [G]+0x47A0 | assumed |
| 0x020414d4 / 0x0205f2d0 | NavOp24_HotelDustAdd / Hotel_AddDust | dust level per location (max 9), hotel rooms only (table 0x02131F34) | confirmed (code + data) |
| 0x02040b4c / 0x02063c68 / 0x02063d3c | NavOp3A_StartFire / Fire_StartInLocation / Fire_IncrementSlot | 7 fire slots, spawns prop 260 `Fire` | confirmed (code + data) |
| 0x02040740 / 0x020644b8 | NavOp43_SetWeather / Weather_IsActive | [G]+0x4650 / +0x4651 override, 0 = by date | confirmed (code) |
| 0x02040580 / 0x0206422c | NavOp49_PhoneGate / Phone_CanRingNow | phone call allowed now (also used by op 0x2A) | partial |
| 0x02040a60 / 0x0205b12c | NavOp3C_NpcMet / Phone_DrawPhonebook | phonebook = hotel guests (status 5) + met NPCs (not 7/8/9) | confirmed (code + texts) |
| 0x0203f96c | NavOp4C_NpcSet1C | NPC actor brain +0x1C | assumed |
| 0x0203fa50 | NavOp51_AlfredFlySequence | Optimum Alfred propeller animations | confirmed (data) |
| 0x0203ff50 | NavOp4B_LocationSetup | (was NavOp4B_SpecialEvent) per-location setup hooks 0x11 / 0x15 / 0x1E | confirmed (code) |
| 0x02042788 / 0x0204277c | NavOp03_MusicPause / NavOp04_MusicResume | channel 0 pause / resume | confirmed (code) |
| 0x0204276c / 0x0204275c / 0x0203fc48 | NavOp05_MusicPlay / NavOp06_Sfx / NavOp50_MusicPlay2 | | confirmed (code) |
| 0x0204274c / 0x0204273c | NavOp07_SoundVolumeA / NavOp08_SoundVolumeB | sound engine bytes +0x664 / +0x665 | assumed |
| 0x02040724 | NavOp44_SetFlagBit2 | [G]+0 bit 2 | assumed |

| 0x02087df4 | Map_SpawnRoomFurniture | called by Map_EnterLocation: room slot = Room_SlotFromLocation(loc); spawns each {prop id, cell x, cell z, rot} of [G]+0x41F8+slot*0x58 (count at +0x54) via Actor_InitProp + Room_PlacePropOnGrid | confirmed (code) |
| 0x02073f8c | Room_SlotFromLocation | location id → slot 0..5 through table 0x0211F9D4 (locs 8, 29, 17, 15, 18, 20), else −1 | confirmed (code) |
| 0x02073d48 | Room_InitDefaultFurniture | called by Game_InitNewGame on [G]+0x41F8: clears 6 room slots, copies 6 default items per room from 0x0211FA70, count = 6 | confirmed (code) |
| 0x020c1eb4 | Room_PlacePropOnGrid | (actor, x, z, rot, grid): floor prop → cell (x, z), angle rot×π/2; wall prop (placement obj +0x30) → wall slot x, cell z along it, angle = slot orient; formulas in docs/formats/roomfurn.md | confirmed (code + emulator, 36/36) |
| 0x020c3fc8 | Room_GridEntryFromSlot | room slot → rom.bin entry of its grid file (u16 table 0x02127754) | confirmed (code + emulator) |
| 0x02011e04 | Prop_CreatePlacementObject | per prop id jump table (0x02011e2c, 331 cases → 94 handlers) building the placement object at actor+0x130; 22 furniture ctors → Furn_InitPlacementBase (182 props, list in docs/formats/roomfurn.md §4) | confirmed (code + emulator) |
| 0x0208bb98 | Furn_InitPlacementBase | base ctor of that object: +0x2C/+0x30 = ctor args (+0x30 wall-mounted flag), +0x34/+0x38 first class-2 node x/z, +0x3C/+0x40 X/Z offsets = max(0, −(box_w·s − \|box_x\|·s + node)), +0x44/+0x48 box extents, +0x20/+0x24 footprint (4-unit steps) | confirmed (code + emulator, 72 placements; tools/roomfurn.py placement) |
| 0x02091098 | Furn_CtorWallFlagArg | furniture class whose wall flag is passed by the jump-table case (wall for 94, 101, 160, 162, 163) | confirmed (code) |
| 0x02099ce4 | Furn_CtorTrashWallFromProp9 | furniture class of props 6–11: wall flag = prop ≥ 9 | confirmed (code + emulator: prop 9 wall) |
| 0x02044690 | Node_LoadFile | (holder, rom.bin entry): node file header u8 ?, u8 n_frames (+9), u16 n_nodes (+0xA), allocates n_nodes × 8 and reads each record | confirmed (code, 108/108 files parse) |
| 0x01ffafdc (ITCM) | Node_ReadRecord | u16 kind, u16 id, then Node_ReadFrames | confirmed (code) |
| 0x02044a8c | Node_ReadFrames | allocates n_frames runtime nodes per kind (0/3/5: 0x24 bytes, 4: 0x30; 1/2: none), reads fx32 x, y, z then the kind's virtual read (0x02044fa4 / 0x02044cec / 0x02044e1c / 0x02044d74) | confirmed (code) |
| 0x02044a1c | Node_GetFrame | (node entry, i) → frame i of a node | confirmed (code) |
| 0x02011cdc | Prop_ToggleStateAndSaveRoomEntry | toggles a prop id ±1 (state pair, e.g. on/off) and writes the new id back into the room list entry → room state persists | confirmed (code) |
Data: 0x02132900 NPC initial records (20 bytes, status at +4), 0x02131F34 dust-enabled locations (33 bytes).

Data: 0x0211FA70 default room furniture (6 rooms × 6 × {u8 prop id, u8 x, u8 z, u8 rot}); 0x02127754 room grid entries (u16[6]: 2494, 7565, 5007, 4370, 5297, 6333).
