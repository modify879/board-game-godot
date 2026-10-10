class_name Balance extends RefCounted
## 지갑 잔액을 읽어 라벨에 쓴다 (로비·지갑 공용). 응답을 돌려준다.


static func load_into(label: Label) -> Dictionary:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	label.text = Format.balance(int(r.data.balance)) if r.ok else Format.BALANCE_FAILED
	return r
