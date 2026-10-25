extends Node
## 홀덤 효과음 재생기. 겹쳐 울리도록 플레이어를 몇 개 돌려 쓴다. table.gd 가 자식으로 만든다.

const SETTINGS_PATH := "user://holdem_settings.cfg"
const VOICES := 6
const EFFECT_VOLUME := 0.6 # 선형(약 -4.4 dB)
const STREAMS := {
	"deal": preload("res://games/holdem/assets/sounds/card-slide-3.ogg"),
	"board": preload("res://games/holdem/assets/sounds/card-place-1.ogg"),
	"call": preload("res://games/holdem/assets/sounds/chip-lay-1.ogg"),
	"allin": preload("res://games/holdem/assets/sounds/chips-stack-3.ogg"),
	"check": preload("res://games/holdem/assets/sounds/click1.ogg"),
	"fold": preload("res://games/holdem/assets/sounds/card-shove-1.ogg"),
	"win": preload("res://games/holdem/assets/sounds/chips-collide-2.ogg"),
	"shuffle": preload("res://games/holdem/assets/sounds/card-shuffle.ogg"),
	"beep": preload("res://games/holdem/assets/sounds/timer_beep.wav"),
}

var muted := false
var silent := false # 헤드리스 점검에서는 소리를 내지 않는다
var played: Array = [] # 재생 요청 기록(점검용)
var _players: Array = []
var _next := 0


func _ready() -> void:
	silent = DisplayServer.get_name() == "headless"
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		muted = bool(cfg.get_value("sound", "muted", false))
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play(sound: String) -> void:
	if muted or not STREAMS.has(sound):
		return
	played.append(sound)
	if silent:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = STREAMS[sound]
	p.volume_db = 0.0 if sound == "beep" else linear_to_db(EFFECT_VOLUME)
	p.play()


func set_muted(value: bool) -> void:
	muted = value
	var cfg := ConfigFile.new()
	cfg.set_value("sound", "muted", muted)
	cfg.save(SETTINGS_PATH)
