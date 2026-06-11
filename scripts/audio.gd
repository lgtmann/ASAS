extends Node

# SFX manager, autoloaded as "Sfx". A small player pool for polyphony, pitch
# variation per play so repeated sounds don't machine-gun, a looping ambient
# bed, and a master volume persisted to user://settings.cfg.

const SFX_DIR := "res://assets/sfx/"
const POOL_SIZE := 10
const AMBIENT_GAIN := 0.45

var volume: float = 0.8
var _players: Array = []
var _ambient: AudioStreamPlayer
var _streams: Dictionary = {}

func _ready() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	_ambient = AudioStreamPlayer.new()
	add_child(_ambient)
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		volume = clampf(float(cfg.get_value("audio", "volume", 0.8)), 0.0, 1.0)

func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "volume", volume)
	cfg.save("user://settings.cfg")
	if _ambient != null and _ambient.playing:
		_ambient.volume_db = linear_to_db(maxf(volume * AMBIENT_GAIN, 0.0001))

func _stream(sname: String) -> AudioStream:
	if _streams.has(sname):
		return _streams[sname]
	var path := SFX_DIR + sname + ".wav"
	var st: AudioStream = null
	if ResourceLoader.exists(path):
		st = load(path)
	_streams[sname] = st
	return st

func play(sname: String, pitch_var: float = 0.08, gain_db: float = 0.0) -> void:
	if volume <= 0.001:
		return
	var st: AudioStream = _stream(sname)
	if st == null:
		return
	var chosen: AudioStreamPlayer = null
	for p in _players:
		if not p.playing:
			chosen = p
			break
	if chosen == null:
		chosen = _players[0]      # steal the oldest slot
	chosen.stream = st
	chosen.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	chosen.volume_db = gain_db + linear_to_db(volume)
	chosen.play()

# Material-aware harvest/dig sound.
func terrain(mat: int) -> void:
	match mat:
		VoxelWorld.Mat.TREE:
			play("chop", 0.06)
		VoxelWorld.Mat.STONE:
			play("stone", 0.08)
		VoxelWorld.Mat.GOLD, VoxelWorld.Mat.CRYSTAL, VoxelWorld.Mat.RELIC:
			play("dig", 0.10)
			play("reward", 0.02)
		_:
			play("dig", 0.10)

# Gentle wind bed; safe to call repeatedly (no-op while playing).
func ambient_start() -> void:
	if _ambient.playing:
		return
	var st: AudioStream = _stream("ambient")
	if st == null:
		return
	if st is AudioStreamWAV:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = 0
		st.loop_end = st.data.size() / 2      # 16-bit mono: 2 bytes per frame
	_ambient.stream = st
	_ambient.volume_db = linear_to_db(maxf(volume * AMBIENT_GAIN, 0.0001))
	_ambient.play()
