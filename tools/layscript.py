"""Layout script opcodes (Nav_DispatchScriptOp 0x0204299c, handler table 0x0211E4F0). Doc: docs/formats/layout.md §4b

  python tools/layscript.py 5            # disassemble every script of location 5 (with dialogue text)
  python tools/layscript.py 5 --lang fr
  python tools/layscript.py --stats      # opcode usage over the 32 layouts

Every handler receives (location layout object, pointer to its args). Args are read as bytes / s16 / u16 at fixed
offsets; the size of the arg record comes from ARG_SIZE (tools/layout.py). Field specs below follow the handlers
read in Ghidra (all 82 decompiled, see docs/ghidra.md part 5). Conventions:
  group / script : 1-based index in the *selected variant block*, 0 = none (Nav_SpawnGroup / Nav_RunScript)
  g, i           : an actor = item i (1-based, 0 = none) of group g (0-based: the group spawned by group = g + 1)
                   of that block (FUN_020523dc), g = 0xFF -> the player Sim
  npc            : NPC id (name = text 0x143 + npc), table [0x0213E434] + 0x21DC + 0x2C * npc
  flag           : story flag, bitset [0x0213E434] + 0x4814 (Game_TestStoryFlag)
"""
import argparse
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import layout  # noqa: E402
from locations import read_table, PLACES  # noqa: E402
import nitro  # noqa: E402
import text  # noqa: E402

ARM9 = layout._A9


def _a9(addr, fmt):
    return struct.unpack_from(fmt, ARM9, addr - 0x02000000)


# --- data tables referenced by the scripts ---------------------------------------------------------------------
CONV_TABLE = 0x0211F16C     # conversation id -> {u32 lines*, u8 count}; line = {u16 text id, u8 speaker, u8 0}
N_CONV = 216                # ids 0..0xD7 (id 67 is a null record)
MSG_TABLE = 0x0211E8C0      # message id -> {u32 text id, s32 text id 2 or -1} (op 0x45, FUN_0205871c)
NPC_NAME_BASE = 0x143       # NPC name = text 0x143 + npc id (FUN_02082810; Jebediah 22, Cow 53, Bull 54)
SPEAKER = {0x3F: 'narrator', 0x40: 'player'}   # ov15 FUN_02149cd0
GOAL_TABLE = 0x0211FB68     # 4 missions x 0x114: u8 goal count, u8 first goal; goal k: u32 ? @+4+8k, s32 delay @+8+8k
POPUP_SCRIPT = 0x18         # byte of the UI object [0x02139FA4]: layout script run when the popup is closed
# NPC moods (op 0x1C, record +0x1A): names of the BCA0 animations 0xDD + 4*mood .. +3, the same in every NPC model
# (e.g. JebDrunkWalk / JebDrunkIdle1-3). 0 = the model's default idle / walk (ids 0 / 3). 7-11 are the social
# mini-game sets (In / Loop / Hit / Miss).
MOOD = ['normal', 'angry', 'romantic', 'sad', 'drunk', 'impatient?', 'cow_stare', 'hi_five', 'double_guns',
        'joke', 'punch', 'scream']
                            # (written by ops 0x21 / 0x22 / 0x45; set to 0 in RAM the chain stops)


def conversation(cid: int):
    """[(text id, speaker id)] of a conversation (state 0xE, overlay 15)."""
    p, c = _a9(CONV_TABLE + 8 * cid, '<II')
    c &= 0xFF
    return [_a9(p + 4 * k, '<HB')[:2] for k in range(c)] if p else []


def speaker_name(s: int, lang='en') -> str:
    return SPEAKER.get(s) or text.text(NPC_NAME_BASE + s, lang)


def npc_name(n: int, lang='en') -> str:
    return text.text(NPC_NAME_BASE + n, lang) if n < 0x3F else f'npc{n}'


def message(mid: int):
    return _a9(MSG_TABLE + 8 * mid, '<Ii')


def actor_item(block, g: int, i: int):
    """Layout item behind actor (g, i) of a block (None for the player Sim or an index out of range)."""
    if g == 0xFF or g >= len(block.groups) or not 0 < i <= len(block.groups[g].items):
        return None
    return block.groups[g].items[i - 1]


def anim_list(item) -> dict:
    """Animation id -> BCA0 rom.bin entry for an NPC / prop item: model record {u32 list, u16 BMD0, u16 count},
    list entries {u16 id, u16 BCA0, u16 BCA0 or 0xFFFF}."""
    tbl = {1: layout.NPC_MODELS, 2: layout.PROP_MODELS}.get(item.type)
    if tbl is None:
        return {}
    p, _, n = _a9(tbl + 8 * item.fields()['id'], '<IHH')
    return {_a9(p + 6 * k, '<H')[0]: _a9(p + 6 * k + 2, '<H')[0] for k in range(n)} if p else {}


def actor_anim_name(block, g: int, i: int, anim: int) -> str:
    """JNT0 name of the BCA0 played by op 0x0E ('' if unknown: player Sim, id not in the list)."""
    it = actor_item(block, g, i)
    e = anim_list(it).get(anim) if it else None
    if e is None:
        return ''
    p = layout.ROOT / 'rom_bin' / 'dec' / f'{e:04d}.bin'
    d = (p if p.exists() else layout.RAW / f'{e:04d}.bin').read_bytes()
    return nitro.dict_names(d, struct.unpack_from('<I', d, 16)[0] + 8)[0] if d[:4] == b'BCA0' else ''


# --- opcode table -------------------------------------------------------------------------------------------------
# fields: 'name:fmt' with fmt B (u8), h (s16), H (u16), x (unused byte); unlisted trailing bytes are padding.
# status: C = role CONFIRMED by the handler code, A = mechanism read in the code but the game meaning is ASSUMED
OPS = {
    0x00: ('despawn_item', 'group:B item:B', 'C', 'Nav_DespawnGroupItem(group, item)'),
    0x01: ('actor_cmd', 'g:B i:B action:B value:B', 'C', 'action 0 despawn, 1 set/clear actor flag 1, 2 flag 4'),
    0x02: ('group_cmd', 'g:B action:B value:B', 'C', 'op 1 on every item of a spawned group'),
    0x03: ('music_pause', '', 'C', 'channel 0 sequence paused (FUN_020d4884, state 1 -> 2), sound flag bit 0 set. Never used'),
    0x04: ('music_resume', '', 'C', 'channel 0 resumed (FUN_020d4710, state 2 -> 1). Never used'),
    0x05: ('music_play', 'track:B', 'C', 'Snd_PlayMusic: channel 0, track 0..0x29 (table 0x020d556c), no-op if already playing'),
    0x06: ('sfx', 'sound:B', 'C', 'Snd_PlaySfx: random variant of sound id (same call as camera_shake sound 9)'),
    0x07: ('sound_volume_a', 'value:B', 'A', 'sound engine byte +0x664 = value, then refresh (FUN_020d87d4); music/SFX volume? Never used'),
    0x08: ('sound_volume_b', 'value:B', 'A', 'sound engine byte +0x665 = value, refreshes the 16 channels (FUN_020d87f0). Never used'),
    0x09: ('timer', 'delay:H group:B script:B', 'C',
           'event watcher (FUN_02015770 mode 2): delay = update ticks (frames), then spawn group + run script'),
    0x0A: ('despawn_group', 'g:B', 'C', 'FUN_0205251c: deletes every actor of spawned group g'),
    0x0B: ('nop_0b', '', 'C', 'empty handler'),
    0x0C: ('actor_face', 'g:B i:B dir:B', 'C', 'dir 0..4 -> fixed angles (FUN_02052c08)'),
    0x0D: ('actor_teleport', 'x:h y:h z:h g:B i:B dir:B', 'C', 'position (world units) + direction, then floor snap'),
    0x0E: ('actor_anim', 'g:B i:B anim:B b3:B b4:B b5:B', 'C',
           'actor message 3: play animation id `anim` of the actor model list (names: actor_anim_name)'),
    0x0F: ('warp', 'location:B entry:B', 'C', 'Game_RequestState(2, mode 4, location, entry) like a door'),
    0x10: ('request_state', 'state:B a:B b:B', 'C', 'Game_RequestState(state, slot = state != 2, a, b)'),
    0x11: ('nop_11', '', 'C', 'empty handler'),
    0x12: ('player_control', 'enable:B', 'C',
           '0 = cancel player tasks + set bits 6/7 of [G]+0 (D-pad ignored: cutscene), 1 = clear them'),
    0x13: ('nop_13', '', 'C', 'empty handler'),
    0x14: ('set_flag', 'flag:B value:B', 'C', 'story flag bitset +0x4814 (FUN_0206466c)'),
    0x15: ('if_flag', 'flag:B group:B script:B else_group:B else_script:B', 'C', 'Game_TestStoryFlag'),
    0x16: ('spawn_run', 'group:B script:B', 'C', 'Nav_SpawnGroup + Nav_RunScript'),
    0x17: ('conversation', 'conv:B group:B script:B', 'C',
           'state 0xE (ov15): lines of CONV_TABLE[conv]; at the end spawn group + run script'),
    0x18: ('nop_18', '', 'C', 'empty handler'),
    0x19: ('npc_set_talk', 'npc:B conv:B b2:B b3:B flag:B', 'C',
           'conversation offered by the NPC when talked to (30-slot table [G]+0x2FA4, FUN_02082cf0); '
           'conv 0xD8 = none. 71/79 uses name a conversation where this NPC speaks. b2 0x58 = none (flag?)'),
    0x1A: ('camera_look_at', 'x:B x:B x:B x:B g:B i:B script:B', 'C',
           'camera turns to the actor (FUN_020ba100); script stored at camera+0x2BB, run when done (chains seen)'),
    0x1B: ('actor_walk_to', 'x:h y:h z:h g:B i:B mode:B b9:B', 'C', 'actor message 0x18 (NPC) / 0x1b (Sim)'),
    0x1C: ('npc_mood', 'g:B i:B mood:B', 'C',
           'NPC record +0x1A (FUN_020828ac): animation set, walk = 0xDD + 4*mood, idles +1..+3 (FUN_0200aac4); '
           'MOOD names. Emulator: mood 4 -> JebDrunkIdle1 (238) while roaming, 6 -> JebCowStare (246) under 0x1E'),
    0x1D: ('actor_resume_ai', 'g:B i:B', 'C',
           'removes actor task 0x18; an NPC gets its default task 5 back (roaming, task 10) if it lost it. '
           'Emulator: task 0x18 gone, task 10 active again, Jebediah walks ~8 units in 300 frames'),
    0x1E: ('actor_hold_idle', 'g:B i:B', 'C',
           'actor task 0x18 mode 3: suspends the other tasks (roaming) and loops the mood idle animation in '
           'place. Emulator: task 10 inactive, task 0x18 mode 3 active, animation = mood idle'),
    0x1F: ('camera_reset', '', 'C', 'camera back behind the player (mode 9)'),
    0x20: ('money_add', 'amount:h', 'C', 'Simoleons, [G]+0x2F60 clamped to 0..999999'),
    0x21: ('goal_start', 'goal:B script:B', 'C',
           'mission goal 0..33 started ([G]+0x2F78 bit 1), popup 0x990 "New Mission Goal unlocked!"; '
           'script runs when the popup is closed'),
    0x22: ('goal_done', 'goal:B script:B', 'C',
           'bit 2, popup 0x991 "Mission Goal completed!" or 0x992 "Mission Completed!" when every goal of '
           'the mission is done (-> next mission); script runs when the popup is closed'),
    0x23: ('actor_walk_to_actor', 'g:B i:B g2:B i2:B mode:B', 'C', 'move message towards another actor'),
    0x24: ('hotel_dust_add', '', 'C', 'current location dust level +5 (max 9), [G]+0x4538+loc (FUN_0205f2d0); only hotel rooms '
           '(table 0x02131F34) that are open. Used once: dusty lobby at the intro'),
    0x25: ('npc_ask_money', 'amount:h npc:B script:B', 'C',
           'adds "Pay ($amount)" (menu entry 7, text 0x73C) to the NPC; 3-slot table NPC area +0x78. '
           'script runs when paid (Giuseppi 250 -> script 9 "You got the cash", Frankie 1000 -> script 8). amount 0 = remove'),
    0x26: ('camera_shake', 'seconds:h strength:h b4:B script:B', 'C',
           'Cam_Shake(seconds*60 frames, strength << 12), plays sound 9; script stored at camera+0x2BB like 0x1A'),
    0x27: ('nop_27', '', 'C', 'empty handler'),
    0x28: ('nop_28', '', 'C', 'empty handler'),
    0x29: ('camera_closeup', 'x:B x:B g:B i:B', 'C', 'camera framed on the actor (FUN_02076b60)'),
    0x2A: ('phone_conversation', 'conv:B group:B script:B', 'C',
           'conversation with flag bit 24 (prop 0xFD = phone in hand); deferred through an event watcher while '
           'the player is busy (FUN_0206422c: free roam, idle, no cutscene, gate 0x49); conv 3 = special state 0x21'),
    0x2B: ('if_hotel_score', 'min:H group:B script:B else_group:B else_script:B', 'C',
           'Coll_GetScore: sum of LOCATION_TABLE score of the open locations >= min ("score of 20 percent")'),
    0x2C: ('if_stat', 'min:H idx:B x:B group:B script:B else_group:B else_script:B', 'A', 'byte [G]+0x5B+idx >= min'),
    0x2D: ('if_location_open', 'location:B group:B script:B else_group:B else_script:B', 'C',
           'open bit of the location ([G]+0x41F8+0x218). Emulator: City Hall bit cleared -> its door stays shut'),
    0x2E: ('if_goal_started', 'goal:B group:B script:B else_group:B else_script:B', 'C', 'goal bit 1'),
    0x2F: ('if_goal_done', 'goal:B group:B script:B else_group:B else_script:B', 'C', 'goal bit 2'),
    0x30: ('if_goal_active', 'goal:B group:B script:B else_group:B else_script:B', 'C', 'started and not done'),
    0x31: ('if_flags', 'flag:B op:B flag2:B group:B script:B else_group:B else_script:B', 'C',
           'op 0 and, 1 or, 2 neither, 3 xor'),
    0x32: ('random_script', 's0:B s1:B s2:B s3:B s4:B', 'C', 'rand % 5, then the nearest non-zero entry below'),
    0x33: ('counter_inc', '', 'C', '[G]+0x2F9B += 1'),
    0x34: ('if_counter', 'min:B group:B script:B else_group:B else_script:B', 'C', '[G]+0x2F9B >= min'),
    0x35: ('counter_reset', '', 'C', '[G]+0x2F9B = 0'),
    0x36: ('npc_set_status', 'npc:B value:B', 'C',
           'NPC record +0x10. Initial (table 0x02132900, 20 B/NPC): 0 townie, 3 story NPC, 4 Ava/Frankie/Alfred, '
           '6 not around yet, 7 shop/staff, 8 animal/ghost, 9 alien/goon/robot. NPC socials only start with '
           '0/1/3/5/10; phonebook lists 5 (hotel guests) and met NPCs except 7/8/9. Scripts set 6 during a scene'),
    0x37: ('camera_point', 'param:H point:B g:B i:B', 'C',
           'camera at layout c6 record `point`, looking at the actor (FUN_020b9c24)'),
    0x38: ('inventory_add', 'item:B script:B full_script:B', 'C', '6 slots ([G]+0x28, count +0x215C)'),
    0x39: ('inventory_remove', 'item:B', 'C', ''),
    0x3A: ('start_fire', 'location:B', 'C',
           'fire counter of location 6/8/10/15/18/20/29 (slot 6/2/5/1/0/4/3, [G]+0x4620+4+slot, max 10); '
           'in that location a Fire prop (260) is spawned at a random point. L5: City Hall fire ("WATER!")'),
    0x3B: ('if_time', 'h1:B m1:B h2:B m2:B group:B script:B else_group:B else_script:B', 'C',
           'game clock ([G]+0x4800 hour, +0x4804 minute) within h1:m1 .. h2:m2'),
    0x3C: ('npc_met', 'npc:B', 'C', 'NPC record +0x14 |= 1: listed in the phone Phonebook (FUN_0205b12c); also set when the NPC speaks'),
    0x3D: ('switch_2f9c', ' '.join(f'group{k}:B script{k}:B' for k in range(10)), 'C',
           'group/script pair chosen by [G]+0x2F9C (0..9)'),
    0x3E: ('if_counter24', 'idx:B min:B group:B script:B else_group:B else_script:B', 'C', 'byte [G]+0x24+idx >= min'),
    0x3F: ('counter24_sub', 'idx:B amount:B', 'C', 'byte [G]+0x24+idx -= amount'),
    0x40: ('shop_unlock_item', 'item:B', 'A',
           'items 0x4F/0x50/0x52/0xFE -> 0x8A/0x8B/0x8D/0x139 in a 2-slot list [G]+0x47A0: quest tools made '
           'available (shovel 79, power recharger 80, 82, metal detector 254 in the goal texts)'),
    0x41: ('npc_want_item', 'npc:B item:B script:B', 'C',
           '2-slot table NPC area +0x84: giving `item` to the NPC runs `script` (Honest Jackson, item 78 = '
           'the gift from Frankie -> script 7 "From Frankie Fusilli?")'),
    0x42: ('if_next_goal_ready', 'x:B group:B script:B else_group:B else_script:B', 'C',
           'FUN_020778ac: next goal of the mission may start (delay since the last goal done >= GOAL_TABLE '
           'delay, all 0 in the data); false once the 4 missions are done'),
    0x43: ('set_weather', 'mode:B', 'C',
           '[G]+0x4650: 0 = by date (pseudo-random, FUN_0206453c), 1 = off, 2 = on; then the location weather '
           'record (Map_GetLocField12) is re-applied. Set to 1 for the Super Drencher scene'),
    0x44: ('set_flag_bit2', '', 'A', '[0x0213E434] word |= 4 (once, after buying the Super Drencher)'),
    0x45: ('message', 'msg:B script:B queued:B', 'C',
           'popup with the texts of MSG_TABLE[msg] (FUN_0205871c); script runs when the popup is closed'),
    0x46: ('if_has_item', 'item:B group:B script:B else_group:B else_script:B', 'C', 'inventory contains item'),
    0x47: ('location_offer', 'location:B', 'A',
           'bit of [G]+0x41F8+0x210. New game sets it for the 11 priced rooms (+ 2, 3, 10, 19): rooms offered '
           'for construction (assumed); scripts add 4 Casino, 7 Bovine Shrine, 32 Vault ("build me a vault")'),
    0x48: ('location_link_flag', 'location:B flag:B', 'C', 'story flag set when the location is opened (one slot, Coll_LinkStoryFlag)'),
    0x49: ('phone_gate', 'value:B', 'A',
           '[G]+0x21D8 = value != 0; while set, deferred phone calls wait until [G]+0x21B4 == -1 (FUN_0206422c)'),
    0x4A: ('location_open', 'location:B', 'C',
           'Coll_SetOwned: open bit of the location (doors lead there), sets the linked story flag (0x48); '
           '28 = Small Guest Room also stores the clock. New game opens 2,3,5,6,10,11,13,14,19,24,25,27,29,30'),
    0x4B: ('location_setup', 'event:B arg:B', 'C',
           'hard-coded per location, block 0 script 1: 0x11 Manager Suite license plate display (24 bits '
           '[G]+0x20, model id arg), 0x15 Rat Cave prop by player model, 0x1E Store item of the day (RTC weekday)'),
    0x4C: ('npc_set_1c', 'npc:B value:B', 'A',
           'NPC actors with this NPC id: brain (+0x130) byte +0x1C = value != 0; when cleared in free roam '
           'FUN_02067980 is called. Used twice with 0 (Frankie, Honest Jackson)'),
    0x4D: ('door_open', 'g:B i:B', 'C',
           'door actor (layout type 4, always item 1 of group 0 in the uses): state +0x211 0 -> plays door '
           'animation 135 (DoorXxx), state 3; 1 -> clears flag 8; 2 -> keeps it open 30 more frames'),
    0x4E: ('actor_hold_prop', 'g:B i:B remove_only:B prop:B slot:B', 'C', 'prop actor attached to slot (+0x1C)'),
    0x4F: ('actor_to_object', 'g:B i:B', 'C', 'copies position/rotation of actor (type 0xB, id 0x24)'),
    0x50: ('music_play2', 'track:B', 'C', 'Snd_PlayMusic2: same track table on channel 1 (used once, L13)'),
    0x51: ('alfred_fly_sequence', 'g:B i:B b2:B', 'C',
           'fixed actor message chain: anims 0x7E OptiPropFly, 0x7D OptiPropOut, 0x7A OptiCallWait, 0x79 '
           'OptiCallExt (Optimum Alfred propeller entry); used once'),
}

_FMT = {'B': ('<B', 1), 'h': ('<h', 2), 'H': ('<H', 2)}


def decode_args(op: int, args: bytes) -> dict:
    name, spec, _, _ = OPS[op]
    out, p = {}, 0
    for f in spec.split():
        k, t = f.split(':')
        fmt, n = _FMT[t]
        if k != 'x':
            out[k] = struct.unpack_from(fmt, args, p)[0]
        p += n
    return out


def describe(op: int, args: bytes, lang='en', block=None) -> str:
    name = OPS[op][0]
    a = decode_args(op, args)
    s = f'{name}(' + ', '.join(f'{k}={v:#x}' if k in ('flag', 'flag2', 'msg') else f'{k}={v}'
                                for k, v in a.items()) + ')'
    if 'npc' in a:
        s += f'  ; {npc_name(a["npc"], lang)}'
    if name in ('conversation', 'phone_conversation', 'npc_set_talk') and a['conv'] < N_CONV:
        for t, sp in conversation(a['conv']):
            s += f'\n      | {speaker_name(sp, lang)}: ' + text.text(t, lang).replace('\n', ' ')
    if name == 'message':
        t1, t2 = message(a['msg'])
        s += f'\n      | {text.text(t1, lang)}' + (f' / {text.text(t2, lang)}' if t2 >= 0 else '')
    if name == 'actor_anim' and block is not None:
        n = actor_anim_name(block, a['g'], a['i'], a['anim'])
        s += f'  ; {n}' if n else ''
    if name == 'npc_mood':
        s += f'  ; {MOOD[a["mood"]] if a["mood"] < len(MOOD) else "?"}'
    if name == 'warp':
        s += f'  ; -> {PLACES[a["location"]] if a["location"] < len(PLACES) else "?"}'
    elif 'location' in a:
        s += f'  ; {PLACES[a["location"]] if a["location"] < len(PLACES) else "?"}'
    return s


def cmd_dump(loc: int, lang: str):
    L = read_table()[loc]
    lay = layout.parse((layout.RAW / f'{L["nav"]:04d}.bin').read_bytes())
    print(f'location {loc} ({PLACES[loc]}), layout {L["nav"]}')
    for bi, b in enumerate(lay.blocks):
        print(f'block {bi}: {len(b.groups)} groups, {len(b.scripts)} scripts')
        for si, s in enumerate(b.scripts):
            print(f'  script {si + 1}:')
            for op, args in s:
                print(f'    {describe(op, args, lang, b)}')


def cmd_stats():
    c = Counter()
    for L, idx, d in layout.layouts():
        for b in layout.parse(d).blocks:
            for s in b.scripts:
                c.update(op for op, _ in s)
    for op, n in c.most_common():
        print(f'0x{op:02X} {OPS[op][0]:<22} {n:4d}  [{OPS[op][2]}]')


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser()
    ap.add_argument('location', type=int, nargs='?')
    ap.add_argument('--lang', default='en')
    ap.add_argument('--stats', action='store_true')
    a = ap.parse_args()
    if a.stats:
        cmd_stats()
    else:
        cmd_dump(a.location, a.lang)


if __name__ == '__main__':
    main()
