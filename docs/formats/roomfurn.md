# Hotel room furniture (default table, room grid, placement)

Tool: `tools/roomfurn.py` (`dump`, `verify`). Editor: furniture items of locations 8, 29, 17, 15, 18, 20.

The beds, couches, fridges, showers, toilets and sinks of the 6 hotel rooms are **not in the layout files**. They
come from a table in arm9, copied into the game state at new game, and spawned by code on every room entry.

## 1. Flow — CONFIRMED (code + emulator)

| Step | Function | What |
|---|---|---|
| New game | Game_InitNewGame → Room_InitDefaultFurniture 0x02073d48 | copies the 6 default entries of each room slot from **0x0211FA70** into `[G]+0x41F8 + 0x58*slot`, count = 6 |
| Room entry | Map_EnterLocation → Map_SpawnRoomFurniture 0x02087df4 | slot = Room_SlotFromLocation(loc); loads the room grid (Room_GridEntryFromSlot); for each entry: Actor_InitProp(prop) + Room_PlacePropOnGrid |
| Prop state change | Prop_ToggleStateAndSaveRoomEntry 0x02011cdc | prop id ±1 (state pairs), written back into the room entry |

`G = [0x0213E434]`. Room slots (table 0x0211F9D4, u32[6]): 0 DeluxeRoom (8), 1 SmHotelRoom (29), 2 ManagerSuite (17),
3 JungleRoom (15), 4 ModernRoom (18), 5 Penthouse (20). Any other location → −1, nothing spawned.

Room list in the game state, 0x58 bytes per slot: `{u8 prop, u8 x, u8 z, u8 rot}[14]`, `u32[7]` (all 1 after a new game,
role unknown), `u32 count`. Spawned actors are stored at `[G]+0x44DC + 4*i`, current slot at `[G]+0x44D8`.
**Assumed**: this area is part of the save (it must persist, the player buys / moves furniture). Not checked.

Default table 0x0211FA70: 6 slots × 6 entries × 4 bytes. Every room has the same 6 props: FridgeBasic 86, CheapBed 114,
CouchBasic 133, ShowerBasic 185, Toilet 209, SinkBasic 233. Editing it changes **new games only**.

## 2. Room grid file — CONFIRMED (code + all 6 files)

rom.bin entry from u16 table 0x02127754 (2494, 7565, 5007, 4370, 5297, 6333), stored raw.

| Offset | Type | Field |
|---|---|---|
| 0x00 | u32 | cells_size = width × depth rounded up to 4 |
| 0x04 | fx32 | origin x |
| 0x08 | fx32 | origin z |
| 0x0C | u16 | width (cells along x) |
| 0x0E | u16 | depth (cells along z) |
| 0x10 | u16 ×2 | ? (close to width×4, depth×4, not exact) |
| 0x14 | u8 | n_heights |
| 0x15 | u8 | n_walls |
| 0x16 | u16 | ? |
| 0x18 | u32 | 0 |
| 0x1C | fx32[n_heights] | floor heights |
| … | u8[depth][width] + pad | cell → height index (0xFF = no floor) |
| … | {s32 pos fx32, u8 orient 0..3, u8 height index, u8 ?, u8 ?}[n_walls] | wall slots |
| … | u8[depth][width] + pad to 4 | second layer, unknown (mostly 0xFF) |

Cell size 2.0 (0x2000). `verify` checks the sizes, the height indexes and the wall records of the 6 files: all OK.

## 3. Placement (Room_PlacePropOnGrid 0x020c1eb4) — CONFIRMED (36/36 default items match RAM within 0.001)

Inputs:
- the entry (prop, x, z, rot) and the grid;
- the prop's model box: BMD0 model info +0x2C box_x, +0x30 box_z, +0x38 scale, with `bx = |box_x|·scale` and
  `bz = |box_z|·scale`;
- its placement object (actor+0x130): +0x30 wall flag, +0x3C off_x, +0x40 off_z (§4).

**Floor prop** (flag 0):
```
if rot odd: swap (bx, bz) and swap (off_x, off_z)
if rot >= 2: off_x = max(0, -off_x); off_z = max(0, -off_z)
X = origin_x + (x + 1)·2 + bx + off_x
Z = origin_z + (z + 1)·2 + bz + off_z
Y = heights[cell[z][x]]          angle = rot · π/2   (actor +0x88, fx32 radians)
```
**Wall prop** (flag 1): x = wall slot, z = cell along the wall, rot is ignored.
```
(pos, orient, h) = wall[x]; a = orient · π/2; along = (z + 1)·2 + bx
orient even: X = origin_x + along, Z = pos       orient odd: X = pos, Z = origin_z + along
X -= 0.5·sin a; Z -= 0.5·cos a; Y = heights[h]; angle = a
```

## 4. Placement object of every prop — CONFIRMED (code + 72 placements in the emulator)

`tools/roomfurn.py placement(prop)` → (wall, off_x, off_z), `is_furniture(prop)`.

**Which props are furniture.** Prop_CreatePlacementObject 0x02011e04 is a jump table (0x02011e2c, 331 cases → 94
handlers). Each handler allocates an object and calls a class ctor. 22 ctors (object size 0x5C, or 0x64 for the bed class
0x0208e584) call Furn_InitPlacementBase 0x0208bb98(this, actor, a, **wall flag**): those are the furniture classes,
**182 props**:
- floor: 6–8, 36, 57–61, 64–67, 70, 92–93, 95–100, 102–159, 164–184;
- wall: 9–11, 62–63, 68–69, 83–91, 94, 101, 160, 162–163, 185–244.

The flag is a constant in each ctor, with two exceptions. Furn_CtorWallFlagArg 0x02091098 takes it from the case (wall for
94, 101, 160, 162, 163). Furn_CtorTrashWallFromProp9 0x02099ce4 sets wall = prop ≥ 9 (props 6–11). The other prop ids
get no object or a non-furniture one (doors, effects…). Room_PlacePropOnGrid would read its +0x30 / +0x3C as garbage, so
the editor refuses those ids.

**Offsets** (Furn_InitPlacementBase, fx32 arithmetic, `fx(a, s) = (a·s + 0x800) >> 12`):
```
s = box_pos_scale (model +0x38); box_x +0x2C, box_z +0x30, box_w +0x32, box_d +0x36 (fx16)
(ax, az) = x, z of the first node of class 2 in the prop's node file (0 if none)
ix = fx(box_w, s) − fx(|box_x|, s) + ax        off_x = max(0, −ix)
iz = fx(box_d, s) − fx(|box_z|, s) + az        off_z = max(0, −iz)
```
That is, the footprint is pushed out until the class-2 node lies inside it. This is probably the spot where the Sim
stands to use the object (assumed meaning). The wall branch of the placement does not use the offsets.

**Node file.** Prop table 0x0211CD2C: `{u32 anim_list, u16 BMD0, u16 n_anims}`. The anim list holds n_anims entries
`{u16 id (309 = no animation), u16 animation entry (0xFFFF = none), u16 node file}`. Actor_InitProp uses the node file of
entry 0. The nodes are parsed by Node_LoadFile 0x02044690 → Node_ReadRecord 0x01ffafdc (ITCM) → Node_ReadFrames 0x02044a8c,
and read back with Node_GetFrame(…, 0).

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | ? (0x1E, 0x18 or 0x08) |
| 1 | u8 | n_frames |
| 2 | u16 | n_nodes |
| 4 | per node | u16 kind, u16 id, then n_frames frames |

Every frame starts with fx32 x, y, z. What follows depends on the kind:

| Kind | Frame size | Rest of the frame | class at |
|---|---|---|---|
| 0 | 28 | fx32, u16 ?, u16 class, u32, u32 | +18 |
| 3 | 32 | 2 fx32, u16, u16 class, u32, u32 | +22 |
| 4 | 48 | 6 fx32, u16, u16 class, u32, u32 | +38 |
| 5 | 36 | 3 fx32, u16, u16 class, u32, u32 | +26 |

The runtime objects are 0x24 bytes (0x30 for kind 4), with the class at +0x11. All 108 node files referenced by prop anim
lists parse to their exact size. Only the meaning of byte 0 is unknown.

**Checked**:
- From the code alone, the formula gives back the 6 offsets measured earlier (fridge 0, bed 9650, couch 8368, shower
  14638, toilet 8464, sink 8879).
- Emulator, 2026-10-07: I patched the arm9 default table in RAM (each warp re-copies it into the game state), warped into
  each of the 6 rooms and read actor +0x78…+0x88 for 36 more props. The set covers floor props in all 4 rotations, wall
  props on several walls, the 4 node kinds, multi-frame node files and props with several anim entries. All 36 match within
  0.001 (tests/test_roomfurn.py).

## 5. Open points
- fields 0x10, 0x16 and the second cell layer of the grid file; bytes 6–7 of a wall slot; byte 0 of a node file;
- the 7 u32 per room in the game state.
