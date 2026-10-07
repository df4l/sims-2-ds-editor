# 3D locations (maps) — phase 3

Tools: `tools/locations.py` (arm9 table → `rom_bin/locations.csv`, `--sheet` → `rom_bin/preview/locations.png`),
`tools/gmd1.py` (GMD1 parse/write/OBJ/PNG). Tests: `tests/test_catalog.py`.

A location is described by a record in arm9 and uses 4 kinds of rom.bin entries:
**BSP** (plane tree), **GMD1** (floor mesh), **layout** (placed entities, docs/formats/layout.md), and one or more
**scene BMD0** models with their BTA0 / trs_anim animations.

## 1. Location table (arm9) — CONFIRMED by code
`u32 ptr[33]` at **0x021332E0**. Loader: `Map_LoadLocation` (0x02084894), `obj+4` = location id 0..32.
Accessors `Map_GetLoc*` (0x02088200–0x02088280). Records sit at 0x02122328–0x021227A0 (variable size).

```
+0x00 u16 bsp            rom.bin entry, loaded decompressed by Map_LoadBsp (0x020d9bb4)
+0x02 u16 gmd1           rom.bin entry. No accessor in arm9 → read elsewhere (overlay?)   [use not found]
+0x04 u16 nav            rom.bin entry, loaded raw (Arc_LoadRawArea1), parsed by Map_LoadNav (0x02053128)
+0x06 u16 music[4]       Map_PlayLocationMusic: index chosen at runtime (time of day?);
                         <0x2A, ==0x2A, >0x2A → 3 different sound calls                 [meaning ASSUMED]
+0x0E u16 model_count
+0x10 u16 special_model  this model gets flag 0x10000 + a material call (0xFFFF = none)
+0x12 u16 field12        lo/hi bytes → FUN_020b8a9c (0xFFFF = none)                   [unknown]
+0x14 model[model_count], 8 bytes each:
        u32 anim_list (ptr in arm9), u16 BMD0 entry, u16 anim_count
anim_list entry (6 bytes): u16 kind (200 or 309), u16 BTA0/BCA0 entry, u16 trs_anim entry (0xFFFF = none)
```
Checked on the 33 records: every index points to an entry of the expected kind in the catalogue.
Locations 22 and 23 share BSP 6975 / GMD1 6977 / nav 6981 but use different scene models (6978 / 6979).

## 2. GMD1 — floor mesh — layout CONFIRMED by data, role ASSUMED
> Update 2026-10-05: GMD1 is **not in RAM** while its location is loaded (§6) → probably not the
> run-time collision mesh. The "walkable floor" role below is now doubtful.

```
"GMD1" 01 02 00 00 | u32 vertex_count (always a multiple of 3) | u32 1
"XFRM" s32 centre[3], s32 half_size[3] (fx32 20.12) | 16 bytes: 0,0,0,0 (?), 00 00 2c cf 00 00 2c cf
"FRAM" vertex[vertex_count] — triangle list, no index buffer
vertex (16 bytes): s16 x,y,z   normalised: world = centre + v/32767 * half_size
                   s16 nx,ny,nz face normal, fx 4.12 (|n| = 4096), identical on the 3 vertices of a triangle
                   u32 0
```
Evidence: 32/32 counts divisible by 3; every one of the 38 168 triangles has one normal shared by its 3 vertices;
the stored normal equals the geometric normal (cross product) for 95% of the non-degenerate triangles; the
extremes of the vertex coordinates are exactly ±32747 on every file. Round-trip parse → write is byte-identical
on all 32 files (`python tools/gmd1.py verify`). Rendered from the top, every mesh is a floor plan
(rooms, corridors, holes), almost all faces point up → **walkable floor / collision mesh** (ASSUMED: the
code that reads it has not been found yet; the 16-byte XFRM tail and the `1` after the count are unexplained).

## 3. BSP — collision (solid-leaf plane tree) — CONFIRMED (code + data + emulator)
Tool: `tools/bsp.py` (verify / info / point / png / walk / obj / cell / delete / move / box; `delete_cell`,
`move_cell`, `add_brush`, `add_box`, `stored_blob`). Test: `tests/test_bsp.py`.
Read by `Clsn_TraceBoxBsp` (ITCM 0x01ffc558), a Quake-style swept-AABB trace, called from the actor mover
`Actor_MoveWithCollision` (0x020877e4) through `Clsn_MoveBox` / `Clsn_TraceWorld` (docs/ghidra.md part 4).
```
"BSP\0" u32 version=5 | u32 0 | u32 file_size | u32 root_offset (0x14)
node (0x1C): s32 front, s32 back, u32 flags, s32 normal[3] (fx 20.12, unit), s32 d (fx32)
leaf:        u32 count, u32 node_offset[count]
```
- **Side**: a point p (fx32) goes to `front` when `n.p/4096 + d <= 0`, else to `back`.
- `front`: > 0 = node, < 0 = **solid leaf** at offset −front. Never 0.
- `back`: > 0 = node, **0 = empty space**. Never a leaf.
- `flags`: bit0 = sign of the normal on its axis (1 = +), bits 1-2 = axis (0 x, 1 y, 2 z, 3 = arbitrary plane:
  the trace then uses the full normal). The axial nodes' normals match the flags on all 17 743 nodes.
  bit3: only ever set when back == 0 (7 777 nodes), never read by the trace — meaning unknown, kept as is.
  Root: upper bits 0x0012FC2x (unknown, kept).
- **Leaf** = a convex solid cell. Its list = the ancestor planes that are real faces of the cell
  (always ancestors, 6..22 entries, contains the parent in 3517/3518 cases). The trace reports a hit only when
  the plane it just crossed is in the leaf list → planes that only split space never block.
- **Storage = preorder**: node, its front child at node + 0x1C (node subtree or leaf), then the back subtree.
  Header + nodes + leaves cover the file exactly (32/32). Hence the old observation "−(node offset + 0x1C)".
- Holder in RAM (location obj+0x38): `{u16 entry, bsp*, s32 offset[3]}` — offset is zero (Map_LoadLocation).
- Floors are thin solid slabs: 58/66 entry points are solid 2 units below their y, 66/66 empty 3 units above.

Evidence: byte-identical write(parse) 32/32 with all invariants (`bsp.py verify`); side convention tested on
entry points (the other convention gives "empty" everywhere); top-down walk maps (`bsp.py walk`) show the
floor plans (City Hall rooms and pillars, town street / plaza / ramp).

**Emulator (2026-10-06)**: A/B ROMs with City Hall entry 0 raised to y = 30 (layout edit). ROM A (original BSP):
the Sim falls to y = 0.0625. ROM B (+ a 7×10×10 box with top y = 10 under the entry, added with `add_box`, BSP
stored uncompressed as a type-0x00 blob): the Sim lands at y = 10.0625. `build/bsp_test/A_vs_B.png`.
→ the BSP is the run-time collision, and method-0 stored entries work for compressed-loaded files.

### Editing — CONFIRMED (code + data + emulator)
Constraints from the code: the trace walks `front` without a zero check (offset 0 would be read as a node), and
`Clsn_TraceWorld` copies the hit node's normal and d as is. So an edit must keep every front non-zero, and new
faces are written with their solid cell on the front side (the normal points out of the solid).
Note: 7 303 of the 28 810 original leaf faces are taken on the back side, so their reported normal points into
the solid; the slide code (`p − n·dot(p, n)`) does not depend on the sign.
- `find_cell(p)` → (leaf, path); `cell_polytope(path)` = exact cell (all ancestor half-spaces, clipped polyhedron);
  `cell_planes(path)` = the planes that carry a facet of it, in front-side form.
- `delete_cell(leaf)`: the parent P of the leaf keeps a non-zero front. If P has a back subtree, P's plane is
  flipped (normal and d negated, bit0 toggled on axial planes) and the back subtree becomes the front child.
  Otherwise P is removed (its parent's back becomes 0, or the same rule climbs up when P was a front child).
- `add_brush(planes)`: the convex brush is pushed down the tree and clipped by each node plane. Parts that land in
  a solid leaf are dropped. Every empty back slot it reaches gets a chain of the brush planes (front → … → a leaf
  listing them all), and bit3 of that node is cleared (bit3 only ever appears with back = 0). `add_box` uses it
  (it used to hang the box in the single slot holding its centre).
- `move_cell(leaf, path, delta)` = `cell_planes` shifted (d −= n·delta) + `delete_cell` + `add_brush`.
- Data check (tests/test_bsp.py, 8 locations, 2 cells each, delete and move): written files parse back
  byte-identical and pass `check`; on a 0.71-unit grid around the cell, solid/empty after the edit equals
  "before minus the cell (plus the moved cell)". The only differences ever seen were within 1/2500 unit of a plane
  (fx32 rounding), and the test skips those points.
- **Emulator (2026-10-06, build/bsp_edit_test/, `make_roms.py`)**: floor slab under City Hall entry 0
  (x −32..−16, y −5..0, z −54..19.7), free_roam_loc5 + warp (5, 6, 0), Sim actor 0x0225A1E4 +0x78:
  ROM C (slab deleted): the Sim falls through the floor (y −31.8 at +400 frames, −43.1 at +520, black void on
  screen, `C_delete.png`). ROM D (entry 0 at y 30, slab moved +10 in y): the Sim lands and stays at y = 10.0625,
  above the lobby floor (`D_move.png`); the original BSP gives 0.0625.

## 4. Layout file (rec+4, formerly "nav") — CONFIRMED, see docs/formats/layout.md
Entry points, NPCs, props, interactive objects, trigger boxes, waypoints, lights/sounds and spawn scripts.
Parsed by `Map_LoadNav` (0x02053128); tool `tools/layout.py` (byte-identical round-trip 32/32).

## 5. Scene models and their animations
`model[k]` of the record: BMD0 (+ BTA0 texture animation, + trs_anim). The `trs_anim` with 1 frame and N
tracks found right after the BSP belongs to the scene model (anim_list), not to object placement as first
guessed in phase 2.

## 6. Runtime: which location is loaded, and how to warp — CONFIRMED (code + emulator)
Pointer chain (statics in arm9 .bss):
```
[0x0213E580] = world        world+0xF4 = current location id (33 = none, e.g. Create-a-Sim)
                            world+0xFC = location object (Map_CreateLocationObject), obj+4 = id,
                            obj+0x38 = BSP holder, obj+0x3C = nav object
[0x02139FA4] = game G       state machine, 2 slots (0 = top/3D, 1 = bottom-screen UI)
   G+0xDA8 + 4*slot   current state object: +0 vtable, +4 state id, +8/+0xC/+0x10 args
   G+0xDF0 + 0x20*slot  pending request {u32 state, arg0, arg1, arg2}; 0x32 = no request
                        (written by Game_RequestState 0x02048108; consumed by Game_UpdateStateMachine)
```
State **2** = "enter location" (vtable 0x02132850, enter = `State2_LocationEnter` 0x02076f00):
arg0 = mode (5 seen on the first arrival; 6 keeps the Sim position, 0xE/0xF special cases), arg1 = location id,
arg2 = entry point (passed to FUN_020845bc). Call chain: State2_LocationEnter → Map_EnterLocation (0x02088048,
writes world+0xF4/+0xFC) → Map_CreateLocationObject (0x02085548) → Map_LoadLocation.

**Warp recipe** (MelonMCP, used to visit all 33 ids): with G = [0x02139FA4], write G+0xDF4 = 5, G+0xDF8 = id,
G+0xDFC = 0, then G+0xDF0 = 2; ~300 frames later world+0xF4 == id. Every id 0..32 loads and renders.
Glitches seen only when the warp was done during the first tutorial popup. `tools/whereami.py` reads the
chain from a 4 MB RAM dump and cross-checks which BSP / GMD1 / nav entries are resident.

### What is resident in RAM (locations 5 and 9, full 4 MB dumps)
- BSP and nav entries: present byte-for-byte (decompressed BSP, raw nav).
- **GMD1: absent** — neither the header nor the XFRM/FRAM payload is in main RAM. So GMD1 is not used by
  the game at run time for these locations (or only transiently). Collision comes from the BSP
  (confirmed 2026-10-06, §3). GMD1 may be a leftover export of the floor; keep it in the round-trip but stop treating
  it as the collision mesh. (ASSUMED until a third check / code proof.)

## 7. Location ids → places — CONFIRMED (scene model names)
Name = MDL0 name of the location's first scene model (`tools/nitro.py`), i.e. the data the loader uses for
that id; the ids are in alphabetical order of these names. Cross-checked by the door graph (layout type 4,
e.g. DoorJail → 14 Jail, DoorGym → 12 Gym, DoorManager → 17 ManagerSuite) and by walking through the City Hall
door in the emulator (id 6, City Hall lobby on screen).

**Screenshots (regenerated 2026-10-06):** `build/locations/loc_NN.png` (both screens, ids 0..32, contact sheets
`sheet_a/b/c.png`); every picture matches the name below. The 2026-10-05 set was wrong because of a MelonMCP
capture lag, not slow loading: a screenshot taken right after `advance_frames(N)` returns a frame from before
that call. The game itself loads a location in < 300 frames. Always advance 1 more frame before a screenshot.

| id | place |
|---|---|
| 0 | AlienRoom (Gov Lab) |
| 1 | ArtGallery |
| 2 | Atrium |
| 3 | Basement |
| 4 | Casino |
| 5 | CityExterior (town, starting place) |
| 6 | CityHall |
| 7 | CultRoom |
| 8 | DeluxeRoom (hotel) |
| 9 | Desert |
| 10 | Freezer |
| 11 | Furnace |
| 12 | Gym |
| 13 | HotelLobby |
| 14 | Jail |
| 15 | JungleRoom (hotel) |
| 16 | LionLounge |
| 17 | ManagerSuite |
| 18 | ModernRoom (hotel) |
| 19 | Observatory |
| 20 | Penthouse |
| 21 | RatCave (Cat Cave) |
| 22 | RoomBeingBuilt1 |
| 23 | RoomBeingBuilt2 |
| 24 | Saloon |
| 25 | SaloonRooms |
| 26 | SaxLounge |
| 27 | SecondFloorLobby (hotel) |
| 28 | SecretWarehouse |
| 29 | SmHotelRoom |
| 30 | Store |
| 31 | SushiBar |
| 32 | Vault |
