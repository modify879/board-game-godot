class_name Format
## 화면 표시용 포매터.


## 천 단위 쉼표
static func comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## ISO Instant(UTC) → 로컬 "MM-DD HH:MM". 소수 초·Z 는 앞 19자만 써서 버린다
static func time(iso: String) -> String:
	var t := int(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))
	t += int(Time.get_time_zone_from_system().bias) * 60
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%02d-%02d %02d:%02d" % [d.month, d.day, d.hour, d.minute]
