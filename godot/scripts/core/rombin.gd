class_name RomBin
extends RefCounted
## rom.bin archive (docs/formats/rombin.md): u32 offsets[N + 1] (offsets[0] = table size, offsets[N] = file size),
## entry i = data[offsets[i]:offsets[i + 1]]. Entries are decompressed on demand and cached.

var raw := PackedByteArray()
var offs := PackedInt64Array()
var error := ""
var _data := {}
var _blobs := {}
var _mutex := Mutex.new()


func load_bytes(d: PackedByteArray) -> bool:
	raw = d
	if d.size() < 8:
		error = "rom.bin too small"
		return false
	var first := d.decode_u32(0)
	if first % 4 or first < 8 or first > d.size():
		error = "rom.bin: bad table size 0x%X" % first
		return false
	var count := first / 4
	offs.resize(count)
	for i in count:
		offs[i] = d.decode_u32(4 * i)
	if offs[count - 1] != d.size():
		error = "rom.bin: last offset != file size"
		return false
	for i in count - 1:
		if offs[i] > offs[i + 1]:
			error = "rom.bin: offsets not sorted at %d" % i
			return false
	return true


func count() -> int:
	return offs.size() - 1


func raw_entry(i: int) -> PackedByteArray:
	return raw.slice(offs[i], offs[i + 1])


## Decompressed blobs of entry i ([] if the entry is raw). Each item: {type, start, end, out}.
func blobs(i: int) -> Array:
	_mutex.lock()
	var have := _blobs.has(i)
	var b = _blobs.get(i)
	_mutex.unlock()
	if have:
		return b
	b = S2Cmp.split_blobs(raw_entry(i))
	_mutex.lock()
	_blobs[i] = b
	_mutex.unlock()
	return b


## Content of entry i: its first decompressed blob, or the raw entry when it is not compressed.
func data(i: int) -> PackedByteArray:
	if i < 0 or i >= count():
		return PackedByteArray()
	_mutex.lock()
	var have := _data.has(i)
	var d = _data.get(i)
	_mutex.unlock()
	if have:
		return d
	var b := blobs(i)
	d = b[0].out if not b.is_empty() else raw_entry(i)
	_mutex.lock()
	_data[i] = d
	_mutex.unlock()
	return d


## Archive with some entries replaced ({index: raw entry bytes}) and new entries appended after the last one
## (`added`: raw entry bytes, 4-aligned; they get the indices count(), count() + 1, ...). The game reads the table one
## entry at a time (Arc_GetEntrySize / Arc_ReadEntryRaw: seek idx*4, read 8 bytes), it keeps no entry count.
## Sets `last_map`: [[new offset, old offset, size]] of the byte ranges copied unchanged (for patch export).
var last_map := []


func build(replacements: Dictionary, added := []) -> PackedByteArray:
	var n := count()
	var total := n + added.size()
	var head := PackedByteArray()
	head.resize(4 * (total + 1))
	var pos := 4 * (total + 1)
	for i in n:
		head.encode_u32(4 * i, pos)
		pos += replacements[i].size() if replacements.has(i) else offs[i + 1] - offs[i]
	for k in added.size():
		head.encode_u32(4 * (n + k), pos)
		pos += added[k].size()
	head.encode_u32(4 * total, pos)
	var out := head
	last_map = []
	var i := 0
	while i < n:
		if replacements.has(i):
			out.append_array(replacements[i])
			i += 1
			continue
		var j := i
		while j < n and not replacements.has(j):
			j += 1
		last_map.append([out.size(), offs[i], offs[j] - offs[i]])
		out.append_array(raw.slice(offs[i], offs[j]))
		i = j
	for a in added:
		out.append_array(a)
	return out
