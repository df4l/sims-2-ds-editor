# Object info table (names, icons, prices of NPCs and props)

Tool: `tools/objinfo.py` (`dump`, `sheet out.png`). Test: `tests/test_objinfo.py`. Editor: icon pickers for the NPC and
prop fields (Add item palette, item edit form, hotel room furniture form), `GET /api/icon/<npc|prop>/<id>.png`.

## 1. Table — CONFIRMED (code)

arm9 **0x02122A00**, 18-byte records, read through three accessors (the only references to the table):

| Function | Record | Callers |
|---|---|---|
| Info_ByIndex 0x0208b000 | `0x02122A00 + 18·i` | State0E_ShowNextLine (narrator / player lines), 2 others |
| Info_Npc 0x0208afe8 | `0x02122A00 + 18·(npc + 2)` | State0E_ShowNextLine (speaker = NPC id), 11 others |
| Info_Prop 0x0208afd0 | `0x02122A00 + 18·(prop + 0x3B)` | Furn_InitPlacementBase (prop id = actor +10), ~45 others |

| Offset | Type | Field |
|---|---|---|
| 0x00 | u16 | icon sprite: tiles entry (rom.bin) |
| 0x02 | u16 | icon sprite: definition entry |
| 0x04 | u16 | icon sprite: 16-colour palette entry |
| 0x06 | u16 | 0 |
| 0x08 | u16 | text id of the in-game name |
| 0x0A | u16 | picture entry (a `bg_composite`, 10×12 tiles), 0xFFFF = none — ASSUMED: buy-mode / inventory picture |
| 0x0C | u16 | same as 0x0A in every record |
| 0x0E | u16 | price — ASSUMED (buy-mode furniture 40…2500, food 1…8, quest items 0xFFFF, NPCs 0) |
| 0x10 | s16 | read by Furn_InitPlacementBase into placement object +0x28; meaning unknown (0 or −1) |

## 2. Coverage — CONFIRMED (data)

- **NPCs 0..55**: the name text id is `0x143 + npc`, the same id as the NPC names of docs/formats/text.md (56/56). The icon
  is the conversation portrait. NPC 56 ("XXX NOT USED") repeats Emperor Xizzle's record. NPC 57+ (the player Sims) would
  land on prop records, so they have no record of their own.
- **Props 0..330**: names match the models (FridgeBasic 86 = "White Fridge", CouchBasic 128…135 = the 8 couch colours,
  the 6 default room props…). Colour variants share one model and differ only by texture + icon.
- Records whose icon is entry **6180** share one generic placeholder (effects, unused props, some NPCs): treated as
  "no icon". 53/56 NPCs and 276/331 props have their own icon; all of them decode with `tools/s2sprite.py` (first frame,
  record palette), except prop 253 Cellphone (entry 1951 is not a plain sprite, unknown format).
- In rom.bin, every furniture model is followed by one bundle per colour variant:
  `[img8_pal256 texture][icon tiles][icon def][icon pal][bg_composite picture]`.

Visual check (2026-10-09): `objinfo.py sheet` shows every icon, all match their names.

## 3. Open points
- the meaning of +0x10 and the use of the picture (+0x0A); confirm the price in the buy menu;
- ~~how a variant's texture is chosen~~: solved, it is a per-case table in Prop_CreatePlacementObject, not this table
  (docs/formats/roomfurn.md §4b).
