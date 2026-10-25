extends Node
## 홀덤 효과음 재생기. 겹쳐 울리도록 플레이어를 몇 개 돌려 쓴다. table.gd 가 자식으로 만든다.

const SETTINGS_PATH := "user://holdem_settings.cfg"
const VOICES := 6
const EFFECT_VOLUME := 0.6 # 선형(약 -4.4 dB)
const STREAMS := {
	"deal": preload("res://games/holdem/assets/sounds/card-slide-3.ogg"), # 딜은 DEAL_STREAMS 중 무작위(이 항목은 키 확인용)
	"board": preload("res://games/holdem/assets/sounds/card-place-1.ogg"),
	"call": preload("res://games/holdem/assets/sounds/chip-lay-1.ogg"),
	"raise": preload("res://games/holdem/assets/sounds/chip-lay-1.ogg"),
	"allin": preload("res://games/holdem/assets/sounds/chips-stack-3.ogg"),
	"check": preload("res://games/holdem/assets/sounds/click1.ogg"),
	"fold": preload("res://games/holdem/assets/sounds/card-shove-1.ogg"),
	"win": preload("res://games/holdem/assets/sounds/chips-collide-2.ogg"),
	"shuffle": preload("res://games/holdem/assets/sounds/card-shuffle.ogg"),
	"beep": preload("res://games/holdem/assets/sounds/timer_beep.wav"),
	"voice_fold": preload("res://games/holdem/assets/sounds/voice_fold.mp3"),
	"voice_check": preload("res://games/holdem/assets/sounds/voice_check.mp3"),
	"voice_call": preload("res://games/holdem/assets/sounds/voice_call.mp3"),
	"voice_raise": preload("res://games/holdem/assets/sounds/voice_raise.mp3"),
	"voice_allin": preload("res://games/holdem/assets/sounds/voice_allin.mp3"),
}
const DEAL_STREAMS := [
	preload("res://games/holdem/assets/sounds/card-slide-1.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-2.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-3.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-4.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-5.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-6.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-7.ogg"),
	preload("res://games/holdem/assets/sounds/card-slide-8.ogg"),
]

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


## volume 은 선형. 안 주면 효과음 기본값(목소리는 1.0, 비프는 원본 그대로)
func play(sound: String, volume := -1.0) -> void:
	if muted or not STREAMS.has(sound):
		return
	played.append(sound)
	if silent:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = DEAL_STREAMS.pick_random() if sound == "deal" else STREAMS[sound]
	if volume < 0.0:
		volume = 1.0 if sound == "beep" or sound.begins_with("voice_") else EFFECT_VOLUME
	p.volume_db = linear_to_db(volume)
	p.play()


func set_muted(value: bool) -> void:
	muted = value
	var cfg := ConfigFile.new()
	cfg.set_value("sound", "muted", muted)
	cfg.save(SETTINGS_PATH)
